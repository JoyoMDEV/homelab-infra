# Nextcloud Setup Runbook

Einmaliger Setup-Guide für Nextcloud im Homelab.
Nextcloud läuft unter **https://nextcloud.homelab.local**.

**Voraussetzungen:**
- Kubernetes-Cluster läuft: `make status`
- ArgoCD erreichbar: https://argocd.homelab.local
- Keycloak läuft: https://auth.homelab.local
- Keycloak Realm `homelab` + LDAP-Federation eingerichtet (siehe `docs/keycloak-setup.md`)
- CoreDNS konfiguriert: `make setup-coredns`
- CA importiert auf deinem Gerät: `make cert-ca`

---

## Inhaltsverzeichnis

1. [Datenbank + Secrets anlegen](#1-datenbank--secrets-anlegen)
2. [Keycloak OIDC-Client anlegen](#2-keycloak-oidc-client-anlegen)
3. [Traefik Middleware deployen](#3-traefik-middleware-deployen)
4. [Nextcloud deployen](#4-nextcloud-deployen)
5. [Storage Box einrichten](#5-storage-box-einrichten)
6. [Verifikation](#6-verifikation)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Datenbank + Secrets anlegen

### 1.1 PostgreSQL Datenbank anlegen

```bash
# Warten bis PostgreSQL bereit ist
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s

# Datenbank + User anlegen
NEXTCLOUD_DB_PW=$(openssl rand -base64 24)

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c \
  "CREATE DATABASE nextcloud;" 2>/dev/null || echo "Datenbank existiert bereits"

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nextcloud') THEN
      CREATE ROLE nextcloud WITH LOGIN PASSWORD '${NEXTCLOUD_DB_PW}';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
  ALTER DATABASE nextcloud OWNER TO nextcloud;
"

echo "Nextcloud DB Password: ${NEXTCLOUD_DB_PW}"
echo "→ Dieses Passwort für Schritt 1.2 notieren!"
```

### 1.2 Kubernetes Secrets anlegen

```bash
# Redis Passwort aus bestehendem Secret lesen
REDIS_PW=$(kubectl get secret redis-secret -n infrastructure \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# Admin Passwort generieren
NEXTCLOUD_ADMIN_PW=$(openssl rand -base64 16)

# Storage Box Passwort – aus terraform.tfvars oder Hetzner Console
STORAGE_BOX_PW="<DEIN_STORAGE_BOX_PASSWORT>"

# Nextcloud Secret anlegen
# oidc-client-secret wird nach Schritt 2 nachgetragen
kubectl create secret generic nextcloud-secret \
  --from-literal=nextcloud-username="admin" \
  --from-literal=nextcloud-password="${NEXTCLOUD_ADMIN_PW}" \
  --from-literal=db-password="${NEXTCLOUD_DB_PW}" \
  --from-literal=redis-password="${REDIS_PW}" \
  --from-literal=storage-box-password="${STORAGE_BOX_PW}" \
  --from-literal=oidc-client-secret="PLACEHOLDER_REPLACE_AFTER_KEYCLOAK" \
  -n productivity

echo ""
echo "=========================================="
echo "  Nextcloud Admin: admin / ${NEXTCLOUD_ADMIN_PW}"
echo "  → Sicher aufbewahren!"
echo "=========================================="
```

> **Wichtig:** Das Secret `nextcloud-secret` muss im Namespace `productivity` existieren,
> bevor ArgoCD Nextcloud deployt. ArgoCD wird sonst in einen Sync-Error laufen.

---

## 2. Keycloak OIDC-Client anlegen

**Navigation:** https://auth.homelab.local → Realm `homelab` → **Clients** → **"Create client"**

### 2.1 General Settings

| Feld | Wert |
|------|------|
| Client type | `OpenID Connect` |
| Client ID | `nextcloud` |
| Name | `Nextcloud` |

→ **Next**

### 2.2 Capability Config

| Feld | Wert |
|------|------|
| Client authentication | ON (confidential client) |
| Authorization | OFF |
| Standard flow | ON |
| Direct access grants | OFF |

→ **Next**

### 2.3 Login Settings

| Feld | Wert |
|------|------|
| Root URL | `https://nextcloud.homelab.local` |
| Home URL | `https://nextcloud.homelab.local` |
| Valid redirect URIs | `https://nextcloud.homelab.local/apps/oidc_login/oidc` |
| Valid post logout redirect URIs | `https://nextcloud.homelab.local` |
| Web origins | `https://nextcloud.homelab.local` |

→ **Save**

### 2.4 Gruppen-Claim konfigurieren

Damit Keycloak die Gruppen des Benutzers im Token mitschickt:

1. Client `nextcloud` → Tab **"Client scopes"**
2. Klick auf `nextcloud-dedicated`
3. **"Add mapper"** → **"By configuration"** → **"Group Membership"**

| Feld | Wert |
|------|------|
| Name | `groups` |
| Token Claim Name | `groups` |
| Full group path | OFF |
| Add to ID token | ON |
| Add to access token | ON |
| Add to userinfo | ON |

→ **Save**

### 2.5 Client Secret in Kubernetes eintragen

1. Tab **"Credentials"** öffnen
2. **"Client secret"** kopieren
3. Secret aktualisieren:

```bash
kubectl patch secret nextcloud-secret -n productivity \
  --type merge \
  -p '{"stringData":{"oidc-client-secret":"<DEIN_SECRET_HIER>"}}'
```

---

## 3. Traefik Middleware deployen

Die Middleware sorgt für korrekte Security-Header und CalDAV/CardDAV-Redirects.
Sie muss vor Nextcloud existieren, da der Ingress darauf referenziert.

Erstelle `k8s/infrastructure/nextcloud-middleware.yaml`:

```yaml
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: nextcloud-headers
  namespace: productivity
spec:
  headers:
    customRequestHeaders:
      X-Forwarded-Proto: "https"
    customResponseHeaders:
      X-Robots-Tag: "noindex, nofollow"
      X-Frame-Options: "SAMEORIGIN"
      X-Content-Type-Options: "nosniff"
      Strict-Transport-Security: "max-age=31536000; includeSubDomains"
---
# CalDAV / CardDAV Discovery Redirect
# Ohne diesen Redirect können Kalender/Kontakt-Apps (z.B. DAVx⁵) die
# Endpunkte nicht automatisch finden.
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: nextcloud-redirects
  namespace: productivity
spec:
  redirectRegex:
    permanent: true
    regex: "https://nextcloud.homelab.local/.well-known/(card|cal)dav"
    replacement: "https://nextcloud.homelab.local/remote.php/dav/"
```

```bash
# Direkt anwenden (wird auch von ArgoCD infrastructure App gepickt)
kubectl apply -f k8s/infrastructure/nextcloud-middleware.yaml

# Oder committen und ArgoCD deployen lassen:
git add k8s/infrastructure/nextcloud-middleware.yaml
git commit -m "feat: add Nextcloud Traefik middleware"
git push
```

---

## 4. Nextcloud deployen

### 4.1 ArgoCD Application committen

```bash
git add k8s/argocd/applications/nextcloud.yaml
git commit -m "feat: add Nextcloud to cluster"
git push
```

ArgoCD synct automatisch. Den Fortschritt beobachten:

```bash
# ArgoCD App Status
kubectl get application nextcloud -n argocd

# Pod Status (initContainer + Hauptcontainer)
kubectl get pods -n productivity -w

# Logs des initContainers (oidc_login + files_external Installation)
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c setup-nextcloud --follow

# Logs des Nextcloud Hauptcontainers
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c nextcloud --follow
```

> Der erste Start dauert **3–5 Minuten**, da Nextcloud die Datenbank initialisiert
> und alle Standard-Apps installiert. Der `startupProbe` gibt 60 Versuche à 10s = 10 Minuten.

### 4.2 Erster Login testen

1. https://nextcloud.homelab.local öffnen
2. Mit lokalem Admin-Account einloggen: `admin` / Passwort aus Schritt 1.2
3. Prüfen ob der Button **"Mit Keycloak anmelden"** erscheint
4. OIDC-Login mit einem AD-Benutzer testen (privates Fenster empfohlen)

---

## 5. Storage Box einrichten

### 5.1 Verzeichnis auf Storage Box anlegen

Das Verzeichnis `/nextcloud` muss auf der Storage Box existieren, bevor es gemountet wird.

```bash
# Storage Box Verbindungsdaten aus Terraform auslesen
cd terraform
STORAGE_HOST=$(terraform output -raw storage_box_host)
STORAGE_USER=$(terraform output -raw storage_box_username)
cd ..

# Per SFTP verbinden und Verzeichnis anlegen
# Port 23 (nicht 22!) – Hetzner Storage Box verwendet Port 23
sftp -P 23 ${STORAGE_USER}@${STORAGE_HOST} <<EOF
mkdir nextcloud
ls -la
bye
EOF
```

### 5.2 External Storage Script ausführen

```bash
chmod +x scripts/setup-nextcloud-storage.sh
./scripts/setup-nextcloud-storage.sh
```

Das Script:
- Prüft alle Voraussetzungen
- Testet die SFTP-Verbindung aus dem Cluster
- Aktiviert die `files_external` App (falls noch nicht durch initContainer geschehen)
- Legt den SFTP-Mount zur Storage Box an
- Gibt den Mount für alle Benutzer frei

> Der initContainer in `nextcloud.yaml` aktiviert `files_external` bereits beim Pod-Start.
> Das Script ist trotzdem idempotent und erkennt den Zustand korrekt.

### 5.3 Mount verifizieren

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ files_external:list"
```

Erwartete Ausgabe:

```
+----+-------------+------+--------------------+----------+
| ID | Mount Point | Type | Authentication     | Status   |
+----+-------------+------+--------------------+----------+
| 1  | /Storage Box| SFTP | password::password | ok       |
+----+-------------+------+--------------------+----------+
```

In der Nextcloud-UI erscheint die Storage Box unter **Dateien → Storage Box**.

---

## 6. Verifikation

### Nextcloud erreichbar

```bash
curl -sv https://nextcloud.homelab.local/status.php | python3 -m json.tool
# Erwartete Ausgabe: {"installed":true,"maintenance":false,...}
```

### OIDC funktioniert

```bash
# OIDC Discovery Endpoint von Nextcloud aus erreichbar?
kubectl exec -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -- curl -sf https://auth.homelab.local/realms/homelab/.well-known/openid-configuration \
  | python3 -m json.tool | grep issuer
```

### oidc_login App aktiv

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ app:list --enabled" \
  | grep -E "oidc_login|files_external"
```

### Zertifikate + Pods

```bash
make cert-status
kubectl get pods -n productivity
```

### CalDAV / CardDAV Redirect

```bash
# Muss mit 301 auf /remote.php/dav/ weiterleiten
curl -sv https://nextcloud.homelab.local/.well-known/caldav 2>&1 | grep -E "< HTTP|Location"
```

---

## 7. Troubleshooting

### OIDC-Login schlägt fehl: "SSL certificate problem"

Der initContainer registriert die CA, aber manchmal greift `update-ca-certificates` nicht vollständig.

```bash
# CA im Pod prüfen
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -c nextcloud -- \
  curl -sv https://auth.homelab.local/realms/homelab/.well-known/openid-configuration

# Falls SSL-Fehler: CA manuell im laufenden Pod registrieren (temporär)
kubectl exec -n productivity ${POD} -c nextcloud -- \
  sh -c "update-ca-certificates && echo OK"
```

Dauerhafter Fix: Prüfen ob das `homelab-ca` Secret im Namespace `productivity` existiert:

```bash
kubectl get secret homelab-ca -n productivity
# Falls nicht vorhanden: cert-sync manuell triggern
make cert-sync
```

### OIDC-Login schlägt fehl: "Invalid redirect URI"

Die Redirect URI in Keycloak muss exakt `https://nextcloud.homelab.local/apps/oidc_login/oidc` sein – kein trailing Slash, kein `http://`.

```bash
# Keycloak → Clients → nextcloud → Settings → Valid redirect URIs prüfen
```

### OIDC-Button erscheint nicht auf der Login-Seite

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

# Ist oidc_login aktiv?
kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ app:list --enabled" | grep oidc

# App manuell aktivieren falls nicht vorhanden
kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ app:enable oidc_login"
```

### Nextcloud startet nicht (CrashLoopBackOff)

```bash
# initContainer Logs prüfen
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c setup-nextcloud

# Hauptcontainer Logs
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c nextcloud --previous
```

Häufige Ursachen: Secret fehlt, PostgreSQL nicht erreichbar, PVC nicht gebunden.

### Storage Box nicht erreichbar (Status: "Network error")

```bash
# SFTP-Verbindung direkt aus dem Cluster testen
kubectl run sftp-debug --image=alpine --restart=Never -it --rm -n productivity -- \
  sh -c "apk add openssh-client sshpass -q && \
    sshpass -p '<PASSWORT>' sftp -P 23 -o StrictHostKeyChecking=no \
    <USER>@<HOST>"
```

Häufige Ursache: Storage Box Passwort im Secret falsch oder `/nextcloud`-Verzeichnis
existiert noch nicht auf der Storage Box (→ Schritt 5.1 ausführen).

### Nextcloud zeigt "Wartungsmodus"

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ maintenance:mode --off"
```

### OOMKilled (Pod wird wegen Speichermangel beendet)

Memory Limit in `nextcloud.yaml` erhöhen:

```yaml
resources:
  limits:
    memory: 2Gi  # von 1Gi auf 2Gi
```

Dann committen und pushen – ArgoCD updated automatisch.
