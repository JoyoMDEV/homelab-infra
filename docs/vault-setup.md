# Vault Setup Runbook

Zentrales Secret Management für das Homelab: HashiCorp Vault mit Keycloak OIDC-Auth und Kubernetes Auth Method.

**Services:**
- Vault UI: https://hcvault.homelab.local
- Auth: Keycloak OIDC (`homelab-admins` → Admin) + Kubernetes ServiceAccount

**Voraussetzungen:**
- Kubernetes-Cluster läuft: `make status`
- Keycloak läuft: https://auth.homelab.local
- cert-manager + wildcard TLS aktiv: `make cert-status`
- CoreDNS konfiguriert: `make setup-coredns` (muss in setup-coredns.sh ergänzt werden, siehe unten)

---

## Inhaltsverzeichnis

1. [Architektur](#1-architektur)
2. [Vault deployen](#2-vault-deployen)
3. [Keycloak Client anlegen](#3-keycloak-client-anlegen)
4. [Vault initialisieren](#4-vault-initialisieren)
5. [External Secrets Operator deployen](#5-external-secrets-operator-deployen)
6. [ClusterSecretStore einrichten](#6-clustersecretstore-einrichten)
7. [Secrets aus Vault verwenden](#7-secrets-aus-vault-verwenden)
8. [Bestehende Secrets migrieren](#8-bestehende-secrets-migrieren)
9. [Verifikation](#9-verifikation)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architektur

```
Keycloak (OIDC)
  └── homelab-admins → Vault Admin Policy
  └── alle User      → Vault Reader Policy

Kubernetes ServiceAccounts
  └── Namespace gitlab    → Role gitlab    → Policy ns-gitlab
  └── Namespace auth      → Role auth      → Policy ns-auth
  └── Namespace ...       → Role ...       → Policy ns-...
  └── external-secrets SA → Role eso       → Policy reader

Vault (hcvault.homelab.local)
  └── KV-v2 Engine: secret/
      └── homelab/
          ├── gitlab/          ← GitLab Secrets
          ├── auth/            ← Keycloak Secrets
          ├── productivity/    ← Nextcloud, Paperless, NocoDB
          ├── monitoring/      ← Grafana, Alertmanager
          ├── security/        ← Vaultwarden, Vault selbst
          └── test/            ← Demo + Recovery-Tests

External Secrets Operator (Namespace: external-secrets)
  └── ClusterSecretStore 'vault'
      └── ExternalSecret in Namespace X
            └── Kubernetes Secret in Namespace X (synct stündlich)
```

**Warum kein Agent Injector?**
Der Vault Agent Sidecar Injector ist für Production-Setups gedacht. Im Homelab ist der External Secrets Operator (ESO) einfacher: er erzeugt normale Kubernetes Secrets, die Pods per `secretKeyRef` oder `envFrom` nutzen können – ohne Änderungen an Pod-Specs.

---

## 2. Vault deployen

```bash
# ArgoCD Application committen
git add k8s/argocd/applications/vault.yaml
git commit -m "feat: add HashiCorp Vault for centralized secret management"
git push
```

ArgoCD synct automatisch. Fortschritt beobachten:

```bash
kubectl get pods -n security -w
# NAME                                    READY   STATUS    RESTARTS
# vault-0                                 0/1     Running   0   ← startet als "not ready" (sealed)
```

> **Wichtig:** Der Vault Pod startet im Status `0/1 Running` – das ist normal.
> Vault meldet sich als not-ready bis es unsealed ist. Die readinessProbe
> ist so konfiguriert, dass `sealed` (HTTP 503) als `204` durchgelassen wird.

---

## 3. Keycloak Client anlegen

**Navigation:** https://auth.homelab.local → Realm `homelab` → **Clients** → **"Create client"**

### 3.1 General Settings

| Feld | Wert |
|------|------|
| Client type | `OpenID Connect` |
| Client ID | `vault` |
| Name | `HashiCorp Vault` |

→ **Next**

### 3.2 Capability Config

| Feld | Wert |
|------|------|
| Client authentication | ON (confidential) |
| Standard flow | ON |
| Direct access grants | OFF |

→ **Next**

### 3.3 Login Settings

| Feld | Wert |
|------|------|
| Root URL | `https://hcvault.homelab.local` |
| Valid redirect URIs | `https://hcvault.homelab.local/ui/vault/auth/oidc/oidc/callback` |
| Valid redirect URIs | `https://hcvault.homelab.local/oidc/callback` |
| Web origins | `https://hcvault.homelab.local` |

→ **Save**

### 3.4 Groups Mapper konfigurieren

Damit Vault die Keycloak-Gruppen für Policy-Mapping empfängt:

1. Client `vault` → Tab **"Client scopes"**
2. Klick auf `vault-dedicated`
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

### 3.5 Gruppe `homelab-admins` anlegen (falls noch nicht vorhanden)

**Navigation:** Realm `homelab` → **Groups** → **"Create group"** → Name: `homelab-admins`

Deinen User der Gruppe zuweisen:
**Users** → User auswählen → Tab **"Groups"** → `homelab-admins` joinen.

---

## 4. Vault initialisieren

```bash
chmod +x scripts/setup-hcvault.sh
./scripts/setup-hcvault.sh
```

Das Script:
1. Wartet auf den Vault Pod
2. Initialisiert Vault (5 Keys, Threshold 3)
3. Zeigt Root Token + Unseal Keys → **sofort in Ansible Vault sichern**
4. Unsealt Vault mit 3 von 5 Keys
5. Aktiviert Audit Log
6. Legt KV-v2 Engine unter `secret/` an
7. Konfiguriert Policies (admin, reader, ns-*)
8. Aktiviert Kubernetes Auth Method
9. Konfiguriert Keycloak OIDC (nach Client Secret Eingabe)

### Unseal Keys in Ansible Vault sichern

```bash
make vault-edit
```

```yaml
# In ansible/inventory/group_vars/all/vault.yml hinzufügen:
vault_vault_root_token: "hvs.xxxxxxxxxxxxxxxxxxxx"
vault_vault_unseal_keys:
  - "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  - "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  - "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  - "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  - "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

> **KRITISCH:** Ohne Unseal Keys ist Vault nach einem Neustart nicht mehr zugänglich.
> Alle 5 Keys und der Root Token müssen sicher aufbewahrt werden.
> Für automatisches Unseal nach Pod-Restart → siehe [Auto-Unseal mit Kubernetes](#auto-unseal-optional).

### Vault nach Pod-Neustart manuell unsealen

```bash
# Status prüfen
kubectl exec -n security vault-0 -- vault status

# Falls sealed: 3 von 5 Keys eingeben
./scripts/setup-vault.sh --skip-init
```

---

## 5. External Secrets Operator deployen

```bash
git add k8s/argocd/applications/external-secrets.yaml
git commit -m "feat: add External Secrets Operator"
git push
```

Status prüfen:

```bash
kubectl get pods -n external-secrets
# NAME                                                READY   STATUS
# external-secrets-xxxx                              1/1     Running
# external-secrets-cert-controller-xxxx              1/1     Running
# external-secrets-webhook-xxxx                      1/1     Running
```

---

## 6. ClusterSecretStore einrichten

```bash
kubectl apply -f k8s/security/vault-cluster-secret-store.yaml
```

Store-Status prüfen:

```bash
kubectl get clustersecretstore vault
# NAME    AGE   STATUS   CAPABILITIES   READY
# vault   1m    Valid    ReadWrite      True
```

> Falls `STATUS: Invalid`: Vault nicht erreichbar oder Kubernetes Auth falsch konfiguriert.
> Prüfe: `kubectl describe clustersecretstore vault`

---

## 7. Secrets aus Vault verwenden

### 7.1 Secret in Vault anlegen

```bash
# Per kubectl exec
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token> \
  vault kv put secret/homelab/gitlab/oidc \
    client-secret="mein-geheimes-client-secret"

# Per Vault UI (empfohlen)
# https://hcvault.homelab.local → secret/ → homelab/ → gitlab/ → Create secret
```

### 7.2 ExternalSecret in einem Namespace anlegen

```yaml
# k8s/argocd/applications/mein-service.yaml oder als eigene Datei
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gitlab-oidc-secret
  namespace: gitlab
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: gitlab-oidc-secret          # Name des erzeugten Kubernetes Secrets
    creationPolicy: Owner
  data:
    - secretKey: oidc-client-secret   # Key im Kubernetes Secret
      remoteRef:
        key: homelab/gitlab/oidc      # Vault KV Path (ohne 'secret/')
        property: client-secret       # Feld im Vault Secret
```

### 7.3 Kubernetes Secret nutzen

```yaml
# Im Deployment / ArgoCD values:
env:
  - name: OIDC_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: gitlab-oidc-secret
        key: oidc-client-secret
```

### 7.4 Mehrere Felder auf einmal (dataFrom)

```yaml
spec:
  dataFrom:
    - extract:
        key: homelab/gitlab/rails-secrets   # Alle Felder des Vault Secrets
```

---

## 8. Bestehende Secrets migrieren

Migration erfolgt schrittweise – alte Secrets bleiben bis zur vollständigen Migration bestehen.

### Schritt-für-Schritt Beispiel: GitLab OIDC Secret

```bash
# 1. Bestehenden Wert aus Kubernetes Secret lesen
OIDC_SECRET=$(kubectl get secret gitlab-secret -n gitlab \
  -o jsonpath='{.data.oidc-client-secret}' | base64 -d)

# 2. In Vault schreiben
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token> \
  vault kv put secret/homelab/gitlab/oidc \
    client-secret="${OIDC_SECRET}"

# 3. ExternalSecret anlegen (YAML, committen)
# 4. Prüfen ob Kubernetes Secret korrekt erzeugt wird
kubectl get secret gitlab-oidc-secret -n gitlab
# 5. Deployment auf neues Secret umstellen
# 6. Altes manuelles Secret löschen
```

### Migration Roadmap

| Namespace | Secret | Status |
|-----------|--------|--------|
| `gitlab` | `gitlab-secret` (oidc-client-secret) | ☐ offen |
| `gitlab` | `gitlab-rails-secrets` | ☐ offen |
| `auth` | `keycloak-secret` | ☐ offen |
| `auth` | `keycloak-db-secret` | ☐ offen |
| `productivity` | `nextcloud-secret` | ☐ offen |
| `productivity` | `paperless-secret` | ☐ offen |
| `monitoring` | `grafana-keycloak-secret` | ☐ offen |
| `security` | `vaultwarden-secret` | ☐ offen |
| `infrastructure` | `minio-secret` | ☐ offen |
| `infrastructure` | `restic-ssh-key` | ☐ offen |

---

## 9. Verifikation

### Vault erreichbar

```bash
curl -sf https://hcvault.homelab.local/v1/sys/health | python3 -m json.tool
# {"initialized":true,"sealed":false,"standby":false,...}
```

### Kubernetes Auth funktioniert

```bash
# Aus dem Cluster testen (simuliert ESO-Authentifizierung)
kubectl run -it --rm vault-test --image=vault:1.19.0 --restart=Never -- \
  sh -c "
    vault write auth/kubernetes/login \
      role=external-secrets \
      jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
      -address=http://vault.security.svc.cluster.local:8200
  "
```

### OIDC Login testen

1. https://hcvault.homelab.local im **privaten Fenster** öffnen
2. Auth Method: **OIDC** wählen → **"Sign in with OIDC Provider"**
3. Keycloak-Login → zurück zu Vault
4. User in `homelab-admins` → Admin-Zugriff, sonst Reader

### Demo Secret prüfen

```bash
kubectl get secret vault-demo -n security \
  -o jsonpath='{.data.hello}' | base64 -d
# world
```

### Audit Log prüfen

```bash
kubectl exec -n security vault-0 -- \
  tail -5 /vault/data/audit.log | python3 -m json.tool
```

---

## 10. Troubleshooting

### Vault Pod startet nicht

```bash
kubectl logs -n security vault-0 --previous
kubectl describe pod vault-0 -n security
```

Häufige Ursachen: homelab-ca Secret fehlt, PVC nicht gebunden.

### Vault sealed nach Pod-Neustart

Vault muss nach jedem Neustart manuell unsealt werden (Standardverhalten bei file storage):

```bash
./scripts/setup-vault.sh --skip-init
```

**Auto-Unseal (optional):** Vault unterstützt Auto-Unseal via Transit Secret Engine (Vault selbst), AWS KMS, Azure Key Vault etc. Für Homelab unnötig komplex – manuelles Unsealen reicht.

### ClusterSecretStore: "Invalid"

```bash
kubectl describe clustersecretstore vault
```

Typische Ursachen:
- Vault Pod sealed → unsealen
- Kubernetes Auth Role `external-secrets` nicht angelegt → `setup-vault.sh --skip-init`
- ESO ServiceAccount Name falsch

### ExternalSecret synct nicht

```bash
kubectl describe externalsecret <name> -n <namespace>
# Events zeigen den Fehler

# ESO Logs
kubectl logs -n external-secrets \
  $(kubectl get pod -n external-secrets -l app.kubernetes.io/name=external-secrets \
    -o jsonpath='{.items[0].metadata.name}') --tail=50
```

### OIDC Login: "invalid client"

Keycloak Client Secret prüfen – wurde beim `setup-vault.sh` korrekt eingegeben?

```bash
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token> \
  vault read auth/oidc/config
```

Secret updaten:

```bash
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token> \
  vault write auth/oidc/config \
    oidc_client_secret="<NEUES_SECRET>"
```

### "permission denied" beim Secret lesen

Policy prüfen:

```bash
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root-token> \
  vault policy read ns-gitlab
```

Token Capabilities prüfen:

```bash
kubectl exec -n security vault-0 -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<token-to-check> \
  vault token capabilities secret/data/homelab/gitlab/oidc
```
