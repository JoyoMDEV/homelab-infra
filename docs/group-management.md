# Group Management Runbook

Zentrales Gruppen-Management für das Homelab via Samba AD → Keycloak → Services.

**Konzept:**
```
Samba AD (Source of Truth)
  └── Gruppen in OU=HomelabGroups
        └── Keycloak LDAP Group Mapper (sync)
              └── OIDC Token (groups claim)
                    └── Service RBAC (Admin/User)
```

---

## Inhaltsverzeichnis

1. [Gruppen-Übersicht](#1-gruppen-übersicht)
2. [Neuen Admin-User anlegen](#2-neuen-admin-user-anlegen)
3. [User Gruppen zuweisen](#3-user-gruppen-zuweisen)
4. [Neue Gruppe anlegen](#4-neue-gruppe-anlegen)
5. [Service-Konfiguration](#5-service-konfiguration)
   - [ArgoCD](#argocd)
   - [Vault](#vault)
   - [Grafana](#grafana)
   - [GitLab](#gitlab)
   - [Nextcloud](#nextcloud)
   - [Paperless](#paperless)
   - [NocoDB](#nocodb)
   - [Homarr](#homarr)
   - [Vaultwarden](#vaultwarden)
6. [Keycloak Gruppen-Sync](#6-keycloak-gruppen-sync)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Gruppen-Übersicht

Alle Gruppen liegen in `OU=HomelabGroups,DC=homelab,DC=local`.

| Gruppe | Service | Rolle |
|---|---|---|
| `homelab-admins` | Vault, Keycloak | Full Admin |
| `argocd-admins` | ArgoCD | role:admin |
| `gitlab-admins` | GitLab | Administrator |
| `grafana-admins` | Grafana | Admin |
| `nextcloud-admins` | Nextcloud | Admin |
| `paperless-admins` | Paperless-ngx | Superuser |
| `nocodb-admins` | NocoDB | Org Admin |
| `homarr-admins` | Homarr | Admin |
| `vaultwarden-admins` | Vaultwarden | Admin |

---

## 2. Neuen Admin-User anlegen

```bash
SERVER_IP=$(cd terraform && terraform output -raw k3s_server_ip)

# Samba Admin Passwort aus Vault
SAMBA_PW=$(kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token> \
  vault kv get -field=password secret/homelab/samba/admin 2>/dev/null || \
  echo "<manuell eingeben>")

# User anlegen
ssh root@${SERVER_IP} \
  "samba-tool user create <username> \
   --given-name='<Vorname>' \
   --surname='<Nachname>' \
   --mail-address='<username>@homelab.local' \
   -U Administrator --password='${SAMBA_PW}'"
```

Danach Keycloak sync triggern:
**User Federation → `samba-ad` → "Synchronize all users"**

---

## 3. User Gruppen zuweisen

### Via Samba AD (empfohlen — Source of Truth)

```bash
SERVER_IP=$(cd terraform && terraform output -raw k3s_server_ip)

# Einzelne Gruppe
ssh root@${SERVER_IP} \
  "samba-tool group addmembers '<gruppe>' '<username>' \
   -U Administrator --password='<pw>'"

# Alle Admin-Gruppen auf einmal
for GROUP in homelab-admins argocd-admins gitlab-admins grafana-admins \
             nextcloud-admins paperless-admins nocodb-admins \
             homarr-admins vaultwarden-admins; do
  ssh root@${SERVER_IP} \
    "samba-tool group addmembers '${GROUP}' '<username>' \
     -U Administrator --password='<pw>'" 2>&1 | grep -v WARNING
  echo "✓ <username> → ${GROUP}"
done
```

Danach Keycloak Group Mapper sync triggern:
**User Federation → `samba-ad` → Mappers → `ad-groups` → "Sync LDAP Groups to Keycloak"**

### User aus Gruppe entfernen

```bash
ssh root@${SERVER_IP} \
  "samba-tool group removemembers '<gruppe>' '<username>' \
   -U Administrator --password='<pw>'"
```

---

## 4. Neue Gruppe anlegen

```bash
# Script nutzen (legt Gruppe in OU=HomelabGroups an)
./scripts/setup-ad-groups.sh

# Oder manuell
ssh root@${SERVER_IP} \
  "samba-tool group add '<neue-gruppe>' \
   --description='<Beschreibung>' \
   --groupou='OU=HomelabGroups' \
   -U Administrator --password='<pw>'"
```

Danach:
1. Keycloak sync triggern
2. Service konfigurieren (siehe Abschnitt 5)
3. Keycloak Client Groups Mapper prüfen

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

### Grafana

**Status: ✅ konfiguriert**

Konfiguration in `k8s/argocd/applications/monitoring.yaml`:
```yaml
role_attribute_path: >-
  contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'
```

Keycloak Client `grafana` → Client Scopes → `grafana-dedicated` → Mapper `groups` muss vorhanden sein.

---

### GitLab

**Status: ⚠️ manuell**

GitLab unterstützt kein automatisches Admin-Mapping via OIDC-Gruppen.
Admin-Status muss manuell gesetzt werden:

**Via UI:**
Admin Area → Users → `<username>` → Edit → Access Level: Administrator → Save

**Via CLI:**
```bash
kubectl exec -n gitlab \
  $(kubectl get pod -n gitlab -l app=gitlab \
    -o jsonpath='{.items[0].metadata.name}') -- \
  gitlab-rails runner \
  "User.find_by_username('<username>').update!(admin: true)"
```

Keycloak Client `gitlab` → Client Scopes → `gitlab-dedicated` → Mapper `groups` muss vorhanden sein (für GitLab-Gruppen-Sync).

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

### NocoDB

**Status: ⚠️ manuell**

NocoDB unterstützt kein OIDC-Gruppen-Mapping für Admin-Rechte.
Admin-Status in NocoDB UI setzen:

**https://nocodb.homelab.local → Team & Auth → User als Org-Admin setzen**

---

### Homarr

**Status: ⚠️ manuell / OIDC**

Homarr nutzt OIDC für Auth aber hat kein Gruppen-basiertes Admin-Mapping.
Ersten User der sich einloggt automatisch als Admin setzen oder in den
Homarr-Settings manuell konfigurieren.

Keycloak Client `homarr` → Client Scopes → `homarr-dedicated` → Mapper `groups` anlegen:

| Feld | Wert |
|---|---|
| Name | `groups` |
| Token Claim Name | `groups` |
| Full group path | `OFF` |
| Add to ID token | `ON` |

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

## 6. Keycloak Gruppen-Sync

### Manueller Sync (nach AD-Änderungen)

**User Federation → `samba-ad` → "Synchronize all users"**

Oder Gruppen-Mapper spezifisch:
**User Federation → `samba-ad` → Mappers → `ad-groups` → "Sync LDAP Groups to Keycloak"**

### Automatischer Sync

Konfiguriert in der LDAP Federation:
- Full sync: alle 24h (`86400` Sekunden)
- Changed users sync: stündlich (`3600` Sekunden)

### Gruppen-Claim im Token prüfen

```bash
# Token für einen User holen und Groups-Claim prüfen
curl -s -X POST \
  https://auth.homelab.local/realms/homelab/protocol/openid-connect/token \
  -d "client_id=argocd&grant_type=password&username=<user>&password=<pw>" \
  | python3 -m json.tool | grep -A5 groups
```

---

## 7. Troubleshooting

### User sieht keine Admin-Rechte nach Login

1. Prüfen ob User in AD-Gruppe ist:
```bash
ssh root@${SERVER_IP} \
  "samba-tool user getgroups '<username>' -U Administrator --password='<pw>'"
```

2. Prüfen ob Gruppe in Keycloak synct:
**Users → `<username>` → Tab "Groups"**

3. Session invalidieren (Keycloak):
**Users → `<username>` → Tab "Sessions" → "Logout all sessions"**

4. Neu einloggen im Browser (privates Fenster)

### Gruppen erscheinen nicht in Keycloak

```bash
# LDAP Verbindung testen
kubectl run -it --rm ldap-test --image=alpine --restart=Never -- \
  sh -c "apk add -q openldap-clients && \
  ldapsearch -x -H ldap://<tailscale-ip>:389 \
  -D 'CN=Administrator,CN=Users,DC=homelab,DC=local' \
  -w '<pw>' \
  -b 'OU=HomelabGroups,DC=homelab,DC=local' \
  '(objectClass=group)' cn"
```

### OIDC Token enthält keine Gruppen

Keycloak Client → Client Scopes → `<client>-dedicated` → Mappers:
- `groups` Mapper vorhanden?
- `Add to ID token: ON`?
- `Full group path: OFF`?
