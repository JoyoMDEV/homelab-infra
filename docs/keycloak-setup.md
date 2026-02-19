# Keycloak Setup Runbook

Einmaliger Setup-Guide für Keycloak SSO im Homelab.
Keycloak läuft bereits unter **https://auth.homelab.local**.

**Voraussetzungen:**
- Keycloak Pod ist `Running`: `kubectl get pods -n auth`
- Samba AD DC läuft: `make status`
- Du bist im Tailscale-Netz
- CoreDNS für `*.homelab.local` konfiguriert:
  ```bash
  make setup-coredns
  ```
  > Ohne diesen Schritt können Pods (z.B. GitLab) `auth.homelab.local` nicht
  > auflösen und OIDC-Logins schlagen mit "getaddrinfo: name or service not known" fehl. und CA ist importiert

---

## Inhaltsverzeichnis

1. [Admin-Passwort auslesen](#1-admin-passwort-auslesen)
2. [Realm anlegen](#2-realm-homelab-anlegen)
3. [LDAP-Federation mit Samba AD](#3-ldap-federation-mit-samba-ad)
4. [OIDC-Client: GitLab](#4-oidc-client-gitlab)
5. [OIDC-Client: ArgoCD](#5-oidc-client-argocd)
6. [OIDC-Client: Grafana](#6-oidc-client-grafana-vorbereitung)
7. [OIDC-Client: Nextcloud](#7-oidc-client-nextcloud-vorbereitung)
8. [GitLab OIDC aktivieren](#8-gitlab-oidc-aktivieren)
9. [ArgoCD OIDC aktivieren](#9-argocd-oidc-aktivieren)
10. [Verifikation](#10-verifikation)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. Admin-Passwort auslesen

```bash
kubectl get secret keycloak-secret -n auth \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

Login: https://auth.homelab.local
User: `admin` / Passwort aus dem Befehl oben

---

## 2. Realm `homelab` anlegen

1. Oben links auf das Dropdown **"master"** klicken
2. **"Create realm"** klicken
3. Felder ausfüllen:

| Feld | Wert |
|------|------|
| Realm name | `homelab` |
| Enabled | ON |

4. **"Create"** klicken
5. Du bist jetzt automatisch im Realm `homelab`

---

## 3. LDAP-Federation mit Samba AD

> Verbindet Keycloak mit dem Samba AD DC. Benutzer aus dem AD können sich danach
> mit ihren AD-Credentials bei allen OIDC-Services anmelden.

**Navigation:** Realm `homelab` → **User Federation** → **"Add provider"** → **LDAP**

### 3.1 Connection

| Feld | Wert |
|------|------|
| UI display name | `samba-ad` |
| Vendor | `Active Directory` |
| Connection URL | `ldap://<tailscale-ip-des-servers>:389` |
| Enable StartTLS | OFF (Tailscale verschlüsselt die Verbindung) |
| Use Truststore SPI | `Only for ldaps` |
| Connection pooling | ON |
| Connection timeout | `5000` |
| Read timeout | `10000` |

> Tailscale-IP des Servers:
> ```bash
> ssh root@<server-public-ip> tailscale ip -4
> ```

### 3.2 Bind

| Feld | Wert |
|------|------|
| Bind type | `simple` |
| Bind DN | `CN=Administrator,CN=Users,DC=homelab,DC=local` |
| Bind credentials | `<samba_admin_password>` |

> Samba Admin-Passwort auslesen:
> ```bash
> cd ansible && ansible-vault view inventory/group_vars/all/vault.yml
> # → vault_samba_admin_password
> ```

### 3.3 LDAP Searching and Updating

| Feld | Wert |
|------|------|
| Edit mode | `READ_ONLY` |
| Users DN | `CN=Users,DC=homelab,DC=local` |
| Username LDAP attribute | `sAMAccountName` |
| RDN LDAP attribute | `cn` |
| UUID LDAP attribute | `objectGUID` |
| User object classes | `person, organizationalPerson, user` |
| User LDAP filter | *(leer lassen)* |
| Search scope | `Subtree` |
| Pagination | ON |

### 3.4 Synchronization

| Feld | Wert |
|------|------|
| Import users | ON |
| Sync Registrations | OFF |
| Periodic full sync | ON |
| Full sync period | `86400` (1x täglich) |
| Periodic changed users sync | ON |
| Changed users sync period | `3600` (stündlich) |

4. **"Save"** klicken
5. **"Test connection"** → muss grün werden ✅
6. **"Test authentication"** → muss grün werden ✅
7. **"Synchronize all users"** klicken

> Erfolgreich wenn unter **Users** die AD-Benutzer erscheinen.

---

## 4. OIDC-Client: GitLab

**Navigation:** Realm `homelab` → **Clients** → **"Create client"**

### 4.1 General Settings

| Feld | Wert |
|------|------|
| Client type | `OpenID Connect` |
| Client ID | `gitlab` |
| Name | `GitLab` |

→ **Next**

### 4.2 Capability Config

| Feld | Wert |
|------|------|
| Client authentication | ON (confidential client) |
| Authorization | OFF |
| Standard flow | ON |
| Direct access grants | OFF |

→ **Next**

### 4.3 Login Settings

| Feld | Wert |
|------|------|
| Root URL | `https://gitlab.homelab.local` |
| Home URL | `https://gitlab.homelab.local` |
| Valid redirect URIs | `https://gitlab.homelab.local/users/auth/openid_connect/callback` |
| Valid post logout redirect URIs | `https://gitlab.homelab.local` |
| Web origins | `https://gitlab.homelab.local` |

→ **Save**

### 4.4 Client Secret in Kubernetes eintragen

1. Tab **"Credentials"** öffnen
2. **"Client secret"** kopieren
3. Secret in Kubernetes aktualisieren:

```bash
kubectl patch secret gitlab-secret -n gitlab \
  --type merge \
  -p '{"stringData":{"oidc-client-secret":"<DEIN_SECRET_HIER>"}}'
```

---

## 5. OIDC-Client: ArgoCD

**Navigation:** Realm `homelab` → **Clients** → **"Create client"**

### 5.1 General Settings

| Feld | Wert |
|------|------|
| Client type | `OpenID Connect` |
| Client ID | `argocd` |
| Name | `ArgoCD` |

→ **Next**

### 5.2 Capability Config

| Feld | Wert |
|------|------|
| Client authentication | ON |
| Standard flow | ON |
| Direct access grants | OFF |

→ **Next**

### 5.3 Login Settings

| Feld | Wert |
|------|------|
| Root URL | `https://argocd.homelab.local` |
| Valid redirect URIs | `https://argocd.homelab.local/auth/callback` |
| Valid post logout redirect URIs | `https://argocd.homelab.local` |
| Web origins | `https://argocd.homelab.local` |

→ **Save**

### 5.4 Client Secret in Kubernetes eintragen

```bash
kubectl create secret generic argocd-keycloak-secret \
  --from-literal=oidc.keycloak.clientSecret="<DEIN_SECRET_HIER>" \
  -n argocd
```

### 5.5 ArgoCD Admin-Gruppe anlegen

Damit AD-Benutzer Admin-Rechte in ArgoCD bekommen:

1. Realm `homelab` → **Groups** → **"Create group"**
2. Name: `argocd-admins`
3. Deinen AD-Benutzer der Gruppe zuweisen:
   **Users** → Benutzer auswählen → Tab **"Groups"** → `argocd-admins` joinen

---

## 6. OIDC-Client: Grafana (Vorbereitung)

> Noch nicht deployed – Client jetzt schon anlegen damit er beim Deployment bereit ist.

**Navigation:** Realm `homelab` → **Clients** → **"Create client"**

| Feld | Wert |
|------|------|
| Client ID | `grafana` |
| Client authentication | ON |
| Valid redirect URIs | `https://grafana.homelab.local/login/generic_oauth` |
| Web origins | `https://grafana.homelab.local` |

→ **Save** → Client Secret kopieren und in Kubernetes eintragen:

```bash
kubectl create namespace monitoring 2>/dev/null || true
kubectl create secret generic grafana-keycloak-secret \
  --from-literal=client-secret="<DEIN_SECRET_HIER>" \
  -n monitoring
```

---

## 7. OIDC-Client: Nextcloud (Vorbereitung)

> Noch nicht deployed – Client jetzt schon anlegen.

**Navigation:** Realm `homelab` → **Clients** → **"Create client"**

| Feld | Wert |
|------|------|
| Client ID | `nextcloud` |
| Client authentication | ON |
| Valid redirect URIs | `https://nextcloud.homelab.local/apps/oidc_login/oidc` |
| Web origins | `https://nextcloud.homelab.local` |

→ **Save** → Client Secret kopieren und in Kubernetes eintragen:

```bash
kubectl create namespace productivity 2>/dev/null || true
kubectl create secret generic nextcloud-keycloak-secret \
  --from-literal=client-secret="<DEIN_SECRET_HIER>" \
  -n productivity
```

---

## 8. GitLab OIDC aktivieren

In `k8s/argocd/applications/gitlab.yaml` den OIDC-Block aktivieren:

```yaml
oidc:
  enabled: true
  issuer: https://auth.homelab.local/realms/homelab
  clientId: gitlab
```

Committen und pushen – ArgoCD deployed automatisch:

```bash
git add k8s/argocd/applications/gitlab.yaml
git commit -m "feat: enable Keycloak OIDC for GitLab"
git push
```

GitLab neu starten damit die Konfiguration greift:

```bash
kubectl rollout restart deployment/gitlab -n gitlab
kubectl rollout status deployment/gitlab -n gitlab --timeout=300s
```

> Erfolgreich wenn auf https://gitlab.homelab.local der Button
> **"Sign in with Keycloak"** erscheint.

---

## 9. ArgoCD OIDC aktivieren

In `k8s/values/argocd.yaml` ergänzen:

```yaml
configs:
  cm:
    url: https://argocd.homelab.local
    oidc.config: |
      name: Keycloak
      issuer: https://auth.homelab.local/realms/homelab
      clientID: argocd
      clientSecret: $oidc.keycloak.clientSecret
      requestedScopes:
        - openid
        - profile
        - email
        - groups
      requestedIDTokenClaims:
        groups:
          essential: true

  rbac:
    policy.csv: |
      g, argocd-admins, role:admin
    policy.default: role:readonly
    scopes: '[groups]'
```

Committen und pushen:

```bash
git add k8s/values/argocd.yaml
git commit -m "feat: enable Keycloak OIDC for ArgoCD"
git push
```

ArgoCD Helm-Release updaten:

```bash
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values k8s/values/argocd.yaml \
  --reuse-values
```

> Erfolgreich wenn auf https://argocd.homelab.local der Button
> **"Log in via Keycloak"** erscheint.

---

## 10. Verifikation

### Keycloak erreichbar

```bash
# OIDC Discovery Endpoint
curl -s https://auth.homelab.local/realms/homelab/.well-known/openid-configuration \
  | python3 -m json.tool | grep -E "issuer|token_endpoint|authorization_endpoint"
```

### LDAP Sync prüfen

```bash
# Logs auf LDAP-Fehler prüfen
kubectl logs -n auth -l app.kubernetes.io/name=keycloakx --tail=50 | grep -i ldap
```

### GitLab Login testen

1. https://gitlab.homelab.local in **privatem Fenster** öffnen
2. **"Sign in with Keycloak"** klicken
3. AD-Credentials eingeben (z.B. `Administrator` + Samba-Passwort)
4. GitLab legt automatisch einen neuen User an

### ArgoCD Login testen

1. https://argocd.homelab.local in **privatem Fenster** öffnen
2. **"Log in via Keycloak"** klicken
3. AD-Credentials eingeben
4. User in `argocd-admins` → Admin-Zugriff, sonst read-only

---

## 11. Troubleshooting

**OIDC-Fehler: "getaddrinfo: name or service not known"**
```bash
# CoreDNS kennt *.homelab.local nicht → setup-coredns ausführen
make setup-coredns

# Danach DNS-Auflösung aus dem Cluster testen:
kubectl run -it --rm dns-test --image=alpine --restart=Never -- \
  nslookup auth.homelab.local
# Muss die Traefik Cluster-IP zurückgeben
```

**LDAP-Verbindung schlägt fehl**

```bash
# Samba AD direkt testen
kubectl run -it --rm ldap-test --image=alpine --restart=Never -- \
  sh -c "apk add --no-cache openldap-clients && \
  ldapsearch -x -H ldap://<tailscale-ip>:389 \
  -D 'CN=Administrator,CN=Users,DC=homelab,DC=local' \
  -w '<samba_admin_password>' \
  -b 'DC=homelab,DC=local' '(objectClass=user)' cn"
```

**Keycloak Pod crasht (OOMKilled)**

```bash
# Memory-Limit in k8s/argocd/applications/keycloak.yaml erhöhen:
# limits.memory: 1Gi → 2Gi
# dann: git commit + push, ArgoCD synct automatisch
```

**OIDC-Redirect schlägt fehl**

- Issuer-URL muss exakt stimmen: `https://auth.homelab.local/realms/homelab`
- Redirect URI in Keycloak muss exakt mit der App-URL übereinstimmen (kein trailing slash)
- `https://` nicht `http://` – CA muss auf dem Client importiert sein

**GitLab zeigt keinen "Sign in with Keycloak" Button**

```bash
# OIDC Secret gesetzt?
kubectl get secret gitlab-secret -n gitlab \
  -o jsonpath='{.data.oidc-client-secret}' | base64 -d

# GitLab Logs
kubectl logs -n gitlab -l app=gitlab --tail=100 | grep -i oidc

# GitLab neu starten
kubectl rollout restart deployment/gitlab -n gitlab
```

**User hat keine Rechte in ArgoCD**

```bash
# RBAC Config prüfen
kubectl get cm argocd-rbac-cm -n argocd -o yaml

# Gruppe des Users in Keycloak prüfen:
# Keycloak UI → Users → User auswählen → Tab "Groups"
# → muss in argocd-admins sein für Admin-Zugriff
```
