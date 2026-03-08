# Paperless-ngx Setup Runbook

Einmaliger Setup-Guide für Paperless-ngx im Homelab.
Paperless-ngx läuft unter **https://paperless.homelab.local**.

Paperless-ngx ist ein digitales Dokumentenmanagementsystem mit OCR, automatischer Klassifizierung und Volltextsuche.

**Voraussetzungen:**
- Kubernetes-Cluster läuft: `make status`
- ArgoCD erreichbar: https://argocd.homelab.local
- Keycloak läuft: https://auth.homelab.local
- PostgreSQL (CNPG) läuft: `kubectl get cluster -n infrastructure`
- Redis läuft: `kubectl get pods -n infrastructure | grep redis`
- CoreDNS konfiguriert: `make setup-coredns`
- CA importiert: `make cert-ca`

---

## Inhaltsverzeichnis

1. [Architektur](#1-architektur)
2. [Datenbank und Secrets anlegen](#2-datenbank-und-secrets-anlegen)
3. [Keycloak OIDC-Client anlegen](#3-keycloak-oidc-client-anlegen)
4. [CoreDNS Eintrag setzen](#4-coredns-eintrag-setzen)
5. [Paperless deployen](#5-paperless-deployen)
6. [Ersten Admin-User anlegen](#6-ersten-admin-user-anlegen)
7. [Consumption-Verzeichnis einrichten](#7-consumption-verzeichnis-einrichten)
8. [Verifikation](#8-verifikation)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Architektur

```
Dokument (Upload / Consumption-Ordner)
  └── Paperless-ngx Pod (namespace: productivity)
        ├── Tika Sidecar   ← Extraktion aus DOCX, XLSX, PPTX, etc.
        ├── Gotenberg Sidecar ← PDF-Konvertierung (LibreOffice im Container)
        └── Tesseract OCR  ← integriert in Paperless (deu+eng)

Persistence:
  /data/consume  → PVC 5Gi   (Inbox: neu abzulegende Dokumente)
  /data/data     → PVC 20Gi  (interne DB-Dateien, Suchindex)
  /data/media    → PVC 50Gi  (gespeicherte Originale + Thumbnails)
  /data/export   → PVC 5Gi   (manuell exportierte Archive)

Externe Services:
  PostgreSQL (CNPG) → homelab-pg-rw.infrastructure
  Redis             → redis-master.infrastructure
  Keycloak          → auth.homelab.local (OIDC Login)
```

**Tika** extrahiert Text aus Office-Dokumenten (DOCX, XLSX, PPTX, ODT, etc.)
**Gotenberg** konvertiert diese in PDFs für die Archivierung.
Beide laufen als Sidecar-Container im selben Pod — kein externer Netzwerktraffic.

---

## 2. Datenbank und Secrets anlegen

```bash
chmod +x scripts/setup-paperless.sh
./scripts/setup-paperless.sh
```

Das Script:
- Legt PostgreSQL Datenbank `paperless` + User an
- Liest Redis-Passwort aus bestehendem Secret
- Fragt interaktiv nach dem Keycloak OIDC Client Secret
- Erstellt `paperless-secret` im Namespace `productivity`

### Secret manuell aktualisieren

```bash
# OIDC Secret nachträglich setzen (nach Keycloak-Setup)
kubectl patch secret paperless-secret -n productivity \
  --type merge \
  -p '{"stringData":{"oidc-client-secret":"<DEIN_SECRET_HIER>"}}'
```

---

## 3. Keycloak OIDC-Client anlegen

**Navigation:** https://auth.homelab.local → Realm `homelab` → **Clients** → **"Create client"**

### 3.1 General Settings

| Feld | Wert |
|------|------|
| Client type | `OpenID Connect` |
| Client ID | `paperless` |
| Name | `Paperless-ngx` |

→ **Next**

### 3.2 Capability Config

| Feld | Wert |
|------|------|
| Client authentication | ON (confidential client) |
| Authorization | OFF |
| Standard flow | ON |
| Direct access grants | OFF |

→ **Next**

### 3.3 Login Settings

| Feld | Wert |
|------|------|
| Root URL | `https://paperless.homelab.local` |
| Home URL | `https://paperless.homelab.local` |
| Valid redirect URIs | `https://paperless.homelab.local/accounts/keycloak/login/callback/` |
| Valid post logout redirect URIs | `https://paperless.homelab.local` |
| Web origins | `https://paperless.homelab.local` |

→ **Save**

### 3.4 Client Secret in Kubernetes eintragen

1. Tab **"Credentials"** öffnen
2. **"Client secret"** kopieren
3. Secret in Kubernetes eintragen:

```bash
kubectl patch secret paperless-secret -n productivity \
  --type merge \
  -p '{"stringData":{"oidc-client-secret":"<DEIN_SECRET_HIER>"}}'
```

### 3.5 Gruppen-Claim konfigurieren (optional)

Falls Paperless-Gruppen aus Keycloak-Gruppen befüllt werden sollen:

1. Client `paperless` → Tab **"Client scopes"**
2. Klick auf `paperless-dedicated`
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

---

## 4. CoreDNS Eintrag setzen

`paperless.homelab.local` ist bereits in `scripts/setup-coredns.sh` eingetragen.
Falls du das Script vorher ausgeführt hast, einmal neu ausführen:

```bash
make setup-coredns
```

Manuell prüfen:
```bash
kubectl get configmap coredns-custom -n kube-system -o yaml | grep paperless
```

---

## 5. Paperless deployen

```bash
# ArgoCD Application committen
git add k8s/argocd/applications/paperless.yaml
git commit -m "feat: add Paperless-ngx for document management"
git push
```

ArgoCD synct automatisch. Fortschritt beobachten:

```bash
# Pod Status (Tika + Gotenberg + Paperless = 3 Container)
kubectl get pods -n productivity -l app.kubernetes.io/name=paperless-ngx -w

# Logs
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}') \
  -c paperless-ngx --follow
```

> **Erster Start dauert 3–5 Minuten** wegen DB-Migration und Tika-Start.

---

## 6. Ersten Admin-User anlegen

Beim ersten Start muss ein Superuser angelegt werden. Danach können sich alle
Nutzer per Keycloak OIDC anmelden — der lokale Admin dient nur als Fallback.

```bash
POD=$(kubectl get pod -n productivity \
  -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  python3 manage.py createsuperuser \
  --username admin \
  --email admin@homelab.local
```

> Passwort wird interaktiv abgefragt.
> Diesen Admin in Ansible Vault sichern!

---

## 7. Consumption-Verzeichnis einrichten

Das Consumption-Verzeichnis ist der "Posteingang" für neue Dokumente.
Dateien die dort abgelegt werden, verarbeitet Paperless automatisch (OCR, Indexierung, Klassifizierung).

### 7.1 Per kubectl direkt hochladen (einfachste Methode)

```bash
POD=$(kubectl get pod -n productivity \
  -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

# Einzelnes PDF hochladen
kubectl cp /lokaler/pfad/dokument.pdf \
  productivity/${POD}:/data/consume/dokument.pdf -c paperless-ngx

# Verzeichnis hochladen
kubectl cp /lokaler/pfad/dokumente/ \
  productivity/${POD}:/data/consume/ -c paperless-ngx
```

### 7.2 Automatisch per Nextcloud

Falls du Nextcloud nutzt, kannst du dort einen Ordner anlegen der via WebDAV
auf das Consumption-Verzeichnis zeigt — oder einfach Dateien in Nextcloud ablegen
und von dort manuell ins Consumption-Verzeichnis schieben.

**Geplante Erweiterung:** Consumption-Ordner auf Storage Box via WebDAV einbinden
(analog Nextcloud External Storage) — dann kannst du Dokumente per WebDAV
von jedem Gerät einwerfen.

### 7.3 Consumption per E-Mail (IMAP)

Paperless kann ein IMAP-Postfach überwachen und Anhänge automatisch einlesen.
Konfiguration in `paperless.yaml` unter `env`:

```yaml
PAPERLESS_EMAIL_HOST: mail.your-server.de
PAPERLESS_EMAIL_PORT: "993"
PAPERLESS_EMAIL_HOST_USER: paperless@deine-domain.de
PAPERLESS_EMAIL_HOST_PASSWORD: "$(EMAIL_PASSWORD)"
PAPERLESS_EMAIL_SECURITY: SSL
```

---

## 8. Verifikation

### Paperless erreichbar

```bash
curl -sf https://paperless.homelab.local/api/ | python3 -m json.tool | head -5
```

### Alle Container laufen

```bash
kubectl get pod -n productivity \
  -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{range .items[0].status.containerStatuses[*]}{.name}: {.ready}{"\n"}{end}'
# Erwartete Ausgabe:
# paperless-ngx: true
# gotenberg: true
# tika: true
```

### OCR funktioniert (Tika)

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  curl -sf http://localhost:9998/tika | grep -i tika
```

### PDF-Konvertierung (Gotenberg)

```bash
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  curl -sf http://localhost:3000/health
# Erwartete Ausgabe: {"status": "up"}
```

### OIDC Login testen

1. https://paperless.homelab.local in **privatem Fenster** öffnen
2. Button **"Log in with Keycloak"** erscheint auf der Login-Seite
3. AD-Credentials eingeben
4. Paperless legt automatisch einen neuen User an

### Keycloak OIDC Discovery testen

```bash
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  curl -sf \
  https://auth.homelab.local/realms/homelab/.well-known/openid-configuration \
  | python3 -m json.tool | grep issuer
```

---

## 9. Troubleshooting

### Pod startet nicht (CrashLoopBackOff)

```bash
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}') \
  -c paperless-ngx --previous
```

Häufige Ursachen:
- Secret `paperless-secret` fehlt → `./scripts/setup-paperless.sh`
- PostgreSQL nicht erreichbar → `kubectl get cluster -n infrastructure`
- Redis nicht erreichbar → `kubectl get pods -n infrastructure | grep redis`

### Tika startet nicht

```bash
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}') \
  -c tika --tail=50
```

Tika benötigt mindestens 256 MB RAM. Falls OOMKilled:

```yaml
# In paperless.yaml unter sidecars → tika:
resources:
  limits:
    memory: 1Gi
```

### Gotenberg startet nicht

```bash
kubectl logs -n productivity \
  $(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
    -o jsonpath='{.items[0].metadata.name}') \
  -c gotenberg --tail=50
```

### OIDC Login: "SSL certificate problem"

Die homelab-CA wird per `extraVolumeMounts` in `/usr/local/share/ca-certificates/`
eingebunden. Paperless (Debian-basiert) liest diesen Pfad automatisch via
`update-ca-certificates`.

Falls der Fehler trotzdem auftritt:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

# CA im Container prüfen
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  ls -la /usr/local/share/ca-certificates/

# CA manuell aktualisieren
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  update-ca-certificates
```

### OIDC Login: Redirect URI Mismatch

Die Redirect URI in Keycloak muss exakt stimmen:

```
https://paperless.homelab.local/accounts/keycloak/login/callback/
```

Beachte den **trailing slash** — ohne diesen schlägt der Redirect fehl.

### Dokumente werden nicht verarbeitet (Consumption-Verzeichnis)

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

# Consumer-Logs prüfen
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  tail -f /var/log/paperless/consumer.log

# Berechtigungen im Consumption-Verzeichnis prüfen
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  ls -la /data/consume/
```

Paperless-ngx prüft das Consumption-Verzeichnis standardmäßig alle 10 Sekunden.

### OOMKilled (Paperless, Tika oder Gotenberg)

Memory Limits in `paperless.yaml` erhöhen und committen:

```yaml
# Paperless Container
resources:
  limits:
    memory: 4Gi  # von 2Gi

# Tika Sidecar
sidecars:
  - name: tika
    resources:
      limits:
        memory: 1Gi  # von 512Mi

# Gotenberg Sidecar
  - name: gotenberg
    resources:
      limits:
        memory: 1Gi  # von 512Mi
```

### DB-Migration schlägt fehl

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  python3 manage.py migrate --check
```

Falls Migrationen ausstehen:

```bash
kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  python3 manage.py migrate
```

### Superuser vergessen / Passwort zurücksetzen

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity ${POD} -c paperless-ngx -- \
  python3 manage.py changepassword admin
```
