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

kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c \
  "CREATE DATABASE nextcloud;" 2>/dev/null || echo "Datenbank existiert bereits"

kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c "
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
  --from-literal=db-username="nextcloud" \
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
> bevor ArgoCD Nextcloud deployt.

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

> **Hinweis:** `groups` wird **nicht** als expliziter Scope angefordert (`oidc_login_scope`
> enthält nur `openid profile email`). Der Gruppen-Claim kommt automatisch über diesen
> Mapper im Token. Keycloak würde `invalid_scope` zurückgeben wenn `groups` als Scope
> angefordert wird ohne ihn als Client Scope zu registrieren.

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

```bash
kubectl apply -f k8s/infrastructure/nextcloud-middleware.yaml

# Oder via Git:
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
# Pod Status
kubectl get pods -n productivity -w

# postStart Hook Logs (Installation + App-Aktivierung)
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c nextcloud --follow
```

> Der postStart Hook übernimmt automatisch:
> - homelab-CA ins Alpine PHP-Bundle eintragen (`/etc/ssl/cert.pem`)
> - Nextcloud installieren falls noch nicht installiert
> - `trusted_domains` setzen
> - `oidc_login` und `files_external` Apps aktivieren

> Der erste Start dauert **3–5 Minuten** wegen DB-Initialisierung.

### 4.2 Erster Login testen

1. https://nextcloud.homelab.local öffnen
2. Button **"Mit Keycloak anmelden"** klicken
3. AD-Credentials eingeben (privates Fenster empfohlen)

> **Bekanntes Verhalten:** Beim allerersten Login-Versuch können kurz
> `authentication_expired` oder `PKCE code verifier not specified` Fehler erscheinen.
> Einfach nochmal auf **"Mit Keycloak anmelden"** klicken – beim zweiten Versuch
> funktioniert es. Das ist ein Session-Timing-Problem zwischen Keycloak und oidc_login.

---

## 5. Storage Box einrichten

### 5.1 Verzeichnis auf Storage Box anlegen

```bash
cd terraform
STORAGE_HOST=$(terraform output -raw storage_box_host)
STORAGE_USER=$(terraform output -raw storage_box_username)
cd ..

# Per SFTP verbinden (Port 23 für SFTP-Zugang)
sftp -P 23 -o StrictHostKeyChecking=no ${STORAGE_USER}@${STORAGE_HOST} <<EOF
mkdir nextcloud
ls -la
bye
EOF
```

### 5.2 WebDAV External Storage einrichten

> **Wichtig:** Das Nextcloud `fpm-alpine` Image enthält keine `php-ssh2` Extension,
> daher funktioniert SFTP-External-Storage nicht. Wir nutzen stattdessen **WebDAV**
> (HTTPS Port 443) – die Storage Box unterstützt das out-of-the-box.

```bash
chmod +x scripts/setup-nextcloud-storage.sh
./scripts/setup-nextcloud-storage.sh
```

Das Script:
- Prüft alle Voraussetzungen
- Testet die WebDAV-Verbindung aus dem Cluster
- Aktiviert die `files_external` App (idempotent)
- Legt den WebDAV-Mount zur Storage Box an
- Gibt den Mount für alle Benutzer frei

### 5.3 Mount verifizieren

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ files_external:list"
```

Erwartete Ausgabe:

```
+----------+-------------+---------+---------------------+------------------------------------------+
| Mount ID | Mount Point | Storage | Authentication Type | Configuration                            |
+----------+-------------+---------+---------------------+------------------------------------------+
| 1        | /StorageBox | WebDAV  | Login and password  | host: "https://u....your-storagebox.de"  |
+----------+-------------+---------+---------------------+------------------------------------------+
```

In der Nextcloud-UI erscheint die Storage Box unter **Dateien → StorageBox**.

---

## 6. Verifikation

### Nextcloud erreichbar

```bash
curl -s https://nextcloud.homelab.local/status.php | python3 -m json.tool
# Erwartete Ausgabe: {"installed":true,"maintenance":false,...}
```

### OIDC funktioniert

```bash
kubectl exec -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c nextcloud -- \
  curl -sf https://auth.homelab.local/realms/homelab/.well-known/openid-configuration \
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
curl -sv https://nextcloud.homelab.local/.well-known/caldav 2>&1 | grep -E "< HTTP|Location"
```

---

## 7. Troubleshooting

### OIDC-Button erscheint nicht

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ app:list --enabled" | grep oidc

# App manuell aktivieren
kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "php /var/www/html/occ app:enable oidc_login"
```

### OIDC-Login: "SSL certificate problem"

Der postStart Hook hängt die homelab-CA an `/etc/ssl/cert.pem` an – das ist das
Alpine PHP-Bundle. `update-ca-certificates` greift **nicht** für PHP auf Alpine
(PHP liest `/etc/ssl/cert.pem`, nicht `/etc/ssl/certs/`).

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

# Ist die CA im PHP-Bundle?
kubectl exec -n productivity ${POD} -c nextcloud -- \
  grep -c "BEGIN CERTIFICATE" /etc/ssl/cert.pem

# Manuell anhängen (temporär bis zum nächsten Neustart)
kubectl exec -n productivity ${POD} -c nextcloud -- \
  sh -c "cat /etc/ssl/certs/homelab-ca.pem >> /etc/ssl/cert.pem && echo OK"

# Dauerhafter Fix: homelab-ca Secret vorhanden?
kubectl get secret homelab-ca -n productivity
# Falls nicht: make cert-sync
```

### OIDC-Login: "invalid_scope"

`groups` darf nicht im `oidc_login_scope` stehen. In `oidc.config.php` muss stehen:

```php
'oidc_login_scope' => 'openid profile email',
```

### OIDC-Login: "Auto creating new users is disabled"

`oidc_login_disable_registration` hat in oidc_login 3.x den Default `true` (invertierte
Logik). Muss explizit auf `false` gesetzt werden – ist in `oidc.config.php` bereits so
konfiguriert. Falls der Fehler trotzdem auftritt:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ config:system:set \
      oidc_login_disable_registration --value=false --type=boolean
  "
```

### OIDC-Login: "authentication_expired" / "PKCE code verifier not specified"

Bekanntes Session-Timing-Problem beim allerersten Login. Einfach nochmal auf
**"Mit Keycloak anmelden"** klicken.

### Storage Box: "Ordner nicht gefunden"

Das `fpm-alpine` Image hat keine `php-ssh2` Extension → SFTP-Mounts funktionieren nicht.
Nur **WebDAV** verwenden:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

# SFTP-Mount löschen und als WebDAV neu anlegen
./scripts/setup-nextcloud-storage.sh --reset
```

### Nextcloud-Installation schlägt fehl (config.php leer)

Das Chart legt bei jedem Pod-Start eine leere `config.php` als Placeholder an.
Der postStart Hook erkennt das und entfernt sie vor der Installation automatisch.
Falls es trotzdem hängt:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

# config.php manuell löschen
kubectl exec -n productivity ${POD} -c nextcloud -- \
  rm -f /var/www/html/config/config.php

# Pod neu starten
kubectl rollout restart deployment/nextcloud -n productivity
```

### Nextcloud startet nicht (CrashLoopBackOff)

```bash
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
    -o jsonpath='{.items[0].metadata.name}') \
  -c nextcloud --previous
```

Häufige Ursachen: Secret fehlt, PostgreSQL nicht erreichbar, PVC nicht gebunden.

### OOMKilled

Memory Limit in `nextcloud.yaml` erhöhen:

```yaml
resources:
  limits:
    memory: 2Gi  # von 1Gi auf 2Gi
```

Dann committen und pushen – ArgoCD updated automatisch.
