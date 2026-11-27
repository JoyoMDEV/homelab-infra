# Group Management Runbook

Zentrales Gruppen-Management für das Homelab via Keycloak → Services.

**Konzept:**
```
Keycloak Realm homelab (Source of Truth)
  └── Gruppen und Mitgliedschaften
        └── OIDC Token (groups claim)
              └── Service RBAC (Admin/User)
```

User und Gruppen sind lokale Keycloak-Objekte im Realm `homelab`. Passwörter
und Gruppenmitgliedschaften liegen in Keycloak, es gibt keinen externen
Verzeichnisdienst und keinen Sync mehr.

---

## Inhaltsverzeichnis

1. [Gruppen-Übersicht](#1-gruppen-übersicht)
2. [Neuen User anlegen](#2-neuen-user-anlegen)
3. [User Gruppen zuweisen](#3-user-gruppen-zuweisen)
4. [Neue Gruppe anlegen](#4-neue-gruppe-anlegen)
5. [Service-Konfiguration](#5-service-konfiguration)
   - [ArgoCD](#argocd)
   - [Vault](#vault)
   - [Nextcloud](#nextcloud)
   - [Paperless](#paperless)
   - [Vaultwarden](#vaultwarden)
6. [kcadm.sh im Pod](#6-kcadmsh-im-pod)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Gruppen-Übersicht

Alle Gruppen sind Keycloak-Gruppen im Realm `homelab` (Top-Level, kein Pfad).

| Gruppe | Service | Rolle |
|---|---|---|
| `homelab-admins` | Vault, Keycloak | Full Admin |
| `argocd-admins` | ArgoCD | role:admin |
| `nextcloud-admins` | Nextcloud | Admin |
| `paperless-admins` | Paperless-ngx | Superuser |
| `vaultwarden-admins` | Vaultwarden | Admin |

`gitlab-admins`, `grafana-admins`, `homarr-admins` und `nocodb-admins` sind Reste entfernter Services und können gelöscht werden.

---

## 2. Neuen User anlegen

### Via Admin-UI

1. https://auth.homelab.local → Realm `homelab` → **Users** → **"Add user"**
2. Username, E-Mail, Vorname, Nachname ausfüllen, **"Email verified"** auf ON → **"Create"**
3. Tab **"Credentials"** → **"Set password"**, `Temporary` auf OFF, wenn der User das Passwort nicht beim ersten Login ändern soll
4. Tab **"Groups"** → **"Join Group"** → passende Gruppen auswählen (siehe Abschnitt 3)

### Via kcadm.sh

Vorher einloggen, siehe [Abschnitt 6](#6-kcadmsh-im-pod).

```bash
kcadm create users -r homelab \
  -s username=<username> -s enabled=true -s emailVerified=true \
  -s email=<username>@homelab.local \
  -s firstName='<Vorname>' -s lastName='<Nachname>'

kcadm set-password -r homelab --username <username> --new-password '<passwort>'
```

---

## 3. User Gruppen zuweisen

### Via Admin-UI

Realm `homelab` → **Users** → User auswählen → Tab **"Groups"** → **"Join Group"** → Gruppe(n) auswählen → **"Join"**

Entfernen: im selben Tab die Gruppe markieren → **"Leave"**

Alternativ von der Gruppe aus: **Groups** → Gruppe → Tab **"Members"** → **"Add member"**

### Via kcadm.sh

```bash
kcadm() { kubectl -n auth exec -i keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh "$@"; }

# IDs nachschlagen
USER_ID=$(kcadm get users -r homelab -q username=<username> --fields id --format csv --noquotes)
GROUP_ID=$(kcadm get groups -r homelab -q search=<gruppe> --fields id --format csv --noquotes)

# Gruppe zuweisen
kcadm update users/$USER_ID/groups/$GROUP_ID -r homelab -s realm=homelab -s userId=$USER_ID -s groupId=$GROUP_ID -n

# Gruppe entfernen
kcadm delete users/$USER_ID/groups/$GROUP_ID -r homelab

# Gruppen eines Users anzeigen
kcadm get users/$USER_ID/groups -r homelab --fields name
```

Neue Gruppenmitgliedschaften wirken erst mit einem neuen Token, also nach erneutem Login (siehe Troubleshooting).

---

## 4. Neue Gruppe anlegen

### Via Admin-UI

Realm `homelab` → **Groups** → **"Create group"** → Name eingeben → **"Create"**

### Via kcadm.sh

```bash
kcadm create groups -r homelab -s name=<neue-gruppe>
```

Danach:
1. User zuweisen (Abschnitt 3)
2. Service konfigurieren (Abschnitt 5)
3. Prüfen, ob der Keycloak-Client des Service einen `groups` Mapper hat (siehe Troubleshooting)

---

## 5. Service-Konfiguration

### ArgoCD

**Status: ✅ konfiguriert**

Konfiguration in `k8s/values/argocd.yaml`:
```yaml
configs:
  rbac:
    policy.csv: |
      g, argocd-admins, role:admin
    policy.default: role:readonly
    scopes: '[groups]'
```

Keycloak Client `argocd` → Client Scopes → `argocd-dedicated` → Mapper `groups` muss vorhanden sein.

---

### Vault

**Status: ✅ konfiguriert**

- `homelab-admins` → `admin` Policy (Vollzugriff)
- Alle anderen → `reader` Policy

OIDC Role in Vault:
```bash
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<token> \
  vault read auth/oidc/role/homelab-admin
```

---

### Nextcloud

**Status: ⚠️ teilweise konfiguriert**

`oidc.config.php` mappt die Gruppen bereits. Admin-Gruppe setzen:

```bash
POD=$(kubectl get pod -n productivity -l app.kubernetes.io/name=nextcloud \
  -o jsonpath='{.items[0].metadata.name}')

# Admin-Gruppe konfigurieren
kubectl exec -n productivity $POD -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ config:system:set \
      oidc_login_admin_groups \
      --value='[\"nextcloud-admins\"]' \
      --type=json
  "

# Verifikation
kubectl exec -n productivity $POD -- \
  su -s /bin/sh www-data -c "
    php /var/www/html/occ config:system:get oidc_login_admin_groups
  "
```

Keycloak Client `nextcloud` → Client Scopes → `nextcloud-dedicated` → Mapper `groups` muss vorhanden sein.

---

### Paperless

**Status: ⚠️ manuell**

Django-Allauth unterstützt kein automatisches Superuser-Mapping via OIDC.
Superuser-Status manuell setzen:

```bash
POD=$(kubectl get pod -n productivity \
  -l app.kubernetes.io/name=paperless-ngx \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n productivity $POD -c paperless-ngx -- \
  python3 manage.py shell -c "
from django.contrib.auth.models import User
u = User.objects.get(username='<username>')
u.is_staff = True
u.is_superuser = True
u.save()
print(f'User {u.username}: superuser={u.is_superuser}')
"
```

---

### Vaultwarden

**Status: ⚠️ manuell**

Vaultwarden hat kein OIDC-Gruppen-Mapping für Admin-Rechte.
Admin-Panel ist Token-basiert:

**https://vault.homelab.local/admin** → Admin Token aus Vault:

```bash
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<token> \
  vault kv get -field=admin-token secret/homelab/security/vaultwarden-secret
```

---

## 6. kcadm.sh im Pod

Das Keycloak-Admin-CLI liegt im Pod unter `/opt/keycloak/bin/kcadm.sh`. Die Admin-Zugangsdaten stehen dort als Umgebungsvariablen `KEYCLOAK_ADMIN` und `KEYCLOAK_ADMIN_PASSWORD` bereit. Einmal einloggen, die Session wird im Pod gespeichert und gilt für die folgenden `kcadm.sh`-Aufrufe:

```bash
kubectl -n auth exec -i keycloak-keycloakx-0 -- sh -c \
  '/opt/keycloak/bin/kcadm.sh config credentials \
     --server "http://localhost:8080${KC_HTTP_RELATIVE_PATH}" \
     --realm master \
     --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"'
```

Die einfachen Anführungszeichen sind wichtig, damit die Variablen im Pod und nicht lokal aufgelöst werden.

Für alle weiteren Aufrufe diese Shell-Funktion definieren (in den Beispielen dieses Runbooks vorausgesetzt):

```bash
kcadm() { kubectl -n auth exec -i keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh "$@"; }
```

Eine Funktion statt einer Variablen wie `KCADM="kubectl ..."`: zsh (Standard auf macOS) teilt Variablen beim Aufruf nicht in Wörter auf, `$KCADM get ...` schlägt dort fehl. Ohne `-t` gibt es außerdem keine `\r` in der Ausgabe von `$(...)`. Getestet am 2026-11-27: Gruppe anlegen, beitreten, austreten, löschen.

Nützliche Abfragen:

```bash
kcadm() { kubectl -n auth exec -i keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh "$@"; }

kcadm get users -r homelab --fields username,email,enabled
kcadm get groups -r homelab --fields name
kcadm get groups/<group-id>/members -r homelab --fields username
```

---

## 7. Troubleshooting

### User sieht keine Admin-Rechte nach Login

1. Prüfen ob User in der Gruppe ist:
   **Users → `<username>` → Tab "Groups"**

2. Session invalidieren (Keycloak):
   **Users → `<username>` → Tab "Sessions" → "Logout all sessions"**

3. Neu einloggen im Browser (privates Fenster)

### OIDC Token enthält keine Gruppen

Keycloak Client → Client Scopes → `<client>-dedicated` → Mappers:
- `groups` Mapper vorhanden?
- `Add to ID token: ON`?
- `Full group path: OFF`?

Mapper anlegen, falls er fehlt (**Add mapper → By configuration → Group Membership**):

| Feld | Wert |
|---|---|
| Name | `groups` |
| Token Claim Name | `groups` |
| Full group path | `OFF` |
| Add to ID token | `ON` |
| Add to access token | `ON` |
| Add to userinfo | `ON` |

Ob der Claim im Token landet, lässt sich in der Admin-UI prüfen:
**Clients → `<client>` → Tab "Client scopes" → Sub-Tab "Evaluate"** → User auswählen → **"Generated ID token"**.
