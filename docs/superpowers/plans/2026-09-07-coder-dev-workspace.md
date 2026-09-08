# Coder Remote Dev Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Coder (OIDC-gated, cluster-admin-equivalent, ArgoCD-managed) and a single persistent dev workspace reachable via VS Code Desktop Remote SSH from three machines.

**Architecture:** Coder server runs as an ArgoCD-managed Helm release in a new `coder` namespace, backed by the existing `homelab-pg` CNPG cluster and Keycloak OIDC. A dedicated cluster-admin `ServiceAccount` is tracked as a static RBAC manifest. A Terraform template (pushed manually via `coder templates push`, since Coder templates aren't native k8s resources) defines one persistent workspace `Pod` running a custom image (built in a new, separate GitLab project via the existing Kaniko CI pattern), with a PVC for `/home/coder` and Vault-backed git SSH credentials.

**Tech Stack:** Kubernetes, ArgoCD, Helm (`coder/coder` chart), Terraform (`coder/coder` + `hashicorp/kubernetes` providers), External Secrets Operator + Vault, Keycloak OIDC, GitLab CI + Kaniko, Backstage catalog.

**Spec:** `docs/superpowers/specs/2026-09-03-coder-dev-workspace-design.md`

## Global Constraints

- Never put a real secret value in a `Secret`, `ConfigMap`, or Helm `values:` block — every secret flows through an `ExternalSecret` at Vault path `homelab/coder/...` (repo convention, CLAUDE.md).
- **Vault writes are always run by the user personally.** `scripts/setup-coder.sh` performs `vault kv put` — the implementing agent must write and validate this script (syntax check, review) but must **never execute it**, and must never run any `vault kv put`/`kubectl exec vault-0 -- vault ...` command itself. Flag these as manual steps for the user in every task that touches them (standing preference, not spec-derived).
- ArgoCD Application: `spec.project: default`, `syncPolicy.automated: {prune: true, selfHeal: true}`, `syncOptions: [CreateNamespace=true]`, destination namespace `coder` (repo convention, CLAUDE.md).
- Ingress: `ingressClassName: traefik`, host `coder.homelab.local`, TLS via `homelab-wildcard-tls` (repo convention, CLAUDE.md).
- Reachable only over Tailscale — no public-tier ingress class, no NodePort/LoadBalancer exposure (spec).
- Pinned versions (verified live, 2026-09-07): Coder Helm chart `2.37.0` at `https://helm.coder.com/v2` (chart `coder`); Terraform providers `coder/coder` `2.18.0`, `hashicorp/kubernetes` `3.2.1`.
- Workspace RBAC: `ServiceAccount coder-workspace-admin` (namespace `coder`) bound via `ClusterRoleBinding` to the built-in `cluster-admin` `ClusterRole`, tracked as a static manifest under `k8s/security/` synced by the existing `security-manifests` ArgoCD app — **not** defined inside the Terraform template (spec, explicit design decision).
- **Validate live before handing off to ArgoCD.** For every Kubernetes resource that ArgoCD will eventually manage (Tasks 2, 3, 4): apply it directly against the live cluster (`kubectl apply -f ...`, or for the Helm-chart-based Coder server, `helm template ... | kubectl apply -f -` — the same rendering ArgoCD itself performs, not `helm install`, so there's no separate Helm release to reconcile away later) and verify it actually works *before* committing the manifest to git. Only commit — and only then push — once live validation passes. When the manifest is later pushed, ArgoCD renders/applies the identical content, so it cleanly adopts the already-verified resources (briefly `OutOfSync` while it adds its own tracking label, then `Synced`) rather than creating a conflicting second copy. Tasks 6-8 (the separate GitLab project, the Terraform workspace template) are unaffected — they were already "apply manually, ArgoCD never manages them" by design.
- No multi-user/OIDC-for-access-control, no ephemeral per-project workspaces, no `envbuilder` in-cluster image builds (spec non-goals).
- Every deployed service gets a matching `catalog/<service>/catalog-info.yaml` registered in `catalog/all.yaml`, with a four-section `docs/index.md` (CLAUDE.md).

---

### Task 1: Vault secret seeding script

**Files:**
- Create: `scripts/setup-coder.sh`

**Interfaces:**
- Produces: Vault path `homelab/coder/coder-secret` with keys `db-password`, `oidc-client-secret`, `git-ssh-private-key`; Vault path `homelab/coder/registry-pull-secret` with keys `username`, `token`. Consumed by Task 2's `ExternalSecret`s.
- Produces: a `coder` Postgres database + role on `homelab-pg-1` (namespace `infrastructure`), consumed by Task 4's `CODER_PG_CONNECTION_URL`.
- Produces: an ed25519 SSH keypair; the private key goes to Vault (above), the public key is printed for the user to register manually (documented in Task 10's runbook) as a GitHub deploy key on `homelab-infra` and a GitLab SSH key on the self-hosted instance.

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-coder.sh
#  Legt die Postgres-Datenbank/Rolle für Coder an und schreibt die
#  zugehörigen Secrets (DB-Passwort, OIDC-Client-Secret-Platzhalter,
#  Git-SSH-Deploy-Key, Registry-Pull-Credentials) nach Vault. Das
#  ExternalSecret 'coder-secret' (Namespace coder) übernimmt von dort die
#  Pflege des Kubernetes Secrets.
#
#  IDEMPOTENT: Ist 'homelab/coder/coder-secret' schon vollständig befüllt,
#  wird nur das DB-Passwort mit der Postgres-Rolle synchronisiert (ALTER
#  ROLE) - Secret/SSH-Key werden nicht neu generiert. Gleiches für
#  'homelab/coder/registry-pull-secret'.
#
#  VORAUSSETZUNGEN:
#  - VAULT_TOKEN als Env-Var gesetzt
#  - kubectl konfiguriert und Cluster erreichbar
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-coder.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/coder/coder-secret"
REGISTRY_VAULT_PATH="homelab/coder/registry-pull-secret"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_get() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get -field="$2" "secret/$1" 2>/dev/null || true
}

vault_kv_path_exists() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get "secret/$1" &>/dev/null
}

vault_kv_put() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

force_sync() {
  kubectl annotate externalsecret "$1" -n "$2" \
    force-sync="$(date +%s)" --overwrite 2>/dev/null || \
    echo "    (ExternalSecret $1 noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"
}

echo "==> Creating Coder Postgres database/role..."
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s

CODER_DB_PW=$(vault_kv_get "${VAULT_PATH}" "db-password")
[[ -z "${CODER_DB_PW}" ]] && CODER_DB_PW=$(openssl rand -base64 24)

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE coder;" 2>/dev/null || echo "    coder database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'coder') THEN
      CREATE ROLE coder WITH LOGIN PASSWORD '$CODER_DB_PW';
    ELSE
      ALTER ROLE coder WITH PASSWORD '$CODER_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE coder TO coder;
  ALTER DATABASE coder OWNER TO coder;
"
echo "    Coder database created"

if vault_kv_path_exists "${VAULT_PATH}"; then
  echo "    ${VAULT_PATH} existiert bereits - Secret wird nicht neu angelegt (nur db-password oben synchronisiert)."
else
  echo ""
  echo "==> SSH-Deploy-Key für Git-Zugriff (GitHub + self-hosted GitLab)"
  SSH_KEY_DIR=$(mktemp -d)
  ssh-keygen -t ed25519 -N "" -C "coder-workspace@homelab.local" -f "${SSH_KEY_DIR}/id_ed25519" >/dev/null
  GIT_SSH_PRIVATE_KEY=$(cat "${SSH_KEY_DIR}/id_ed25519")
  GIT_SSH_PUBLIC_KEY=$(cat "${SSH_KEY_DIR}/id_ed25519.pub")
  rm -rf "${SSH_KEY_DIR}"

  vault_kv_put "${VAULT_PATH}" \
    "db-password=${CODER_DB_PW}" \
    "oidc-client-secret=REPLACE_AFTER_KEYCLOAK_SETUP" \
    "git-ssh-private-key=${GIT_SSH_PRIVATE_KEY}"

  force_sync coder-secret coder

  echo ""
  echo "    Öffentlicher Schlüssel (als Deploy Key/SSH-Key hinterlegen, siehe docs/coder-setup.md):"
  echo ""
  echo "${GIT_SSH_PUBLIC_KEY}"
fi

echo ""
if vault_kv_path_exists "${REGISTRY_VAULT_PATH}"; then
  echo "    ${REGISTRY_VAULT_PATH} existiert bereits - nichts zu tun."
else
  echo "==> GitLab Registry-Pull-Credentials (für registry.homelab.local)"
  echo "    Personal/Deploy Access Token mit 'read_registry'-Scope für das"
  echo "    Projekt 'homelab/projects/coder-workspace'."
  read -rp  "    Registry Username: " REGISTRY_USER
  read -rsp "    Registry Token (wird nicht angezeigt): " REGISTRY_TOKEN
  echo ""

  if [[ -z "${REGISTRY_USER}" ]] || [[ -z "${REGISTRY_TOKEN}" ]]; then
    echo "    FEHLER: Username oder Token leer. Abbruch."
    exit 1
  fi

  vault_kv_put "${REGISTRY_VAULT_PATH}" \
    "username=${REGISTRY_USER}" \
    "token=${REGISTRY_TOKEN}"

  force_sync coder-workspace-registry-pull coder
fi

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  DB Password: $CODER_DB_PW"
echo ""
echo "  Nächste Schritte: siehe docs/coder-setup.md"
echo "============================================"
```

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/setup-coder.sh`
Expected: no output, exit code 0. (`shellcheck` isn't installed locally as of writing per CLAUDE.md — pre-commit's `shellcheck-py` hook will catch style issues at commit time.)

- [ ] **Step 3: Make it executable and commit**

```bash
chmod +x scripts/setup-coder.sh
git add scripts/setup-coder.sh
git commit -m "feat(coder): add Vault secret seeding script"
```

Do **not** run `scripts/setup-coder.sh` — this requires `VAULT_TOKEN` and writes real secrets; the user runs it personally as part of the Task 10 runbook.

---

### Task 2: ExternalSecrets for Coder server + workspace image pull

**Files:**
- Create: `k8s/security/external-secrets/coder/coder-secret.yaml`
- Create: `k8s/security/external-secrets/coder/coder-workspace-registry-pull.yaml`

**Interfaces:**
- Consumes: Vault paths `homelab/coder/coder-secret` and `homelab/coder/registry-pull-secret` (Task 1).
- Produces: Kubernetes `Secret` `coder-secret` (namespace `coder`) with keys `db-password`, `oidc-client-secret`, `git-ssh-private-key`, `pg-connection-url` — consumed by Task 4 (`CODER_PG_CONNECTION_URL`, `CODER_OIDC_CLIENT_SECRET`) and Task 7 (`git-ssh-private-key` volume mount). Produces `Secret` `coder-workspace-registry-pull` (namespace `coder`, type `kubernetes.io/dockerconfigjson`) — consumed by Task 7 (`image_pull_secrets`).

- [ ] **Step 1: Write `coder-secret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: coder-secret
  namespace: coder
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: coder-secret
    creationPolicy: Owner
    template:
      # Merge so the individually-fetched keys below (oidc-client-secret,
      # git-ssh-private-key) still land in the Secret alongside the derived
      # pg-connection-url - default template behavior would replace them.
      mergePolicy: Merge
      data:
        pg-connection-url: "postgres://coder:{{ index . \"db-password\" }}@homelab-pg-rw.infrastructure.svc.cluster.local:5432/coder?sslmode=disable"
  data:
    - secretKey: db-password
      remoteRef:
        key: homelab/coder/coder-secret
        property: db-password
    - secretKey: oidc-client-secret
      remoteRef:
        key: homelab/coder/coder-secret
        property: oidc-client-secret
    - secretKey: git-ssh-private-key
      remoteRef:
        key: homelab/coder/coder-secret
        property: git-ssh-private-key
```

- [ ] **Step 2: Write `coder-workspace-registry-pull.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: coder-workspace-registry-pull
  namespace: coder
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: coder-workspace-registry-pull
    creationPolicy: Owner
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: |
          {"auths":{"registry.homelab.local":{"username":"{{ .username }}", "password":"{{ .token }}", "auth":"{{ printf "%s:%s" .username .token | b64enc }}"}}}
  data:
    - secretKey: username
      remoteRef:
        key: homelab/coder/registry-pull-secret
        property: username
    - secretKey: token
      remoteRef:
        key: homelab/coder/registry-pull-secret
        property: token
```

- [ ] **Step 3: Lint both files**

Run: `yamllint -c .yamllint.yml k8s/security/external-secrets/coder/`
Expected: no output (clean).

- [ ] **Step 4: Precondition — confirm Task 1 was already run by the user**

Run: `kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault kv get secret/homelab/coder/coder-secret`
Expected: prints `db-password`, `oidc-client-secret`, `git-ssh-private-key`. If this errors ("no value found") or `VAULT_TOKEN` isn't set, **stop this task** and ask the user to run `scripts/setup-coder.sh` first (Task 1) — do not proceed or attempt to write to Vault yourself.

- [ ] **Step 5: Create the `coder` namespace and apply both ExternalSecrets live**

```bash
kubectl create namespace coder
kubectl apply -f k8s/security/external-secrets/coder/coder-secret.yaml
kubectl apply -f k8s/security/external-secrets/coder/coder-workspace-registry-pull.yaml
```

Expected: `namespace/coder created`, `externalsecret.external-secrets.io/coder-secret created`, `externalsecret.external-secrets.io/coder-workspace-registry-pull created`.

- [ ] **Step 6: Verify both synced into real Secrets**

```bash
kubectl get externalsecret -n coder
kubectl get secret coder-secret coder-workspace-registry-pull -n coder
```

Expected: both `ExternalSecret`s show `STATUS SecretSynced`, and both `Secret`s exist with the expected keys (`kubectl get secret coder-secret -n coder -o jsonpath='{.data}'` lists `db-password`, `oidc-client-secret`, `git-ssh-private-key`, `pg-connection-url`).

- [ ] **Step 7: Commit**

```bash
git add k8s/security/external-secrets/coder/
git commit -m "feat(coder): add ExternalSecrets for server + workspace registry pull"
```

Do not push yet — Task 4 pushes everything together once the Coder server itself is validated live.

---

### Task 3: Workspace RBAC manifest

**Files:**
- Create: `k8s/security/coder-workspace-admin-rbac.yaml`

**Interfaces:**
- Produces: `ServiceAccount coder-workspace-admin` (namespace `coder`) bound to `cluster-admin`. Consumed by Task 7's Terraform template (`service_account_name = "coder-workspace-admin"`).

- [ ] **Step 1: Write the manifest**

```yaml
---
# Grants the Coder workspace pod cluster-admin-equivalent access, matching
# the access already available from the Mac today. Accepted risk, explicit
# design decision - see
# docs/superpowers/specs/2026-09-03-coder-dev-workspace-design.md.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: coder-workspace-admin
  namespace: coder
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: coder-workspace-admin
subjects:
  - kind: ServiceAccount
    name: coder-workspace-admin
    namespace: coder
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/security/coder-workspace-admin-rbac.yaml`
Expected: no output.

- [ ] **Step 3: Apply live and verify**

```bash
kubectl apply -f k8s/security/coder-workspace-admin-rbac.yaml
kubectl get serviceaccount coder-workspace-admin -n coder
kubectl get clusterrolebinding coder-workspace-admin -o jsonpath='{.roleRef.name}{"\n"}'
```

Expected: `serviceaccount/coder-workspace-admin created`, `clusterrolebinding.rbac.authorization.k8s.io/coder-workspace-admin created`, the `ServiceAccount` exists in namespace `coder`, and the `roleRef.name` prints `cluster-admin`.

- [ ] **Step 4: Commit**

```bash
git add k8s/security/coder-workspace-admin-rbac.yaml
git commit -m "feat(coder): add cluster-admin RBAC for workspace pods"
```

Do not push yet — Task 4 pushes everything together. Once pushed, the existing `security-manifests` ArgoCD app (which recurses `k8s/security/`) adopts this already-applied manifest on its next sync — no new Application needed.

---

### Task 4: Coder server ArgoCD Application

**Files:**
- Create: `k8s/argocd/applications/coder.yaml`
- Modify: `k8s/namespaces.yaml` (add the `coder` namespace with the `homelab.local/inject-ca` label — see Step 3a; a live-verified plan correction, not present in the original brief text)

**Interfaces:**
- Consumes: `Secret coder-secret` keys `pg-connection-url`, `oidc-client-secret` (Task 2); `Secret homelab-ca` (produced live by `k8s/infrastructure/cert-sync-cronjob.yaml` once the namespace carries the `inject-ca` label, Step 3a).
- Produces: the `coder` namespace (via `CreateNamespace=true`) and the running Coder server, consumed by Task 7/8/9 (workspace template push targets this server).

- [ ] **Step 1: Write the Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coder
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://helm.coder.com/v2
    chart: coder
    targetRevision: "2.37.0"
    helm:
      values: |
        coder:
          env:
            - name: CODER_ACCESS_URL
              value: "https://coder.homelab.local"
            - name: CODER_PG_CONNECTION_URL
              valueFrom:
                secretKeyRef:
                  name: coder-secret
                  key: pg-connection-url
            - name: CODER_OIDC_ISSUER_URL
              value: "https://auth.homelab.local/realms/homelab"
            - name: CODER_OIDC_CLIENT_ID
              value: "coder"
            - name: CODER_OIDC_CLIENT_SECRET
              valueFrom:
                secretKeyRef:
                  name: coder-secret
                  key: oidc-client-secret
            - name: CODER_OIDC_SIGN_IN_TEXT
              value: "Sign in with Keycloak"
            - name: CODER_DISABLE_PASSWORD_AUTH
              value: "true"
            - name: CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE
              value: "false"
            - name: SSL_CERT_DIR
              value: /usr/local/share/ca-certificates

          ingress:
            enable: true
            className: traefik
            host: coder.homelab.local
            tls:
              enable: true
              secretName: homelab-wildcard-tls

          resources:
            requests:
              memory: 512Mi
              cpu: 250m
            limits:
              memory: 1Gi

          # Trust the internal CA when validating CODER_OIDC_ISSUER_URL
          # (auth.homelab.local's cert is signed by it) - same pattern as
          # k8s/argocd/applications/vault.yaml for the identical Keycloak-OIDC
          # TLS-trust problem. Requires the `coder` namespace to carry the
          # homelab.local/inject-ca=true label (added to k8s/namespaces.yaml)
          # so the cert-sync CronJob (k8s/infrastructure/cert-sync-cronjob.yaml)
          # populates the `homelab-ca` secret into it.
          volumes:
            - name: homelab-ca
              secret:
                secretName: homelab-ca

          volumeMounts:
            - name: homelab-ca
              mountPath: /usr/local/share/ca-certificates/homelab-ca.crt
              subPath: homelab-ca.crt
              readOnly: true

  destination:
    server: https://kubernetes.default.svc
    namespace: coder
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/argocd/applications/coder.yaml`
Expected: no output.

- [ ] **Step 3: Precondition — confirm Tasks 2 and 3 are live**

```bash
kubectl get secret coder-secret coder-workspace-registry-pull -n coder
kubectl get serviceaccount coder-workspace-admin -n coder
```

Expected: all three exist (Task 2/3 already applied them live). If not, stop and complete those tasks first — the Coder pod will crash-loop without `coder-secret`.

- [ ] **Step 3a: Add `coder` to `k8s/namespaces.yaml` and enable CA injection live**

`k8s/namespaces.yaml` lists every managed namespace with a `homelab.local/inject-ca: "true"` label consumed by `k8s/infrastructure/cert-sync-cronjob.yaml` (a daily CronJob that copies the internal CA into every labeled namespace as a `homelab-ca` Secret). `coder` was created ad-hoc by Task 2 without this label — without it, Coder's Go OIDC client cannot validate `auth.homelab.local`'s certificate at startup (`x509: certificate signed by unknown authority`) and crash-loops before ever listening. Add an entry to `k8s/namespaces.yaml` (same two labels as every other entry there, e.g. `backstage`'s):

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: coder
  labels:
    managed-by: argocd
    homelab.local/inject-ca: "true"
```

Then apply the label to the already-live namespace directly (faster than waiting for `k8s/namespaces.yaml` to be re-applied) and trigger cert-sync immediately rather than waiting for its 03:00 schedule:

```bash
kubectl label namespace coder homelab.local/inject-ca=true managed-by=argocd --overwrite
kubectl create job --from=cronjob/cert-sync cert-sync-manual-$(date +%s) -n kube-system
kubectl wait --for=condition=complete job -l job-name -n kube-system --timeout=60s 2>/dev/null || sleep 10
kubectl get secret homelab-ca -n coder
```

Expected: the final command shows a `homelab-ca` Secret now exists in the `coder` namespace.

- [ ] **Step 4: Render the chart with the embedded values**

```bash
helm repo add coder-v2 https://helm.coder.com/v2 --force-update
helm repo update coder-v2
yq '.spec.source.helm.values' k8s/argocd/applications/coder.yaml > /tmp/coder-values.yaml
helm template coder coder-v2/coder --version 2.37.0 --namespace coder \
  -f /tmp/coder-values.yaml > /tmp/coder-rendered.yaml
```

Expected: `/tmp/coder-rendered.yaml` contains a `Deployment` (name `coder`), `Service`, and `Ingress` (host `coder.homelab.local`) with no template errors. (If `yq` isn't installed, extract the `helm.values:` block from the file into `/tmp/coder-values.yaml` by hand instead.)

- [ ] **Step 5: Apply the rendered manifests directly — this is exactly what ArgoCD will do later**

```bash
kubectl apply -f /tmp/coder-rendered.yaml
kubectl rollout status deployment/coder -n coder --timeout=300s
```

Expected: rollout completes successfully (`deployment "coder" successfully rolled out`).

- [ ] **Step 6: Verify the server actually works**

```bash
kubectl logs -n coder -l app.kubernetes.io/name=coder --tail=50
curl -sk -o /dev/null -w '%{http_code}\n' https://coder.homelab.local
```

Expected: no `FATAL`/OIDC-config errors in the logs (a clean startup log mentioning the configured issuer URL and access URL), and the `curl` prints `200`. If this fails, fix the values in `k8s/argocd/applications/coder.yaml`, re-run Steps 4-6 against the same live resources (`kubectl apply` is idempotent) until it passes — do not commit a values change you haven't re-verified live.

- [ ] **Step 7: Commit and push**

```bash
git add k8s/argocd/applications/coder.yaml k8s/namespaces.yaml
git commit -m "feat(coder): deploy Coder server via ArgoCD"
git push
```

- [ ] **Step 8: Confirm ArgoCD adopts the already-running deployment cleanly**

Run: `kubectl get application coder -n argocd -w`
Expected: within a couple of minutes, `SYNC STATUS` reaches `Synced` and `HEALTH STATUS` reaches `Healthy` — ArgoCD is now managing the exact resources already verified live in Steps 5-6, with no pod restart or diff (it renders the identical chart+values).

---

### Task 5: Keycloak OIDC client documentation

**Files:**
- Modify: `docs/keycloak-setup.md`

**Interfaces:** none (documentation only) — the resulting client ID `coder` and redirect URI must match Task 4's `CODER_OIDC_CLIENT_ID`/`CODER_ACCESS_URL`.

- [ ] **Step 1: Update the table of contents**

In `docs/keycloak-setup.md`, replace:

```
5. [OIDC-Client: ArgoCD](#5-oidc-client-argocd)
6. [OIDC-Client: Grafana](#6-oidc-client-grafana-vorbereitung)
7. [OIDC-Client: Nextcloud](#7-oidc-client-nextcloud-vorbereitung)
8. [GitLab OIDC aktivieren](#8-gitlab-oidc-aktivieren)
9. [ArgoCD OIDC aktivieren](#9-argocd-oidc-aktivieren)
10. [Verifikation](#10-verifikation)
11. [Troubleshooting](#11-troubleshooting)
```

with:

```
5. [OIDC-Client: ArgoCD](#5-oidc-client-argocd)
6. [OIDC-Client: Coder](#6-oidc-client-coder)
7. [OIDC-Client: Grafana](#7-oidc-client-grafana-vorbereitung)
8. [OIDC-Client: Nextcloud](#8-oidc-client-nextcloud-vorbereitung)
9. [GitLab OIDC aktivieren](#9-gitlab-oidc-aktivieren)
10. [ArgoCD OIDC aktivieren](#10-argocd-oidc-aktivieren)
11. [Verifikation](#11-verifikation)
12. [Troubleshooting](#12-troubleshooting)
```

- [ ] **Step 2: Renumber the existing sections 6-11 to 7-12**

Replace each of these exact header lines (leave all other content in each section untouched):

- `## 6. OIDC-Client: Grafana (Vorbereitung)` → `## 7. OIDC-Client: Grafana (Vorbereitung)`
- `## 7. OIDC-Client: Nextcloud (Vorbereitung)` → `## 8. OIDC-Client: Nextcloud (Vorbereitung)`
- `## 8. GitLab OIDC aktivieren` → `## 9. GitLab OIDC aktivieren`
- `## 9. ArgoCD OIDC aktivieren` → `## 10. ArgoCD OIDC aktivieren`
- `## 10. Verifikation` → `## 11. Verifikation`
- `## 11. Troubleshooting` → `## 12. Troubleshooting`

- [ ] **Step 3: Insert the new section 6, immediately after the existing ArgoCD section (before the old section 6/new section 7 header)**

```markdown
## 6. OIDC-Client: Coder

**Navigation:** Realm `homelab` → **Clients** → **"Create client"**

### 6.1 General Settings

| Feld | Wert |
|------|------|
| Client type | `OpenID Connect` |
| Client ID | `coder` |
| Name | `Coder` |

→ **Next**

### 6.2 Capability Config

| Feld | Wert |
|------|------|
| Client authentication | ON (confidential client) |
| Standard flow | ON |
| Direct access grants | OFF |

→ **Next**

### 6.3 Login Settings

| Feld | Wert |
|------|------|
| Root URL | `https://coder.homelab.local` |
| Home URL | `https://coder.homelab.local` |
| Valid redirect URIs | `https://coder.homelab.local/api/v2/users/oidc/callback` |
| Valid post logout redirect URIs | `https://coder.homelab.local` |
| Web origins | `https://coder.homelab.local` |

→ **Save**

### 6.4 Client Secret in Vault eintragen

1. Tab **"Credentials"** öffnen
2. **"Client secret"** kopieren
3. In Vault hinterlegen (ersetzt den `REPLACE_AFTER_KEYCLOAK_SETUP`-Platzhalter aus `scripts/setup-coder.sh`):

```bash
kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN=$VAULT_TOKEN vault kv patch secret/homelab/coder/coder-secret \
  oidc-client-secret='<DEIN_SECRET_HIER>'

kubectl annotate externalsecret coder-secret -n coder \
  force-sync="$(date +%s)" --overwrite
```

4. Coder neu starten, damit der neue Secret-Wert (als Env-Var injiziert, wird
   nicht automatisch neu geladen) greift:

```bash
kubectl rollout restart deployment/coder -n coder
kubectl rollout status deployment/coder -n coder --timeout=300s
```
```

- [ ] **Step 4: Verify the edit is well-formed**

Run: `grep -n "^## " docs/keycloak-setup.md`
Expected: sections numbered 1 through 12 consecutively, `6. OIDC-Client: Coder` present, no duplicate numbers.

- [ ] **Step 5: Commit**

```bash
git add docs/keycloak-setup.md
git commit -m "docs(keycloak): add Coder OIDC client section"
git push
```

---

### Task 6: Workspace image — new GitLab project

**Files** (in a new, separate local clone — this is **not** part of the `homelab-infra` git repository, mirroring where the sibling `backstage` app repo lives locally):
- Create: `~/Code/gitlab/coder-workspace/Dockerfile`
- Create: `~/Code/gitlab/coder-workspace/known_hosts`
- Create: `~/Code/gitlab/coder-workspace/.gitlab-ci.yml`

**Interfaces:**
- Produces: image `registry.homelab.local/homelab/projects/coder-workspace:latest` (and `:$CI_COMMIT_SHORT_SHA`), consumed by Task 7's `kubernetes_pod_v1.container.image`.

- [ ] **Step 1: Generate `known_hosts`**

```bash
mkdir -p ~/Code/gitlab/coder-workspace
ssh-keyscan -t ed25519 github.com gitlab.homelab.local > ~/Code/gitlab/coder-workspace/known_hosts 2>/dev/null
cat ~/Code/gitlab/coder-workspace/known_hosts
```

Expected: two non-empty lines, one for `github.com`, one for `gitlab.homelab.local` (GitLab's own `ssh-ed25519` host key, exposed via the `gitlab-ssh` `IngressRouteTCP` in `k8s/charts/gitlab-omnibus/templates/service.yaml`).

- [ ] **Step 2: Write the Dockerfile**

```dockerfile
# Base: same Node major as the backstage app image, gives us Node + npm for
# free; everything else layered on top via apt/pip.
FROM node:24-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg unzip git openssh-client python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# known_hosts for GitHub + the self-hosted GitLab (baked in - not a secret,
# and lets the Coder agent's startup script just point IdentityFile/
# UserKnownHostsFile at fixed paths without re-scanning on every start)
COPY known_hosts /etc/ssh/ssh_known_hosts
RUN chmod 644 /etc/ssh/ssh_known_hosts

# kubectl, matching the k3s server's minor version (v1.34)
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
       | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
       > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y --no-install-recommends kubectl \
    && rm -rf /var/lib/apt/lists/*

# Vault CLI + Terraform (HashiCorp's own apt repo ships both)
RUN curl -fsSL https://apt.releases.hashicorp.com/gpg \
       | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com bookworm main" \
       > /etc/apt/sources.list.d/hashicorp.list \
    && apt-get update && apt-get install -y --no-install-recommends vault terraform \
    && rm -rf /var/lib/apt/lists/*

# Helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Ansible
RUN pip install --break-system-packages --no-cache-dir ansible-core

# Non-root user matching the workspace pod's securityContext (uid/gid 1000).
# node:24-bookworm-slim already ships a "node" user/group at uid/gid 1000,
# so it must be removed first or useradd fails with "UID 1000 is not unique".
RUN userdel -r node && useradd --uid 1000 --create-home --shell /bin/bash coder
USER coder
WORKDIR /home/coder
```

- [ ] **Step 3: Write `.gitlab-ci.yml`** (same Kaniko pattern proven for the `backstage` app repo, `resource_group` fix included from the start)

```yaml
stages:
  - build

build-and-push:
  stage: build
  # Serializes overlapping pipeline runs so a slower job for an older commit
  # can't finish after a newer one and clobber the mutable `:latest` tag.
  resource_group: production
  image:
    name: ghcr.io/osscontainertools/kaniko:v1.28.3-debug
    entrypoint: [""]
  before_script:
    - cat "$HOMELAB_CA_CRT" >> /kaniko/ssl/certs/ca-certificates.crt
  script:
    - mkdir -p /kaniko/.docker
    - |
      cat <<EOF > /kaniko/.docker/config.json
      {
        "auths": {
          "$CI_REGISTRY": {
            "auth": "$(printf "%s:%s" "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD" | base64 | tr -d '\n')"
          }
        }
      }
      EOF
    - /kaniko/executor
      --context "$CI_PROJECT_DIR"
      --dockerfile "$CI_PROJECT_DIR/Dockerfile"
      --destination "$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA"
      --destination "$CI_REGISTRY_IMAGE:latest"
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
```

- [ ] **Step 4: Build the image locally to confirm it's valid**

Run: `docker build -t coder-workspace:test ~/Code/gitlab/coder-workspace/`
Expected: build succeeds (exit code 0); this is the same Dockerfile Kaniko will build in CI, just via a local Docker daemon for a fast feedback loop.

- [ ] **Step 5: Sanity-check the built image**

Run: `docker run --rm coder-workspace:test sh -c "kubectl version --client && helm version && vault --version && terraform --version && ansible --version && node --version && python3 --version"`
Expected: each command prints a version string with no errors.

- [ ] **Step 6: Lint the CI file**

Run: `yamllint ~/Code/gitlab/coder-workspace/.gitlab-ci.yml` (default yamllint rules — this file lives outside `homelab-infra`, so the repo's `.yamllint.yml` doesn't apply)
Expected: no output, or only cosmetic warnings (e.g. line length) — no errors.

- [ ] **Step 7: Initialize the local repo (project creation + push happen in Task 10)**

```bash
cd ~/Code/gitlab/coder-workspace
git init
git add Dockerfile known_hosts .gitlab-ci.yml
git commit -m "feat: add coder workspace image (kubectl/helm/vault/terraform/ansible)"
```

Do not push — the GitLab project `homelab/projects/coder-workspace` doesn't exist yet; Task 10's runbook creates it and pushes.

---

### Task 7: Coder Terraform workspace template

**Files:**
- Create: `k8s/coder-templates/homelab-workspace/main.tf`

**Interfaces:**
- Consumes: `ServiceAccount coder-workspace-admin` (Task 3), `Secret coder-secret` key `git-ssh-private-key` (Task 2), `Secret coder-workspace-registry-pull` (Task 2), image `registry.homelab.local/homelab/projects/coder-workspace:latest` (Task 6).
- Produces: the Coder template `homelab-workspace`, consumed by Task 10 (workspace creation).

- [ ] **Step 1: Write `main.tf`**

```hcl
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
  }
}

provider "coder" {}

provider "kubernetes" {
  # Coder server runs in-cluster (namespace "coder") under a ServiceAccount
  # with workspace-management permissions - no kubeconfig needed.
  config_path = null
}

locals {
  namespace = "coder"
  image     = "registry.homelab.local/homelab/projects/coder-workspace:latest"
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<-EOT
    set -e

    # SSH config for GitHub + the self-hosted GitLab. The private key comes
    # from a Secret volume mounted read-only outside the persistent home PVC
    # (ExternalSecret "coder-secret", key "git-ssh-private-key"); known_hosts
    # is baked into the image at /etc/ssh/ssh_known_hosts.
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if [ ! -f "$HOME/.ssh/config" ]; then
      cat <<-'SSHCFG' > "$HOME/.ssh/config"
      Host github.com gitlab.homelab.local
        IdentityFile /etc/coder/ssh/id_ed25519
        UserKnownHostsFile /etc/ssh/ssh_known_hosts
        IdentitiesOnly yes
      SSHCFG
      chmod 600 "$HOME/.ssh/config"
    fi
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-homelab-workspace-home"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

resource "kubernetes_pod_v1" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-homelab-workspace"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
    }
  }

  spec {
    service_account_name = "coder-workspace-admin"

    image_pull_secrets {
      name = "coder-workspace-registry-pull"
    }

    security_context {
      run_as_user     = 1000
      fs_group        = 1000
      run_as_non_root = true
    }

    container {
      name              = "dev"
      image             = local.image
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        run_as_user = "1000"
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu    = "1"
          memory = "2Gi"
        }
        limits = {
          cpu    = "4"
          memory = "8Gi"
        }
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
      }

      volume_mount {
        mount_path = "/etc/coder/ssh"
        name       = "git-ssh-key"
        read_only  = true
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata.0.name
      }
    }

    volume {
      name = "git-ssh-key"
      secret {
        secret_name  = "coder-secret"
        default_mode = "0400"
        items {
          key  = "git-ssh-private-key"
          path = "id_ed25519"
        }
      }
    }
  }
}
```

- [ ] **Step 2: Format check**

Run: `terraform fmt -check k8s/coder-templates/homelab-workspace/`
Expected: no output, exit code 0. If it fails, run `terraform fmt k8s/coder-templates/homelab-workspace/` and re-check.

- [ ] **Step 3: Init and validate**

```bash
cd k8s/coder-templates/homelab-workspace
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
cd ../../..
git add k8s/coder-templates/homelab-workspace/
git commit -m "feat(coder): add homelab-workspace Terraform template"
git push
```

(Also add `.terraform/` and `.terraform.lock.hcl` from Step 3 to the repo's `.gitignore` if not already covered by an existing `**/.terraform/` pattern — check `git status` after Step 3 and add an ignore rule if `.terraform/` shows as untracked.)

---

### Task 8: `scripts/deploy-coder-template.sh`

**Files:**
- Create: `scripts/deploy-coder-template.sh`

**Interfaces:**
- Consumes: `k8s/coder-templates/homelab-workspace/` (Task 7), a running, reachable Coder server (Task 4) and an active `coder login` session (manual, Task 10).

- [ ] **Step 1: Write the script**

```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
#  deploy-coder-template.sh
#  Pushes the Terraform-defined Coder workspace template
#  (k8s/coder-templates/homelab-workspace/) to the running Coder instance.
#  Coder templates aren't native Kubernetes resources ArgoCD can sync
#  directly, so this stays a manual/scripted step - matching this repo's
#  scripts/setup-<service>.sh convention.
#
#  VORAUSSETZUNGEN:
#  - coder CLI installiert (https://coder.com/docs/install/cli)
#  - Eingeloggt: coder login https://coder.homelab.local
#
#  USAGE:
#    ./scripts/deploy-coder-template.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/k8s/coder-templates/homelab-workspace"

echo "==> Pushing Coder template from ${TEMPLATE_DIR}..."
coder templates push homelab-workspace \
  --directory "${TEMPLATE_DIR}" \
  --yes

echo "    Template gepusht. Workspace erstellen mit:"
echo "      coder create --template homelab-workspace <workspace-name>"
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/deploy-coder-template.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Make executable and commit**

```bash
chmod +x scripts/deploy-coder-template.sh
git add scripts/deploy-coder-template.sh
git commit -m "feat(coder): add template deploy script"
git push
```

Do not run it yet — the Coder server (Task 4) isn't deployed/reachable until Task 10's rollout sequence gets there.

---

### Task 9: Backstage catalog entry

**Files:**
- Create: `catalog/coder/catalog-info.yaml`
- Create: `catalog/coder/mkdocs.yml`
- Create: `catalog/coder/docs/index.md`
- Modify: `catalog/all.yaml`

**Interfaces:** none — pure catalog metadata, per CLAUDE.md's Backstage-catalog-sync convention.

- [ ] **Step 1: Write `catalog-info.yaml`**

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: coder
  description: Persistent remote dev workspace (VS Code Remote SSH)
  annotations:
    argocd/app-name: coder
    backstage.io/kubernetes-id: coder
    backstage.io/techdocs-ref: dir:.
  links:
    - url: https://coder.homelab.local
      title: Coder
spec:
  type: service
  lifecycle: production
  owner: group:homelab
  system: homelab
```

- [ ] **Step 2: Write `mkdocs.yml`**

```yaml
site_name: Coder
```

- [ ] **Step 3: Write `docs/index.md`**

```markdown
## What it is

A persistent, always-on remote development workspace — a self-hosted [Coder](https://coder.com) instance plus one long-running workspace `Pod`, reachable from any machine via VS Code Desktop's Remote SSH (through the Coder extension), with identical tooling and state (uncommitted changes, shell history, caches) regardless of which machine connects.

## Why it's here

Johannes develops this repo (and a few others) from three machines — a personal PC, a work laptop, and a private laptop. Rather than keeping `kubectl`/`helm`/the Vault CLI/`terraform`/`ansible`/Node.js/Python in sync across all three, one workspace runs in-cluster with cluster-admin-equivalent access (the same level already available from the Mac) and all three machines just SSH into it.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/coder.yaml` — Coder's official Helm chart (`coder/coder`, `https://helm.coder.com/v2`, pinned `2.37.0`), destination namespace `coder`.
- Database: the `coder` Postgres role/database on the shared `homelab-pg` CNPG cluster (`k8s/infrastructure/postgres-cluster.yaml`), created by `scripts/setup-coder.sh`.
- OIDC: mandatory login via Keycloak (`CODER_DISABLE_PASSWORD_AUTH=true`), client `coder` documented in `docs/keycloak-setup.md` section 6.
- Secrets: `k8s/security/external-secrets/coder/coder-secret.yaml` (Vault path `homelab/coder/coder-secret` — DB password, OIDC client secret, git SSH private key) and `k8s/security/external-secrets/coder/coder-workspace-registry-pull.yaml` (Vault path `homelab/coder/registry-pull-secret`).
- Workspace RBAC: `k8s/security/coder-workspace-admin-rbac.yaml` — `ServiceAccount coder-workspace-admin` bound to the built-in `cluster-admin` `ClusterRole`, synced via the `security-manifests` app. Explicit accepted risk — see `docs/superpowers/specs/2026-09-03-coder-dev-workspace-design.md`.
- Workspace image: built from a separate GitLab project, `homelab/projects/coder-workspace` (Dockerfile with `kubectl`/`helm`/the Vault CLI/`git`/`terraform`/`ansible`/Node.js/Python), via GitLab CI + Kaniko, pushed to `registry.homelab.local/homelab/projects/coder-workspace`.
- Workspace template: `k8s/coder-templates/homelab-workspace/main.tf` (Terraform, `coder`+`hashicorp/kubernetes` providers), pushed to the running Coder instance via `scripts/deploy-coder-template.sh` — not synced by ArgoCD, since Coder templates aren't native Kubernetes resources.
- Ingress: `coder.homelab.local` via Traefik, `homelab-wildcard-tls`, reachable only over Tailscale.

## How to change it

- **Rotate the OIDC client secret or DB password**: write the new value to Vault at the relevant `homelab/coder/coder-secret` key, then force-sync: `kubectl -n coder annotate externalsecret coder-secret force-sync=$(date +%s) --overwrite`.
- **Add a tool to the workspace image**: edit the `Dockerfile` in the `coder-workspace` GitLab project, push to `main` — CI builds and pushes `registry.homelab.local/homelab/projects/coder-workspace:latest` automatically. Restart the workspace pod (`imagePullPolicy: Always`) to pick it up.
- **Change workspace resources/disk size**: edit `k8s/coder-templates/homelab-workspace/main.tf`, then re-run `./scripts/deploy-coder-template.sh` and let Coder re-provision the workspace.
- **Rotate the git SSH deploy key**: re-run the SSH-keygen section of `scripts/setup-coder.sh` (delete the Vault path first to force regeneration), register the new public key with GitHub/GitLab, restart the workspace pod.
```

- [ ] **Step 4: Add the new entry to `catalog/all.yaml`**

In `catalog/all.yaml`, insert `- ./coder/catalog-info.yaml` between `- ./cert-manager-webhook-hetzner/catalog-info.yaml` and `- ./external-secrets/catalog-info.yaml`:

```yaml
    - ./cert-manager-webhook-hetzner/catalog-info.yaml
    - ./coder/catalog-info.yaml
    - ./external-secrets/catalog-info.yaml
```

- [ ] **Step 5: Lint**

Run: `yamllint -c .yamllint.yml catalog/coder/catalog-info.yaml catalog/coder/mkdocs.yml catalog/all.yaml`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add catalog/coder/ catalog/all.yaml
git commit -m "feat(catalog): add Coder to Backstage catalog"
git push
```

---

### Task 10: End-to-end rollout runbook

**Files:**
- Create: `docs/coder-setup.md`

**Interfaces:** none — this is the document the user follows to actually execute every manual step from Tasks 1–9 in order and verify the result, mirroring `docs/keycloak-setup.md`/`docs/gitlab-runner-setup.md`'s structure.

- [ ] **Step 1: Write the runbook**

```markdown
# Coder Remote Dev Workspace Setup Runbook

Einmaliger Setup-Guide für den persistenten Coder Dev-Workspace.
Voraussetzung: Tasks 1-9 aus dem Implementation Plan sind committed.

**Voraussetzungen:**
- `kubectl` konfiguriert, Cluster erreichbar
- `VAULT_TOKEN` als Env-Var gesetzt
- Du bist im Tailscale-Netz, `*.homelab.local` löst auf
- Coder CLI installiert: https://coder.com/docs/install/cli
- Zugriff auf die self-hosted GitLab-Instanz (`gitlab.homelab.local`)

---

## 1. Vault-Secrets + Postgres-DB anlegen

```bash
export VAULT_TOKEN="..."
./scripts/setup-coder.sh
```

Merke dir den ausgegebenen öffentlichen SSH-Schlüssel für Schritt 4.

---

## 2. Keycloak OIDC-Client anlegen

Siehe `docs/keycloak-setup.md`, Abschnitt 6 ("OIDC-Client: Coder") - Client anlegen,
echtes Client Secret nach Vault schreiben und den `coder`-Deployment-Restart
ausführen (Befehle stehen im Runbook-Abschnitt selbst).

---

## 3. Coder Server verifizieren

Der Server wurde bereits während der Implementierung live deployt und
validiert (Task 4 des Implementation Plans appliziert die gerenderten
Manifeste direkt, bevor sie committed/gepusht werden) und läuft inzwischen
unter ArgoCD-Verwaltung. Nach Schritt 2 hier oben nur noch den echten
OIDC-Login bestätigen:

```bash
kubectl get application coder -n argocd
# STATUS sollte "Synced" / "Healthy" sein
```

`https://coder.homelab.local` im Browser öffnen - Erfolgreich wenn der
Keycloak-Login-Button erscheint (kein E-Mail/Passwort-Formular, da
`CODER_DISABLE_PASSWORD_AUTH=true`) und der Login mit den AD-Credentials
funktioniert.

---

## 4. GitLab-Projekt für das Workspace-Image anlegen

1. `https://gitlab.homelab.local` → **New project** → `homelab/projects/coder-workspace`
2. **Settings → CI/CD → Variables** → `HOMELAB_CA_CRT` als File-Variable setzen
   (gleicher Wert wie beim `backstage`-Projekt)
3. Deployed SSH-Key/User-SSH-Key mit dem öffentlichen Schlüssel aus Schritt 1
   hinterlegen (**Settings → Repository → Deploy keys**, oder als eigener
   User-SSH-Key falls der Key einem GitLab-User zugeordnet werden soll)
4. Push:

```bash
cd ~/Code/gitlab/coder-workspace
git remote add origin git@gitlab.homelab.local:homelab/projects/coder-workspace.git
git push -u origin main
```

5. Pipeline beobachten: `https://gitlab.homelab.local/homelab/projects/coder-workspace/-/pipelines`
6. Auf GitHub: den gleichen öffentlichen Schlüssel aus Schritt 1 als Deploy Key
   für `homelab-infra` hinterlegen (**Settings → Deploy keys**, read-only reicht
   für Pull, read-write falls der Workspace auch pushen soll).

---

## 5. Workspace-Template pushen

```bash
coder login https://coder.homelab.local
./scripts/deploy-coder-template.sh
```

---

## 6. Workspace erstellen

```bash
coder create --template homelab-workspace homelab
```

---

## 7. Verifikation (von allen drei Maschinen)

- [ ] VS Code Desktop: Coder-Extension installieren, `coder.homelab.local` als
      Server eintragen, Login via Keycloak im Browser (einmalig)
- [ ] Workspace `homelab` verbinden - gleiche Dateien/Shell-History wie von den
      anderen zwei Maschinen aus sichtbar
- [ ] Im Workspace-Terminal:
  ```bash
  kubectl get nodes
  helm list -A
  vault status -address=http://vault.security.svc.cluster.local:8200
  ```
  Alle drei ohne zusätzliches Setup erfolgreich.
- [ ] Git-Zugriff:
  ```bash
  git clone git@github.com:JoyoMDEV/homelab-infra.git /tmp/test-github
  git clone git@gitlab.homelab.local:homelab/projects/backstage.git /tmp/test-gitlab
  ```
  Beide ohne Passwort-/Fingerprint-Prompt erfolgreich.
- [ ] Persistenz: eine Testdatei anlegen, Pod neu starten lassen
      (`kubectl delete pod -n coder -l com.coder.resource=true`), Datei ist
      nach dem Neustart noch da.

---

## 8. Troubleshooting

**Coder Pod crasht mit "connect: connection refused" (Postgres)**
```bash
kubectl get pods -n infrastructure | grep homelab-pg
# Postgres muss Running sein, bevor Coder startet
```

**OIDC-Login schlägt fehl**
```bash
kubectl logs -n coder -l app.kubernetes.io/name=coder --tail=50 | grep -i oidc
```
Prüfen: Redirect-URI in Keycloak muss exakt
`https://coder.homelab.local/api/v2/users/oidc/callback` sein.

**Workspace-Pod hängt in `ImagePullBackOff`**
```bash
kubectl describe pod -n coder -l com.coder.resource=true | grep -A5 Events
```
Meist: `coder-workspace-registry-pull` Secret fehlt/veraltet - Token in Vault
prüfen (`homelab/coder/registry-pull-secret`) und
`kubectl -n coder annotate externalsecret coder-workspace-registry-pull force-sync=$(date +%s) --overwrite`.
```

- [ ] **Step 2: Verify the doc's internal cross-references**

Run: `grep -c "^## " docs/coder-setup.md`
Expected: `8` (one per top-level section, matching the runbook's own numbering 1-8).

- [ ] **Step 3: Commit**

```bash
git add docs/coder-setup.md
git commit -m "docs(coder): add end-to-end rollout runbook"
git push
```

---

## Self-Review Notes

- **Spec coverage:** Coder server (Task 4), Postgres reuse (Task 1), OIDC-mandatory (Task 4/5), Vault-backed secrets (Task 1/2), Traefik ingress/Tailscale-only (Task 4), workspace RBAC as a static manifest (Task 3), workspace image via GitLab CI + Kaniko (Task 6), Terraform template with PVC (Task 7), template push script (Task 8), git access from the workspace (Task 6/7/10), Backstage catalog sync (Task 9, CLAUDE.md requirement not in the original spec text but required by repo convention), rollout order and all six "Testing" bullets from the spec (Task 10).
- **Placeholder scan:** none — every file has literal, complete content; the spec's two deliberately-deferred decisions (exact workspace-image tool list, exact git-credential mechanism) are resolved concretely in Task 6/7 rather than left open.
- **Type/name consistency checked:** `coder-secret` keys (`db-password`, `oidc-client-secret`, `git-ssh-private-key`, `pg-connection-url`) match across Tasks 1, 2, 4, 7; `coder-workspace-admin` ServiceAccount name matches across Tasks 3 and 7; `coder-workspace-registry-pull` Secret name matches across Tasks 2 and 7; Vault paths (`homelab/coder/coder-secret`, `homelab/coder/registry-pull-secret`) match across Tasks 1, 2, 10; image reference `registry.homelab.local/homelab/projects/coder-workspace:latest` matches across Tasks 6, 7, 9.
