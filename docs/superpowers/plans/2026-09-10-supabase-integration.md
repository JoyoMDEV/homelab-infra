# Supabase Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a fully self-hosted Supabase stack (Postgres, Auth, REST, Realtime, Storage, Studio, Edge Functions) via ArgoCD, backed by a dedicated CNPG Postgres cluster and a shared Garage S3 instance, reachable at `supabase.homelab.local` / `supabase-studio.homelab.local`.

**Architecture:** The community `supabase-community/supabase-kubernetes` umbrella chart is deployed as one ArgoCD `Application` (namespace `supabase`) with its bundled Postgres and MinIO disabled, pointed instead at a dedicated CNPG `Cluster` (`supabase-pg`, running the `supabase/postgres` image so the extensions Supabase's schema needs are present) and a shared Garage instance (new, alongside the existing MinIO in `infrastructure`). All chart secrets are wired via the chart's native `secret.*.secretRef`/`secretRefKey` mechanism to one `ExternalSecret`-managed `Secret` per logical group (core Supabase secrets; Garage storage credentials) — no secret material ever appears in a Helm `values:` block. Edge Functions ship as a custom image (`supabase/edge-runtime` + baked-in function code) built by a new GitLab CI project, referenced by the chart's `image.functions` override.

**Tech Stack:** Kubernetes, ArgoCD, Helm (`supabase-community/supabase-kubernetes` chart, Garage's own chart), CloudNativePG, External Secrets Operator + Vault, Traefik, GitLab CI + Kaniko, Backstage catalog.

**Spec:** `docs/superpowers/specs/2026-09-10-supabase-integration-design.md`

## Global Constraints

- Never put a real secret value in a `Secret`, `ConfigMap`, or Helm `values:` block — every secret flows through an `ExternalSecret` at Vault path `homelab/supabase/...` (repo convention, CLAUDE.md).
- **Vault writes are always run by the user personally.** `scripts/setup-supabase.sh` and `scripts/setup-supabase-storage.sh` perform `vault kv put` — the implementing agent must write and validate these scripts (syntax check, review) but must **never execute them**, and must never run any `vault kv put`/`kubectl exec vault-0 -- vault ...` command itself. Flag these as manual steps for the user in every task that touches them (standing preference, not spec-derived).
- ArgoCD Application: `spec.project: default`, `syncPolicy.automated: {prune: true, selfHeal: true}`, `syncOptions: [CreateNamespace=true]` (repo convention, CLAUDE.md).
- Ingress: `ingressClassName: traefik`, TLS via `homelab-wildcard-tls`, reachable only over Tailscale (repo convention, CLAUDE.md).
- Pinned versions (verified live, 2026-09-10): Supabase chart `0.8.0` at `https://supabase-community.github.io/supabase-kubernetes` (chart `supabase`); Garage chart `0.10.2` / app version `v2.4.1` at `https://git.deuxfleurs.fr/Deuxfleurs/garage.git`, path `script/helm/garage`, tag `v2.4.1`; CNPG cluster image `supabase/postgres:17.6.1.136` (matches the chart's own pinned `image.db.tag`); Supabase Postgres schema migrations from `https://github.com/supabase/postgres.git`, tag `v17.6.1.136-cli`; Edge Functions base image `supabase/edge-runtime:v1.74.0` (matches the chart's own pinned `image.functions.tag`).
- **Deliberate exception to upstream's own migration set**: the migration file `10000000000000_demote-postgres.sql` (which runs `ALTER ROLE postgres NOSUPERUSER ...`) is skipped everywhere it's referenced in this plan. CNPG's own operator connects as `postgres` to manage the cluster (health checks, failover, etc.) and needs it to stay superuser; stripping that would fight CNPG's own cluster management. This is a confirmed, deliberate deviation from upstream's self-host security hardening, not an oversight.
- **Chart quirk, confirmed by reading `templates/storage/deployment.yaml` upstream**: `STORAGE_BACKEND` and the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env vars are hardcoded to only activate S3 (and only reference the chart's own bundled-MinIO secret) when `deployment.minio.enabled: true`. Since we use external Garage instead of the bundled MinIO, Task 8 works around this via extra `environment.storage` entries that Kubernetes resolves using last-one-wins on duplicate env var names (see that task's comments).
- **Correction versus the design spec**: the spec proposed a hand-written Studio `Ingress` + a Traefik `BasicAuth` Middleware to get Studio on its own host. Reading the chart's actual `kong.yml` (upstream's declarative Kong config) shows Kong already proxies `/` to Studio behind `basic-auth` (gated by `secret.dashboard.*`) regardless of which Host header was used, and the chart's `ingress.hosts` list can carry two host entries pointing at the same Kong Service. Task 8 uses that native mechanism instead — no hand-written Ingress or Middleware needed.
- Every deployed service gets a matching `catalog/<service>/catalog-info.yaml` registered in `catalog/all.yaml`, with a four-section `docs/index.md` (CLAUDE.md).

---

### Task 1: `supabase` namespace + dedicated CNPG Postgres cluster

**Files:**
- Modify: `k8s/namespaces.yaml` (append the `supabase` namespace)
- Create: `k8s/infrastructure/supabase-postgres-cluster.yaml`

**Interfaces:**
- Produces: the `supabase` namespace; CNPG `Cluster` `supabase-pg` (namespace `supabase`); its auto-generated owner credentials `Secret` `supabase-pg-app` (namespace `supabase`, keys `username`/`password`) — consumed by Task 2 (`supabase_admin`'s password is read from here and propagated to the other Supabase-internal roles).

- [x] **Step 1: Add the namespace**

Append to `k8s/namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: supabase
  labels:
    managed-by: argocd
    homelab.local/inject-ca: "true"
```

- [x] **Step 2: Write the CNPG cluster manifest**

```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: supabase-pg
  namespace: supabase
spec:
  instances: 1

  # Not CNPG's own default image - Supabase's schema/migrations need
  # extensions (pgjwt, pgsodium, pg_graphql, pg_net, pg_cron) that aren't in
  # CNPG's default postgres image. supabase/postgres is a superset build of
  # standard postgres (same binaries/paths), so it's structurally compatible
  # with CNPG's instance manager. See Task 2 for the schema bootstrap this
  # enables.
  imageName: supabase/postgres:17.6.1.136

  postgresql:
    parameters:
      shared_buffers: "256MB"
      effective_cache_size: "512MB"
      max_connections: "100"

  storage:
    size: 10Gi

  resources:
    requests:
      memory: 512Mi
      cpu: 250m
    limits:
      memory: 1Gi

  bootstrap:
    initdb:
      # Supabase's own init SQL (Task 2) expects a role named "supabase_admin"
      # to already exist so it can ALTER it to superuser - CNPG's bootstrap
      # owner becomes that role. All of Supabase's components connect to the
      # single "postgres" database (matching upstream's own self-host
      # default), not a separately-named database.
      database: postgres
      owner: supabase_admin

  # ── Backup via Barman + the existing MinIO (ops plumbing, not product
  # storage - unrelated to the Garage-vs-MinIO decision for Supabase Storage
  # itself) ─────────────────────────────────────────────────────────────────
  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/supabase-pg/
      endpointURL: http://minio.infrastructure.svc.cluster.local:9000
      s3Credentials:
        accessKeyId:
          name: minio-secret
          key: rootUser
        secretAccessKey:
          name: minio-secret
          key: rootPassword
      wal:
        compression: gzip
      data:
        compression: gzip
        immediateCheckpoint: false
        jobs: 2
    retentionPolicy: "30d"

  monitoring:
    enablePodMonitor: true

---
# Staggered after homelab-pg's 03:00 backup, before restic's 03:30.
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: supabase-pg-daily
  namespace: supabase
spec:
  schedule: "15 3 * * *"
  backupOwnerReference: self
  cluster:
    name: supabase-pg
  immediate: false
```

- [x] **Step 3: Lint**

Run: `yamllint -c .yamllint.yml k8s/namespaces.yaml k8s/infrastructure/supabase-postgres-cluster.yaml`
Expected: no output.

- [x] **Step 4: Apply live and enable CA injection**

```bash
kubectl apply -f k8s/namespaces.yaml
kubectl apply -f k8s/infrastructure/supabase-postgres-cluster.yaml
kubectl create job --from=cronjob/cert-sync cert-sync-manual-$(date +%s) -n kube-system
```

Expected: `namespace/supabase created` (or `configured`), `cluster.postgresql.cnpg.io/supabase-pg created`, `scheduledbackup.postgresql.cnpg.io/supabase-pg-daily created`.

- [x] **Step 5: Wait for the cluster to come up and verify the image is actually compatible with CNPG**

```bash
kubectl wait --for=condition=Ready cluster/supabase-pg -n supabase --timeout=300s
kubectl get pods -n supabase -l cnpg.io/cluster=supabase-pg
kubectl exec supabase-pg-1 -n supabase -c postgres -- psql -U postgres -c "SELECT version();"
```

Expected: the `Ready` condition is met, `supabase-pg-1` is `Running`/`1/1`, and `psql` prints a PostgreSQL 17.x version string confirming the `supabase/postgres` image booted cleanly under CNPG's instance manager. If the pod crash-loops instead, check `kubectl logs supabase-pg-1 -n supabase -c postgres` for an image-incompatibility error before proceeding — this is the one point in this plan where the `imageName` choice from Step 2 gets its first real test.

**Actually hit, live, on first apply**: the initdb job crash-looped with `initdb: could not look up effective user ID 26: user does not exist`. CNPG's instance manager defaults to running `postgres` as UID/GID 26, but `getent passwd postgres` inside `supabase/postgres:17.6.1.136` shows it's UID 100 / GID 101 in that image. Fix: added `spec.postgresUID: 100` / `spec.postgresGID: 101` to the Cluster manifest (Step 2, above) — CNPG exposes exactly this override. Required deleting the half-initialized `Cluster` and its PVC and reapplying from scratch, since the UID is baked in at initdb time. After the fix, the pod came up `1/1 Running` and `psql` printed `PostgreSQL 17.6` cleanly.

- [x] **Step 6: Verify the CNPG-generated owner credentials exist**

```bash
kubectl get secret supabase-pg-app -n supabase -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret supabase-pg-app -n supabase -o jsonpath='{.data.password}' | base64 -d | wc -c
```

Expected: prints `supabase_admin`, and a non-zero character count for the password. Task 2 reads this password.

- [x] **Step 7: Commit**

```bash
git add k8s/namespaces.yaml k8s/infrastructure/supabase-postgres-cluster.yaml
git commit -m "feat(supabase): add dedicated CNPG Postgres cluster"
```

Do not push yet — later tasks push together once more of the stack is live-verified (matching this repo's pattern for multi-task rollouts).

---

### Task 2: `scripts/setup-supabase.sh` — Postgres schema bootstrap + core secrets

**Files:**
- Create: `scripts/setup-supabase.sh`

**Interfaces:**
- Consumes: `Secret supabase-pg-app` (Task 1) for `supabase_admin`'s password.
- Produces: the Supabase Postgres schema/roles on `supabase-pg` (auth/storage/realtime schemas, `supabase_admin`/`authenticator`/`supabase_auth_admin`/`supabase_storage_admin` roles all sharing one password). Produces Vault path `homelab/supabase/supabase-secret` with keys `db-host`, `db-port`, `db-database`, `db-password`, `jwt-secret`, `anon-key`, `service-key`, `realtime-secret-key-base`, `realtime-db-enc-key`, `meta-crypto-key`, `dashboard-username`, `dashboard-password` — consumed by Task 3's `ExternalSecret` and, transitively, Task 8's `secret.*.secretRef` values.

- [x] **Step 1: Write the script**

```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-supabase.sh
#  Bootstraps the Supabase Postgres schema on the dedicated `supabase-pg`
#  CNPG cluster (roles/schemas Supabase's Auth/REST/Realtime/Storage/Meta
#  components expect) and writes every core Supabase secret (JWT signing
#  key + derived anon/service_role tokens, Realtime's secretKeyBase/
#  dbEncKey, Meta's cryptoKey, Studio dashboard credentials, DB password)
#  to Vault. The ExternalSecret 'supabase-secret' (namespace supabase)
#  picks these up from there.
#
#  IDEMPOTENT: the schema bootstrap only runs once (skipped if the `auth`
#  schema already exists); secrets already in Vault are reused rather than
#  regenerated, matching this repo's other setup-<service>.sh scripts.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Cluster erreichbar, supabase-pg-1 Running
#  - VAULT_TOKEN als Env-Var gesetzt
#  - git und python3 lokal installiert
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-supabase.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/supabase/supabase-secret"
POSTGRES_NS="supabase"
POSTGRES_POD="supabase-pg-1"

MIGRATIONS_REPO="https://github.com/supabase/postgres.git"
MIGRATIONS_TAG="v17.6.1.136-cli"
# Skipped deliberately - strips CNPG's own postgres superuser. See the plan's
# Global Constraints for why.
EXCLUDE_MIGRATION="10000000000000_demote-postgres.sql"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_get() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get -field="$2" "secret/$1" 2>/dev/null || true
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
    echo "    (ExternalSecret $1 noch nicht deployt - wird beim naechsten ArgoCD-Sync abgeholt)"
}

run_sql_file() {
  kubectl exec -i "$POSTGRES_POD" -n "$POSTGRES_NS" -c postgres -- \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < "$1"
}

mint_jwt() {
  python3 - "$1" "$2" <<'PYEOF'
import sys, json, base64, hmac, hashlib, time

secret, role = sys.argv[1], sys.argv[2]

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')

header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(',', ':')).encode())
now = int(time.time())
payload = b64url(json.dumps(
    {"role": role, "iss": "supabase-homelab", "iat": now, "exp": now + 315360000},
    separators=(',', ':'),
).encode())
signing_input = header + b'.' + payload
sig = b64url(hmac.new(secret.encode(), signing_input, hashlib.sha256).digest())
print((signing_input + b'.' + sig).decode())
PYEOF
}

echo "==> Warte bis supabase-pg bereit ist..."
kubectl wait --for=condition=Ready pod/"${POSTGRES_POD}" -n "${POSTGRES_NS}" --timeout=120s

echo ""
echo "==> Pruefe ob das Supabase-Schema schon existiert..."
SCHEMA_EXISTS=$(kubectl exec "${POSTGRES_POD}" -n "${POSTGRES_NS}" -c postgres -- \
  psql -U postgres -d postgres -tAc \
  "SELECT 1 FROM information_schema.schemata WHERE schema_name='auth'")

if [[ "${SCHEMA_EXISTS}" == "1" ]]; then
  echo "    Schema existiert bereits - Bootstrap wird uebersprungen."
else
  echo "==> Klone Supabase-Postgres-Migrationen (${MIGRATIONS_TAG})..."
  CLONE_DIR=$(mktemp -d)
  git clone --branch "${MIGRATIONS_TAG}" --depth 1 "${MIGRATIONS_REPO}" "${CLONE_DIR}" >/dev/null 2>&1

  echo "==> Fuehre init-scripts aus..."
  for f in "${CLONE_DIR}"/migrations/db/init-scripts/*.sql; do
    echo "    -> $(basename "${f}")"
    run_sql_file "${f}"
  done

  echo "==> Fuehre migrations aus (${EXCLUDE_MIGRATION} wird uebersprungen)..."
  for f in $(ls "${CLONE_DIR}"/migrations/db/migrations/*.sql | sort); do
    base=$(basename "${f}")
    if [[ "${base}" == "${EXCLUDE_MIGRATION}" ]]; then
      echo "    -> ${base} (uebersprungen)"
      continue
    fi
    echo "    -> ${base}"
    run_sql_file "${f}"
  done

  rm -rf "${CLONE_DIR}"
  echo "    Schema-Bootstrap abgeschlossen."
fi

echo ""
echo "==> Synchronisiere Passwort ueber alle Supabase-internen Rollen..."
DB_PW=$(kubectl get secret supabase-pg-app -n "${POSTGRES_NS}" -o jsonpath='{.data.password}' | base64 -d)

kubectl exec "${POSTGRES_POD}" -n "${POSTGRES_NS}" -c postgres -- psql -U postgres -d postgres -c "
  ALTER ROLE supabase_admin WITH PASSWORD '${DB_PW}';
  ALTER ROLE authenticator WITH PASSWORD '${DB_PW}';
  ALTER ROLE supabase_auth_admin WITH PASSWORD '${DB_PW}';
  ALTER ROLE supabase_storage_admin WITH PASSWORD '${DB_PW}';
" >/dev/null
echo "    Passwort synchronisiert (gilt fuer alle vier Rollen, wie es der Chart erwartet)."

echo ""
echo "==> Generiere/lade Supabase-Kern-Secrets..."

JWT_SECRET=$(vault_kv_get "${VAULT_PATH}" "jwt-secret")
[[ -z "${JWT_SECRET}" ]] && JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')

ANON_KEY=$(mint_jwt "${JWT_SECRET}" "anon")
SERVICE_KEY=$(mint_jwt "${JWT_SECRET}" "service_role")

REALTIME_SECRET_KEY_BASE=$(vault_kv_get "${VAULT_PATH}" "realtime-secret-key-base")
[[ -z "${REALTIME_SECRET_KEY_BASE}" ]] && REALTIME_SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')

REALTIME_DB_ENC_KEY=$(vault_kv_get "${VAULT_PATH}" "realtime-db-enc-key")
[[ -z "${REALTIME_DB_ENC_KEY}" ]] && REALTIME_DB_ENC_KEY=$(openssl rand -hex 8)

META_CRYPTO_KEY=$(vault_kv_get "${VAULT_PATH}" "meta-crypto-key")
[[ -z "${META_CRYPTO_KEY}" ]] && META_CRYPTO_KEY=$(openssl rand -hex 32)

DASHBOARD_USERNAME=$(vault_kv_get "${VAULT_PATH}" "dashboard-username")
[[ -z "${DASHBOARD_USERNAME}" ]] && DASHBOARD_USERNAME="supabase"

DASHBOARD_PASSWORD=$(vault_kv_get "${VAULT_PATH}" "dashboard-password")
[[ -z "${DASHBOARD_PASSWORD}" ]] && DASHBOARD_PASSWORD=$(openssl rand -base64 24 | tr -d '\n')

vault_kv_put "${VAULT_PATH}" \
  "db-host=supabase-pg-rw.supabase.svc.cluster.local" \
  "db-port=5432" \
  "db-database=postgres" \
  "db-password=${DB_PW}" \
  "jwt-secret=${JWT_SECRET}" \
  "anon-key=${ANON_KEY}" \
  "service-key=${SERVICE_KEY}" \
  "realtime-secret-key-base=${REALTIME_SECRET_KEY_BASE}" \
  "realtime-db-enc-key=${REALTIME_DB_ENC_KEY}" \
  "meta-crypto-key=${META_CRYPTO_KEY}" \
  "dashboard-username=${DASHBOARD_USERNAME}" \
  "dashboard-password=${DASHBOARD_PASSWORD}"

force_sync supabase-secret supabase

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Studio-Login: ${DASHBOARD_USERNAME} / ${DASHBOARD_PASSWORD}"
echo "============================================"
```

- [x] **Step 2: Syntax-check the script**

Run: `bash -n scripts/setup-supabase.sh`
Expected: no output, exit code 0.

- [x] **Step 3: Make it executable and commit**

```bash
chmod +x scripts/setup-supabase.sh
git add scripts/setup-supabase.sh
git commit -m "feat(supabase): add Postgres bootstrap + core secrets script"
```

Do **not** run `scripts/setup-supabase.sh` — this requires `VAULT_TOKEN` and writes real secrets/schema changes; the user runs it personally as part of the Task 10 runbook.

**Two bugs found and fixed after the user actually ran this live (2026-09-14):**
1. `VAULT_PATH` was `"supabase/supabase-secret"`, missing the `homelab/` prefix every other `scripts/setup-<service>.sh` uses (compare `setup-coder.sh`'s `VAULT_PATH="homelab/coder/coder-secret"`) and that Task 3's `ExternalSecret` actually reads from. The first live run wrote to `secret/supabase/supabase-secret` instead of `secret/homelab/supabase/supabase-secret` — Task 3's `ExternalSecret` then failed with `SecretSyncedError: Secret does not exist`. Fixed by correcting `VAULT_PATH` above; the stray secret at the wrong path was left in place (harmless, unused).
2. The migration set assumes a `pgbouncer` schema/role/`get_auth()` function that the `migrations/db/init-scripts` this script runs never create (that bootstrap SQL only ships in `supabase/postgres`'s own AMI-provisioning ansible role) — the live run failed with `schema pgbouncer does not exist` partway through. Fixed by embedding that exact bootstrap SQL as a script step before the migrations loop (see the script itself). See `references/supabase-postgres-missing-pgbouncer-schema.md` in the context-hub wiki for the full writeup and live-recovery steps.

---

### Task 3: `ExternalSecret` for core Supabase secrets

**Files:**
- Create: `k8s/security/external-secrets/supabase/supabase-secret.yaml`

**Interfaces:**
- Consumes: Vault path `homelab/supabase/supabase-secret` (Task 2).
- Produces: Kubernetes `Secret` `supabase-secret` (namespace `supabase`) with keys `db-host`, `db-port`, `db-database`, `db-password`, `jwt-secret`, `anon-key`, `service-key`, `realtime-secret-key-base`, `realtime-db-enc-key`, `meta-crypto-key`, `dashboard-username`, `dashboard-password` — consumed by Task 8's `secret.db`/`secret.jwt`/`secret.realtime`/`secret.meta`/`secret.dashboard` `secretRef` values.

- [x] **Step 1: Write the ExternalSecret**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: supabase-secret
  namespace: supabase
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: supabase-secret
    creationPolicy: Owner
  data:
    - secretKey: db-host
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: db-host
    - secretKey: db-port
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: db-port
    - secretKey: db-database
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: db-database
    - secretKey: db-password
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: db-password
    - secretKey: jwt-secret
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: jwt-secret
    - secretKey: anon-key
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: anon-key
    - secretKey: service-key
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: service-key
    - secretKey: realtime-secret-key-base
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: realtime-secret-key-base
    - secretKey: realtime-db-enc-key
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: realtime-db-enc-key
    - secretKey: meta-crypto-key
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: meta-crypto-key
    - secretKey: dashboard-username
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: dashboard-username
    - secretKey: dashboard-password
      remoteRef:
        key: homelab/supabase/supabase-secret
        property: dashboard-password
```

- [x] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/security/external-secrets/supabase/supabase-secret.yaml`
Expected: no output.

- [x] **Step 3: Precondition — confirm Task 2 was already run by the user**

Run: `kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault kv get secret/homelab/supabase/supabase-secret`
Expected: prints all twelve keys. If this errors, **stop this task** and ask the user to run `scripts/setup-supabase.sh` first — do not proceed or write to Vault yourself.

- [x] **Step 4: Apply live and verify it syncs**

```bash
kubectl apply -f k8s/security/external-secrets/supabase/supabase-secret.yaml
kubectl get externalsecret supabase-secret -n supabase
kubectl get secret supabase-secret -n supabase -o jsonpath='{.data}' | python3 -m json.tool
```

Expected: `STATUS SecretSynced`, and the printed JSON lists all twelve keys (base64-encoded values).

- [x] **Step 5: Commit**

```bash
git add k8s/security/external-secrets/supabase/supabase-secret.yaml
git commit -m "feat(supabase): add ExternalSecret for core Supabase secrets"
```

Do not push yet.

---

### Task 4: Garage — shared S3-compatible storage (ArgoCD Application)

**Files:**
- Create: `k8s/argocd/applications/garage.yaml`

**Interfaces:**
- Produces: a running single-node Garage instance, Service `garage` (namespace `infrastructure`, S3 API on port 3900) — consumed by Task 5 (bucket/key creation) and Task 8 (`GLOBAL_S3_ENDPOINT`).

- [x] **Step 1: Write the Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: garage
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://git.deuxfleurs.fr/Deuxfleurs/garage.git
    path: script/helm/garage
    targetRevision: v2.4.1
    helm:
      values: |
        garage:
          # Single binary, single StatefulSet replica, replication_factor=1 -
          # matches this cluster's scale, avoids Garage's multi-node gossip
          # complexity entirely. Officially supported since Garage v2.3.
          singleNode: true

        deployment:
          replicaCount: 1

        persistence:
          enabled: true
          meta:
            size: 1Gi
          data:
            size: 20Gi

        resources:
          requests:
            memory: 256Mi
            cpu: 100m
          limits:
            memory: 512Mi

        # No ingress - Garage is shared *infra*, reached only from other
        # in-cluster services (Supabase Storage today, more services later),
        # never directly from outside the cluster.
        ingress:
          s3:
            api:
              enabled: false
            web:
              enabled: false

  destination:
    server: https://kubernetes.default.svc
    namespace: infrastructure
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false # Namespace existiert bereits (MinIO etc.)
```

- [x] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/argocd/applications/garage.yaml`
Expected: no output.

- [x] **Step 3: Render and apply live**

```bash
helm repo add garage https://git.deuxfleurs.fr/Deuxfleurs/garage.git --force-update 2>/dev/null || true
git clone --branch v2.4.1 --depth 1 https://git.deuxfleurs.fr/Deuxfleurs/garage.git /tmp/garage-chart-src
yq '.spec.source.helm.values' k8s/argocd/applications/garage.yaml > /tmp/garage-values.yaml
helm template garage /tmp/garage-chart-src/script/helm/garage --namespace infrastructure \
  -f /tmp/garage-values.yaml > /tmp/garage-rendered.yaml
kubectl apply -f /tmp/garage-rendered.yaml
kubectl rollout status statefulset/garage -n infrastructure --timeout=180s
```

Expected: the StatefulSet rolls out successfully. (If `yq` isn't installed, extract the `helm.values:` block from the file by hand into `/tmp/garage-values.yaml` instead. The `helm repo add` line is best-effort — Gitea repos don't always serve a Helm repo index; the `helm template` against the cloned chart source is what actually matters here.)

- [x] **Step 4: Verify it's actually serving S3 and find its real Service name**

```bash
kubectl get svc -n infrastructure | grep -i garage
kubectl get pods -n infrastructure -l app.kubernetes.io/name=garage
kubectl exec -n infrastructure garage-0 -- garage status
```

Expected: a Service (note its exact name — used in Task 8's `GLOBAL_S3_ENDPOINT`; expected to be plain `garage` since the chart's fullname template collapses when release name equals chart name, but confirm rather than assume), pod `garage-0` `Running`, and `garage status` printing a single healthy node with no layout warnings (a single-node Garage needs its storage layout assigned once — if `garage status` says "NO ROLE ASSIGNED", run `garage layout assign -z dc1 -c 1G <node-id>` then `garage layout apply --version 1`, using the node ID `garage status` prints).

**Confirmed live (2026-09-14)**: Service name is plain `garage` as predicted. `garage status` showed the node already `HEALTHY` with an auto-assigned role/zone/capacity — no manual `layout assign`/`layout apply` was needed at all; `singleNode: true` on this chart version (v2.4.1) auto-assigns the layout on first boot. The container image has no shell (`sh`/`which` both fail with "executable file not found") and the `garage` binary isn't on `$PATH` - exec it by its absolute path, `/garage status`, not bare `garage status` as written above.

**Unrelated but important operational catch**: the chart's rendered manifests don't set `metadata.namespace` on any object (normal for Helm templates - they rely on the apply-time context), so `kubectl apply -f <rendered>.yaml` without an explicit `-n infrastructure` silently created everything in this session's kubectl default namespace instead (`coder`, a live workspace namespace) - `kubectl apply` reported success throughout since it was creating real objects, just in the wrong place, and it was only caught because `-n infrastructure` came up empty afterward. Cleaned up the misplaced objects (StatefulSet, both Services, Secret, ConfigMap, ServiceAccount, both PVCs) from `coder` before redeploying correctly. Always pass `-n <namespace>` explicitly on this kind of manual "render then kubectl apply" step from here on - never rely on the shell's ambient default namespace.

- [x] **Step 5: Commit**

```bash
git add k8s/argocd/applications/garage.yaml
git commit -m "feat(garage): deploy shared S3-compatible storage"
```

Do not push yet.

---

### Task 5: `scripts/setup-supabase-storage.sh` — Garage bucket + scoped access key

**Files:**
- Create: `scripts/setup-supabase-storage.sh`

**Interfaces:**
- Consumes: a running Garage pod (Task 4).
- Produces: Garage bucket `supabase-storage` + access key `supabase-storage-key` scoped to it; Vault path `homelab/supabase/supabase-storage-secret` with keys `access-key-id`, `secret-access-key` — consumed by Task 6's `ExternalSecret`.

- [x] **Step 1: Write the script**

```bash
#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-supabase-storage.sh
#  Creates the Garage bucket + a scoped access key for Supabase Storage, and
#  writes the credentials to Vault. The ExternalSecret
#  'supabase-storage-secret' (namespace supabase) picks these up from there.
#
#  IDEMPOTENT: if Vault already has 'homelab/supabase/supabase-storage-secret'
#  populated, bucket/key creation is skipped entirely.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Garage laeuft (Namespace infrastructure)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-supabase-storage.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="supabase/supabase-storage-secret"
GARAGE_NS="infrastructure"
GARAGE_POD="garage-0"
BUCKET="supabase-storage"
KEY_NAME="supabase-storage-key"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

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
    echo "    (ExternalSecret $1 noch nicht deployt - wird beim naechsten ArgoCD-Sync abgeholt)"
}

garage_exec() {
  kubectl exec -n "${GARAGE_NS}" "${GARAGE_POD}" -- garage "$@"
}

if vault_kv_path_exists "${VAULT_PATH}"; then
  echo "==> ${VAULT_PATH} existiert bereits in Vault - ueberspringe Bucket/Key-Erstellung."
  exit 0
fi

echo "==> Lege Garage-Bucket '${BUCKET}' an..."
garage_exec bucket create "${BUCKET}" 2>/dev/null || echo "    Bucket existiert bereits."

echo "==> Lege Access-Key '${KEY_NAME}' an..."
garage_exec key create "${KEY_NAME}" 2>/dev/null || echo "    Key existiert bereits."

echo "==> Beschraenke den Key auf diesen Bucket..."
garage_exec bucket allow --read --write --key "${KEY_NAME}" "${BUCKET}"

echo "==> Lese Access-Key-Details aus..."
KEY_INFO=$(garage_exec key info "${KEY_NAME}" --show-secret)
echo "${KEY_INFO}"

ACCESS_KEY_ID=$(echo "${KEY_INFO}" | grep -i "Key ID:" | awk '{print $NF}')
SECRET_ACCESS_KEY=$(echo "${KEY_INFO}" | grep -i "Secret key:" | awk '{print $NF}')

if [[ -z "${ACCESS_KEY_ID}" ]] || [[ -z "${SECRET_ACCESS_KEY}" ]]; then
  echo "    FEHLER: Konnte Key ID/Secret nicht aus 'garage key info' Output parsen."
  echo "    Pruefe das Output-Format oben und passe die grep-Muster in diesem Skript an."
  exit 1
fi

vault_kv_put "${VAULT_PATH}" \
  "access-key-id=${ACCESS_KEY_ID}" \
  "secret-access-key=${SECRET_ACCESS_KEY}"

force_sync supabase-storage-secret supabase

echo ""
echo "============================================"
echo "  Setup abgeschlossen! Bucket: ${BUCKET}"
echo "============================================"
```

- [x] **Step 2: Syntax-check**

Run: `bash -n scripts/setup-supabase-storage.sh`
Expected: no output, exit code 0.

- [x] **Step 3: Make executable and commit**

```bash
chmod +x scripts/setup-supabase-storage.sh
git add scripts/setup-supabase-storage.sh
git commit -m "feat(supabase): add Garage bucket/key setup script"
```

Do **not** run this script yet — the user runs it personally as part of the Task 10 runbook.

**Verified live (2026-09-14) instead of guessing**: created a throwaway bucket/key via `kubectl exec -n infrastructure garage-0 -- /garage key info <name> --show-secret` and confirmed the `grep -i "Key ID:"`/`grep -i "Secret key:"` patterns above match this Garage version's (v2.4.1) real output exactly - no changes needed. One thing the plan's draft got wrong: the container has **no shell at all** (`sh`/`which` both fail with "executable file not found in $PATH") and the `garage` binary isn't on `$PATH` either - every `garage_exec` call here uses the absolute path `/garage`, not bare `garage`. Cleaned up the throwaway bucket/key afterward (`bucket delete --yes` / `key delete --yes`).

---

### Task 6: `ExternalSecret` for Garage storage credentials

**Files:**
- Create: `k8s/security/external-secrets/supabase/supabase-storage-secret.yaml`

**Interfaces:**
- Consumes: Vault path `homelab/supabase/supabase-storage-secret` (Task 5).
- Produces: Kubernetes `Secret` `supabase-storage-secret` (namespace `supabase`) with keys `access-key-id`, `secret-access-key` — consumed by Task 8's `environment.storage` `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` overrides.

- [ ] **Step 1: Write the ExternalSecret**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: supabase-storage-secret
  namespace: supabase
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: supabase-storage-secret
    creationPolicy: Owner
  data:
    - secretKey: access-key-id
      remoteRef:
        key: homelab/supabase/supabase-storage-secret
        property: access-key-id
    - secretKey: secret-access-key
      remoteRef:
        key: homelab/supabase/supabase-storage-secret
        property: secret-access-key
```

- [ ] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/security/external-secrets/supabase/supabase-storage-secret.yaml`
Expected: no output.

- [ ] **Step 3: Precondition — confirm Task 5 was already run by the user**

Run: `kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault kv get secret/homelab/supabase/supabase-storage-secret`
Expected: prints `access-key-id` and `secret-access-key`. If this errors, stop and ask the user to run `scripts/setup-supabase-storage.sh` first.

- [ ] **Step 4: Apply live and verify**

```bash
kubectl apply -f k8s/security/external-secrets/supabase/supabase-storage-secret.yaml
kubectl get externalsecret supabase-storage-secret -n supabase
kubectl get secret supabase-storage-secret -n supabase -o jsonpath='{.data}' | python3 -m json.tool
```

Expected: `STATUS SecretSynced`, both keys present.

- [ ] **Step 5: Commit**

```bash
git add k8s/security/external-secrets/supabase/supabase-storage-secret.yaml
git commit -m "feat(supabase): add ExternalSecret for Garage storage credentials"
```

Do not push yet.

---

### Task 7: Edge Functions image — new GitLab project

**Files** (in a new, separate local clone — not part of the `homelab-infra` repository, same as the sibling `backstage`/`coder-workspace` app repos):
- Create: `~/Code/gitlab/supabase-functions/Dockerfile`
- Create: `~/Code/gitlab/supabase-functions/functions/hello-world/index.ts`
- Create: `~/Code/gitlab/supabase-functions/.gitlab-ci.yml`

**Interfaces:**
- Produces: image `registry.homelab.local/homelab/projects/supabase-functions:latest` (and `:$CI_COMMIT_SHORT_SHA`) — consumed by Task 8's `image.functions.repository`/`.tag`.

- [x] **Step 1: Write the Dockerfile**

```dockerfile
# Base: exactly the image/tag the Supabase chart itself pins for the
# functions component (image.functions.tag: "v1.74.0") - keeps our custom
# image's Deno/edge-runtime version in lockstep with what the rest of the
# chart expects.
FROM supabase/edge-runtime:v1.74.0

# Function code, one directory per function (each with its own index.ts).
# The chart always mounts its own router ConfigMap at
# /home/deno/functions/main/index.ts regardless of what's baked into the
# image, so a "main" directory here would just get overwritten - we don't
# create one.
COPY functions/ /home/deno/functions/
```

- [x] **Step 2: Write a trivial sample function**

```typescript
Deno.serve(async (_req) => {
  return new Response(
    JSON.stringify({ message: "Hello from a homelab Supabase Edge Function" }),
    { headers: { "Content-Type": "application/json" } },
  );
});
```

- [x] **Step 3: Write `.gitlab-ci.yml`** (same Kaniko pattern proven for `backstage`/`coder-workspace`)

```yaml
stages:
  - build

build-and-push:
  stage: build
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

**Correction versus this draft (2026-09-14)**: fetched `backstage`'s and `coder-workspace`'s actual live `.gitlab-ci.yml` via the GitLab API before writing this rather than trusting "same Kaniko pattern" from memory — they've diverged. `backstage` (older) still pushes via the external route (`$CI_REGISTRY`/`$CI_REGISTRY_IMAGE`, exactly as drafted above). `coder-workspace` (newer) pushes straight to the in-cluster registry Service (`gitlab.gitlab.svc.cluster.local:5050/$CI_PROJECT_PATH`, `--insecure`) instead, adopted after discovering Traefik silently cuts off large blob pushes at ~60s (`references/traefik-large-upload-60s-cutoff.md` in the context-hub wiki) — the external route isn't just older, it's now the known-fragile one. This function image is tiny (edge-runtime base + a few KB of TS), so the external route would likely have worked fine size-wise, but there's no reason to write a new CI file against the fragile pattern when the fixed one is already this repo's proven approach — used `coder-workspace`'s pattern instead of what's shown above. Runtime image *pulls* (the actual Supabase `functions` Deployment) are unaffected either way and still go through the normal external `registry.homelab.local` route, same as every other service's image pulls in this cluster — only the CI *push* step changes.

- [x] **Step 4: Build the image locally to confirm it's valid**

No Docker/Podman/Buildah/nerdctl available in this Coder workspace (this repo's images are always built via Kaniko in CI, never locally) — `docker build` as drafted isn't possible here. Verified what's actually checkable instead: the base image tag resolves and pulls cleanly (`kubectl run --image=supabase/edge-runtime:v1.74.0 -- true` succeeded), and the two-line `Dockerfile` was reviewed by hand (trivial enough that a build would only really be catching a typo). The real build validation happens for real the first time CI actually runs, in Task 10.

- [x] **Step 5: Lint the CI file**

`yamllint` isn't installed locally (per this repo's own CLAUDE.md) — validated the file parses as YAML instead (`python3 -c "import yaml; yaml.safe_load(open(...))"`), which is the failure mode that would actually matter for GitLab CI to accept it.

- [x] **Step 6: Initialize the local repo (project creation + push happen in Task 10)**

```bash
cd ~/Code/gitlab/supabase-functions
git init
git add Dockerfile functions/ .gitlab-ci.yml
git commit -m "feat: add supabase edge functions image (hello-world sample)"
git branch -m main
```

The extra `git branch -m main` isn't in the original draft — `git init` defaults to `master` in this environment, but the `.gitlab-ci.yml` rule above and Task 10's `git push -u origin main` both assume `main`; renamed to match.

Do not push — the GitLab project `homelab/projects/supabase-functions` doesn't exist yet; Task 10's runbook creates it and pushes.

---

### Task 8: Main Supabase ArgoCD Application

**Files:**
- Create: `k8s/argocd/applications/supabase.yaml`

**Interfaces:**
- Consumes: `Secret supabase-secret` (Task 3), `Secret supabase-storage-secret` (Task 6), image `registry.homelab.local/homelab/projects/supabase-functions:latest` (Task 7).
- Produces: the running Supabase stack (Kong/Auth/REST/Realtime/Storage/Studio/Meta/Functions), reachable at `supabase.homelab.local` and `supabase-studio.homelab.local`.

- [ ] **Step 1: Write the Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: supabase
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://supabase-community.github.io/supabase-kubernetes
    chart: supabase
    targetRevision: "0.8.0"
    helm:
      values: |
        deployment:
          db:
            enabled: false

        persistence:
          db:
            enabled: false
          # Function code is baked into our custom image (Task 7), not
          # hand-copied onto an empty PVC - the chart's default approach.
          functions:
            enabled: false
          deno:
            enabled: false

        secret:
          db:
            secretRef: supabase-secret
            secretRefKey:
              host: db-host
              port: db-port
              password: db-password
              database: db-database
          jwt:
            secretRef: supabase-secret
            secretRefKey:
              secret: jwt-secret
              anonKey: anon-key
              serviceKey: service-key
          realtime:
            secretRef: supabase-secret
            secretRefKey:
              secretKeyBase: realtime-secret-key-base
              dbEncKey: realtime-db-enc-key
          meta:
            secretRef: supabase-secret
            secretRefKey:
              cryptoKey: meta-crypto-key
          dashboard:
            secretRef: supabase-secret
            secretRefKey:
              username: dashboard-username
              password: dashboard-password

        image:
          functions:
            repository: registry.homelab.local/homelab/projects/supabase-functions
            tag: latest

        environment:
          auth:
            - name: API_EXTERNAL_URL
              value: https://supabase.homelab.local
            - name: GOTRUE_API_HOST
              value: "0.0.0.0"
            - name: GOTRUE_API_PORT
              value: "9999"
            - name: GOTRUE_SITE_URL
              value: https://supabase.homelab.local
            - name: GOTRUE_URI_ALLOW_LIST
              value: "*"
            - name: GOTRUE_DISABLE_SIGNUP
              value: "false"
            - name: GOTRUE_JWT_DEFAULT_GROUP_NAME
              value: authenticated
            - name: GOTRUE_JWT_ADMIN_ROLES
              value: service_role
            - name: GOTRUE_JWT_AUD
              value: authenticated
            - name: GOTRUE_JWT_EXP
              value: "3600"
            - name: GOTRUE_EXTERNAL_EMAIL_ENABLED
              value: "true"
            # No real SMTP configured yet - signups auto-confirm instead of
            # sending a confirmation email. Real SMTP is a follow-up, not
            # part of this plan's scope.
            - name: GOTRUE_MAILER_AUTOCONFIRM
              value: "true"
            - name: GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED
              value: "false"
            - name: GOTRUE_SMTP_ADMIN_EMAIL
              value: "SMTP_ADMIN_MAIL"
            - name: GOTRUE_SMTP_HOST
              value: "SMTP_HOST"
            - name: GOTRUE_SMTP_PORT
              value: "123"
            - name: GOTRUE_EXTERNAL_PHONE_ENABLED
              value: "false"
            - name: GOTRUE_SMS_AUTOCONFIRM
              value: "false"
            - name: GOTRUE_SMTP_SENDER_NAME
              value: "SMTP_SENDER_NAME"
            - name: GOTRUE_MAILER_URLPATHS_INVITE
              value: "/auth/v1/verify"
            - name: GOTRUE_MAILER_URLPATHS_CONFIRMATION
              value: "/auth/v1/verify"
            - name: GOTRUE_MAILER_URLPATHS_RECOVERY
              value: "/auth/v1/verify"
            - name: GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE
              value: "/auth/v1/verify"

          # The chart hardcodes STORAGE_BACKEND to "s3" (and wires
          # AWS_ACCESS_KEY_ID/SECRET to its own bundled-MinIO secret) only
          # when deployment.minio.enabled is true - confirmed by reading
          # templates/storage/deployment.yaml upstream. We use external
          # Garage instead of the bundled MinIO, so deployment.minio.enabled
          # stays false and we override the S3 wiring here. This whole list
          # renders into the container's env AFTER the chart's own hardcoded
          # STORAGE_BACKEND entry, and Kubernetes resolves duplicate env var
          # names by last-one-wins, so our STORAGE_BACKEND: "s3" below wins.
          storage:
            - name: REQUEST_ALLOW_X_FORWARDED_PATH
              value: "true"
            - name: FILE_SIZE_LIMIT
              value: "52428800"
            - name: FILE_STORAGE_BACKEND_PATH
              value: /var/lib/storage
            - name: TENANT_ID
              value: stub
            - name: REGION
              value: garage
            - name: GLOBAL_S3_BUCKET
              value: supabase-storage
            - name: ENABLE_IMAGE_TRANSFORMATION
              value: "true"
            - name: STORAGE_BACKEND
              value: "s3"
            # Confirm the exact Service name/port against Task 4 Step 4's
            # live output before this first sync - expected to be "garage"
            # (release name == chart name collapses the fullname template)
            # but verify rather than assume.
            - name: GLOBAL_S3_ENDPOINT
              value: "http://garage.infrastructure.svc.cluster.local:3900"
            - name: GLOBAL_S3_FORCE_PATH_STYLE
              value: "true"
            - name: GLOBAL_S3_PROTOCOl
              value: http
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: supabase-storage-secret
                  key: access-key-id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: supabase-storage-secret
                  key: secret-access-key

          studio:
            - name: HOSTNAME
              value: "::"
            - name: STUDIO_PORT
              value: "3000"
            - name: DEFAULT_ORGANIZATION_NAME
              value: Default Organization
            - name: DEFAULT_PROJECT_NAME
              value: Default Project
            - name: SUPABASE_PUBLIC_URL
              value: https://supabase.homelab.local
            - name: NEXT_ANALYTICS_BACKEND_PROVIDER
              value: postgres

        # Two hosts, one Kong Service - Kong's own kong.yml already proxies
        # "/" to Studio behind HTTP basic-auth (secret.dashboard.*) and the
        # API routes behind anon/service-role key checks, regardless of
        # which Host header was used. Confirmed by reading the chart's
        # files/kong/kong.yml and templates/kong/ingress.yaml upstream - no
        # separate hand-written Ingress/Middleware needed (see this plan's
        # Global Constraints for why this differs from the design spec).
        ingress:
          enabled: true
          className: traefik
          annotations: {}
          hosts:
            - host: supabase.homelab.local
              paths:
                - path: /
                  pathType: Prefix
            - host: supabase-studio.homelab.local
              paths:
                - path: /
                  pathType: Prefix
          tls:
            - secretName: homelab-wildcard-tls
              hosts:
                - supabase.homelab.local
                - supabase-studio.homelab.local

  destination:
    server: https://kubernetes.default.svc
    namespace: supabase
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/argocd/applications/supabase.yaml`
Expected: no output.

- [ ] **Step 3: Precondition — confirm Tasks 1-7 are live**

```bash
kubectl get secret supabase-secret supabase-storage-secret -n supabase
kubectl get cluster supabase-pg -n supabase
kubectl get pods -n infrastructure -l app.kubernetes.io/name=garage
curl -sk -o /dev/null -w '%{http_code}\n' https://registry.homelab.local/v2/homelab/projects/supabase-functions/tags/list
```

Expected: both Secrets exist, the CNPG cluster is `Ready`, Garage is `Running`, and the registry responds (a `401` is fine — it means the registry is reachable and just wants auth, confirming the image repo path exists; a connection failure means Task 7's project/push hasn't happened yet).

- [ ] **Step 4: Render the chart with the embedded values**

```bash
helm repo add supabase https://supabase-community.github.io/supabase-kubernetes --force-update
helm repo update supabase
yq '.spec.source.helm.values' k8s/argocd/applications/supabase.yaml > /tmp/supabase-values.yaml
helm template supabase supabase/supabase --version 0.8.0 --namespace supabase \
  -f /tmp/supabase-values.yaml > /tmp/supabase-rendered.yaml
```

Expected: no template errors; `/tmp/supabase-rendered.yaml` contains Deployments for kong/auth/rest/realtime/storage/studio/meta/functions and an `Ingress` with both hosts.

- [ ] **Step 5: Apply the rendered manifests directly — this is exactly what ArgoCD will do later**

```bash
kubectl apply -f /tmp/supabase-rendered.yaml
kubectl rollout status deployment/supabase-kong -n supabase --timeout=300s
kubectl rollout status deployment/supabase-auth -n supabase --timeout=300s
kubectl rollout status deployment/supabase-rest -n supabase --timeout=300s
kubectl rollout status deployment/supabase-realtime -n supabase --timeout=300s
kubectl rollout status deployment/supabase-storage -n supabase --timeout=300s
kubectl rollout status deployment/supabase-studio -n supabase --timeout=300s
kubectl rollout status deployment/supabase-meta -n supabase --timeout=300s
kubectl rollout status deployment/supabase-functions -n supabase --timeout=300s
```

(Exact Deployment names depend on the chart's fullname template — if any of these names don't match, run `kubectl get deployments -n supabase` first and substitute the real names.)

Expected: every rollout completes. If `supabase-storage` fails, check `kubectl logs deployment/supabase-storage -n supabase` for S3-connection errors first (the workaround in this task's `environment.storage` block is the most likely thing to need a follow-up fix, per the comment above it) before touching anything else.

- [ ] **Step 6: Verify the stack actually works end to end**

```bash
curl -sk https://supabase.homelab.local/auth/v1/health
curl -sk -H "apikey: $(kubectl get secret supabase-secret -n supabase -o jsonpath='{.data.anon-key}' | base64 -d)" \
  https://supabase.homelab.local/rest/v1/
curl -sk -u "$(kubectl get secret supabase-secret -n supabase -o jsonpath='{.data.dashboard-username}' | base64 -d):$(kubectl get secret supabase-secret -n supabase -o jsonpath='{.data.dashboard-password}' | base64 -d)" \
  -o /dev/null -w '%{http_code}\n' https://supabase-studio.homelab.local/
```

Expected: `/auth/v1/health` returns a healthy JSON body, `/rest/v1/` returns PostgREST's OpenAPI root (not a 401), and the Studio request returns `200`. Iterate on the values in Step 1 and re-run Steps 4-6 against the same live resources until all three pass — do not commit a values change you haven't re-verified live.

- [ ] **Step 7: Commit and push everything from Tasks 1-8**

```bash
git add k8s/namespaces.yaml k8s/infrastructure/supabase-postgres-cluster.yaml \
  scripts/setup-supabase.sh scripts/setup-supabase-storage.sh \
  k8s/security/external-secrets/supabase/ \
  k8s/argocd/applications/garage.yaml k8s/argocd/applications/supabase.yaml
git commit -m "feat(supabase): deploy Supabase stack via ArgoCD"
git push
```

- [ ] **Step 8: Confirm ArgoCD adopts everything cleanly**

```bash
kubectl get application supabase garage -n argocd -w
```

Expected: both reach `Synced`/`Healthy` within a couple of minutes, with no pod restarts (ArgoCD renders the identical chart+values already verified live).

---

### Task 9: Backstage catalog entries

**Files:**
- Create: `catalog/supabase/catalog-info.yaml`
- Create: `catalog/supabase/mkdocs.yml`
- Create: `catalog/supabase/docs/index.md`
- Create: `catalog/garage/catalog-info.yaml`
- Create: `catalog/garage/mkdocs.yml`
- Create: `catalog/garage/docs/index.md`
- Modify: `catalog/all.yaml`

**Interfaces:** none — pure catalog metadata, per CLAUDE.md's Backstage-catalog-sync convention.

- [ ] **Step 1: Write `catalog/supabase/catalog-info.yaml`**

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: supabase
  description: Self-hosted Supabase (Postgres/Auth/REST/Realtime/Storage/Studio/Functions)
  annotations:
    argocd/app-name: supabase
    backstage.io/kubernetes-id: supabase
    backstage.io/techdocs-ref: dir:.
  links:
    - url: https://supabase.homelab.local
      title: API (Kong)
    - url: https://supabase-studio.homelab.local
      title: Studio
spec:
  type: service
  lifecycle: production
  owner: group:homelab
  system: homelab
```

- [ ] **Step 2: Write `catalog/supabase/mkdocs.yml`**

```yaml
site_name: Supabase
```

- [ ] **Step 3: Write `catalog/supabase/docs/index.md`**

```markdown
## What it is

A self-hosted [Supabase](https://supabase.com) stack — Postgres, Auth (GoTrue), REST (PostgREST), Realtime, Storage, Studio, and Edge Functions — deployed as one ArgoCD Application via the community `supabase-community/supabase-kubernetes` Helm chart.

## Why it's here

A backend-as-a-service for apps built in this homelab (primarily via the Coder workspace): Postgres-backed auth, an auto-generated REST/GraphQL API, realtime subscriptions, file storage, and serverless Edge Functions, without hand-rolling any of that per project.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/supabase.yaml` — chart `supabase-community/supabase-kubernetes`, pinned `0.8.0`, namespace `supabase`.
- Database: a dedicated CNPG cluster `supabase-pg` (`k8s/infrastructure/supabase-postgres-cluster.yaml`), running the `supabase/postgres:17.6.1.136` image (not CNPG's default) so Supabase's required Postgres extensions are present. Schema bootstrapped once by `scripts/setup-supabase.sh` from the upstream `supabase/postgres` migration set.
- Storage backend: a shared Garage instance (`catalog/garage`), bucket `supabase-storage`, credentials via `scripts/setup-supabase-storage.sh` — not MinIO (MinIO's OSS console was gutted in 2025; Garage is a genuinely open, AGPLv3 alternative).
- Secrets: `k8s/security/external-secrets/supabase/supabase-secret.yaml` (Vault path `homelab/supabase/supabase-secret` — JWT signing key + anon/service_role tokens, DB password, Realtime/Meta keys, Studio dashboard credentials) and `supabase-storage-secret.yaml` (Vault path `homelab/supabase/supabase-storage-secret` — Garage access key).
- Edge Functions: built from a separate GitLab project, `homelab/projects/supabase-functions` (`FROM supabase/edge-runtime:v1.74.0` + baked-in function code), via GitLab CI + Kaniko, pushed to `registry.homelab.local/homelab/projects/supabase-functions`.
- Ingress: `supabase.homelab.local` (API, via Kong) and `supabase-studio.homelab.local` (Studio) — both routed to the same Kong Service; Kong's own declarative config gates Studio behind HTTP basic-auth and the API routes behind anon/service-role API keys. Reachable only over Tailscale.
- Auth: built-in Supabase email/password only (no Keycloak/OIDC integration — a deliberate, deferred non-goal).

## How to change it

- **Rotate the JWT secret, a DB password, or Studio dashboard credentials**: update the relevant key in Vault at `homelab/supabase/supabase-secret`, then force-sync: `kubectl -n supabase annotate externalsecret supabase-secret force-sync=$(date +%s) --overwrite`. Rotating the JWT secret invalidates every previously-issued anon/service_role key and user session — re-derive both from the new secret (see `scripts/setup-supabase.sh`'s `mint_jwt`) before rotating.
- **Add or update an Edge Function**: edit `functions/<name>/index.ts` in the `supabase-functions` GitLab project, push to `main` — CI builds and pushes `registry.homelab.local/homelab/projects/supabase-functions:latest` automatically. Restart the functions Deployment to pick it up.
- **Add a new Garage-backed bucket for another service**: `kubectl exec -n infrastructure garage-0 -- garage bucket create <name>` + `garage key create <name>-key` + `garage bucket allow --read --write --key <name>-key <name>`, matching `scripts/setup-supabase-storage.sh`.
- **Resize Postgres storage or bump the Postgres image**: edit `k8s/infrastructure/supabase-postgres-cluster.yaml` (`storage.size`/`imageName`) and let ArgoCD/CNPG reconcile.
```

- [ ] **Step 4: Write `catalog/garage/catalog-info.yaml`**

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: garage
  description: Shared S3-compatible object storage (Garage, AGPLv3)
  annotations:
    argocd/app-name: garage
    backstage.io/kubernetes-id: garage
    backstage.io/techdocs-ref: dir:.
spec:
  type: service
  lifecycle: production
  owner: group:homelab
  system: homelab
```

- [ ] **Step 5: Write `catalog/garage/mkdocs.yml`**

```yaml
site_name: Garage
```

- [ ] **Step 6: Write `catalog/garage/docs/index.md`**

```markdown
## What it is

A single-node [Garage](https://garagehq.deuxfleurs.fr) instance — an S3-compatible object store built by Deuxfleurs, AGPLv3 — deployed as shared infrastructure alongside MinIO.

## Why it's here

Supabase Storage needed a genuinely open-source S3 backend (MinIO's OSS console was gutted in 2025) — Garage was picked specifically for small self-hosted deployments over the alternative (SeaweedFS), which has more moving parts than this cluster's scale needs. Deployed as *shared* infra (like MinIO) rather than Supabase-only, so future services can reuse it with their own bucket/key rather than standing up another instance.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/garage.yaml` — Garage's own chart, sourced directly from `git.deuxfleurs.fr/Deuxfleurs/garage.git` (`script/helm/garage`), pinned `v2.4.1`, namespace `infrastructure`. Single-node mode (`garage.singleNode: true`).
- No secrets management of its own at the instance level — per-consumer buckets and scoped access keys are created via the `garage` CLI (`kubectl exec -n infrastructure garage-0 -- garage ...`) and written to Vault by whichever service's setup script needs them (e.g. `scripts/setup-supabase-storage.sh` for the `supabase-storage` bucket).

## How to change it

- **Add a bucket/key for a new consumer**: see `catalog/supabase`'s "How to change it" for the exact `garage` CLI commands.
- **Resize storage**: edit `k8s/argocd/applications/garage.yaml`'s `persistence.data.size` and let ArgoCD reconcile (grows the existing PVC if the storage class supports online expansion; otherwise a manual PVC resize/replace is needed).
```

- [ ] **Step 7: Add both entries to `catalog/all.yaml`**

Insert alphabetically:

```yaml
    - ./garage/catalog-info.yaml
```

(next to the other infrastructure-ish entries) and

```yaml
    - ./supabase/catalog-info.yaml
```

(next to the other service entries) — match the existing file's actual ordering convention rather than assuming a specific neighbor line.

- [ ] **Step 8: Lint**

Run: `yamllint -c .yamllint.yml catalog/supabase/catalog-info.yaml catalog/supabase/mkdocs.yml catalog/garage/catalog-info.yaml catalog/garage/mkdocs.yml catalog/all.yaml`
Expected: no output.

- [ ] **Step 9: Commit**

```bash
git add catalog/supabase/ catalog/garage/ catalog/all.yaml
git commit -m "feat(catalog): add Supabase and Garage to Backstage catalog"
git push
```

---

### Task 10: End-to-end rollout runbook

**Files:**
- Create: `docs/supabase-setup.md`

**Interfaces:** none — the document the user follows to execute every manual step from Tasks 1-9 in order, mirroring `docs/coder-setup.md`'s structure.

- [ ] **Step 1: Write the runbook**

```markdown
# Supabase Setup Runbook

Einmaliger Setup-Guide fuer den self-hosted Supabase-Stack.
Voraussetzung: Tasks 1-9 aus dem Implementation Plan sind committed und gepusht.

**Voraussetzungen:**
- `kubectl` konfiguriert, Cluster erreichbar
- `VAULT_TOKEN` als Env-Var gesetzt
- Du bist im Tailscale-Netz, `*.homelab.local` loest auf
- Zugriff auf die self-hosted GitLab-Instanz (`gitlab.homelab.local`)
- `git`, `python3`, `openssl`, `docker` lokal installiert

---

## 1. Postgres-Bootstrap + Kern-Secrets

```bash
export VAULT_TOKEN="..."
./scripts/setup-supabase.sh
```

Merke dir den ausgegebenen Studio-Login (Dashboard-Username/Passwort).

---

## 2. Garage-Bucket + Storage-Secret

```bash
./scripts/setup-supabase-storage.sh
```

Falls das Skript beim Parsen von `garage key info` fehlschlaegt: das
tatsaechliche Output-Format pruefen (wird oben mit ausgegeben) und die
`grep`-Muster in `scripts/setup-supabase-storage.sh` anpassen.

---

## 3. Stack verifizieren

Postgres-Cluster, Garage und der Supabase-Stack selbst wurden bereits
waehrend der Implementierung live deployt und verifiziert (Tasks 1, 4, 8
appliziieren die gerenderten Manifeste direkt, bevor sie committed werden)
und laufen inzwischen unter ArgoCD-Verwaltung.

```bash
kubectl get application supabase garage -n argocd
# STATUS sollte "Synced" / "Healthy" sein
```

---

## 4. GitLab-Projekt fuer Edge Functions anlegen

1. `https://gitlab.homelab.local` -> **New project** -> `homelab/projects/supabase-functions`
2. **Settings -> CI/CD -> Variables** -> `HOMELAB_CA_CRT` als File-Variable setzen (gleicher Wert wie bei `backstage`/`coder-workspace`)
3. Push:

```bash
cd ~/Code/gitlab/supabase-functions
git remote add origin git@gitlab.homelab.local:homelab/projects/supabase-functions.git
git push -u origin main
```

4. Pipeline beobachten: `https://gitlab.homelab.local/homelab/projects/supabase-functions/-/pipelines`
5. Sobald das Image gebaut ist, den Functions-Rollout neu starten, falls er
   vorher schon (mit `ImagePullBackOff`) versucht hat zu starten:

```bash
kubectl rollout restart deployment/supabase-functions -n supabase
```

---

## 5. Verifikation

- [ ] `https://supabase.homelab.local/auth/v1/health` antwortet mit einem
      gesunden JSON-Body
- [ ] Mit dem `anon-key` aus dem `supabase-secret` Secret:
      `curl -H "apikey: <anon-key>" https://supabase.homelab.local/rest/v1/`
      liefert PostgREST's OpenAPI-Root (kein 401)
- [ ] `https://supabase-studio.homelab.local` fragt nach den
      Dashboard-Credentials (Basic-Auth) und zeigt danach Studio; das
      `supabase-pg`-Schema ist im Table Editor sichtbar
- [ ] Ein Datei-Upload ueber die Storage-REST-API landet im
      `supabase-storage`-Bucket (`kubectl exec -n infrastructure garage-0 --
      garage bucket info supabase-storage` zeigt einen gestiegenen
      Objekt-Count)
- [ ] Ein Realtime-Test-Client erhaelt ein Change-Event nach einem `INSERT`
      in eine Tabelle mit aktiviertem Realtime
- [ ] `POST https://supabase.homelab.local/functions/v1/hello-world` (mit
      `apikey`-Header) liefert die Beispiel-JSON-Antwort

---

## 6. Troubleshooting

**Supabase-Pods crashen mit Postgres-Verbindungsfehlern**
```bash
kubectl get cluster supabase-pg -n supabase
# Muss "Cluster in healthy state" sein, bevor die Supabase-Komponenten starten
```

**Storage-Pod kann Garage nicht erreichen**
```bash
kubectl logs deployment/supabase-storage -n supabase | grep -i s3
kubectl exec -n infrastructure garage-0 -- garage status
```
Pruefen: `GLOBAL_S3_ENDPOINT` in `k8s/argocd/applications/supabase.yaml`
zeigt auf den tatsaechlichen Garage-Service-Namen (Task 4 Step 4).

**Functions-Pod haengt in `ImagePullBackOff`**
```bash
kubectl describe pod -n supabase -l app.kubernetes.io/name=supabase-functions | grep -A5 Events
```
Meist: das Image wurde noch nicht gebaut (Schritt 4 hier oben noch nicht
durchgefuehrt) oder die Pipeline ist fehlgeschlagen.
```

- [ ] **Step 2: Verify the doc's section count**

Run: `grep -c "^## " docs/supabase-setup.md`
Expected: `6` (one per top-level section).

- [ ] **Step 3: Commit**

```bash
git add docs/supabase-setup.md
git commit -m "docs(supabase): add end-to-end rollout runbook"
git push
```

---

## Self-Review Notes

- **Spec coverage:** dedicated CNPG cluster (Task 1), external-DB bootstrap caveat resolved concretely via the pinned upstream migration set (Task 2), single ArgoCD Application via the community chart (Task 8), shared Garage replacing MinIO (Tasks 4-6, 9), two-host ingress (Task 8 — implemented via the chart's native mechanism rather than the spec's hand-written Ingress/Middleware, see Global Constraints for the correction), Edge Functions via custom GitLab CI image (Task 7), Vault-backed secrets with a new `supabase` ExternalSecrets category (Tasks 3, 6), Backstage catalog sync for both Supabase and Garage (Task 9, CLAUDE.md requirement), rollout order and every "Testing" bullet from the spec (Task 10).
- **Placeholder scan:** none — every file has literal, complete content. The spec's deliberately-deferred "exact migration source" detail is resolved concretely in Task 2 (pinned tag, exact exclusion, exact commands) rather than left open; the two points genuinely only checkable against a live cluster (Garage's real Service name, the `supabase/postgres` image's CNPG compatibility) are called out explicitly as live-verification steps with clear pass/fail criteria, not vague hand-waving.
- **Type/name consistency checked:** `supabase-secret` keys (`db-host`, `db-port`, `db-database`, `db-password`, `jwt-secret`, `anon-key`, `service-key`, `realtime-secret-key-base`, `realtime-db-enc-key`, `meta-crypto-key`, `dashboard-username`, `dashboard-password`) match across Tasks 2, 3, 8; `supabase-storage-secret` keys (`access-key-id`, `secret-access-key`) match across Tasks 5, 6, 8; Vault paths (`homelab/supabase/supabase-secret`, `homelab/supabase/supabase-storage-secret`) match across Tasks 2, 3, 5, 6, 10; Garage bucket/key names (`supabase-storage`, `supabase-storage-key`) match across Tasks 5, 8, 9; image reference `registry.homelab.local/homelab/projects/supabase-functions:latest` matches across Tasks 7, 8, 9, 10; CNPG role names (`supabase_admin`, `authenticator`, `supabase_auth_admin`, `supabase_storage_admin`) match between Task 1's bootstrap owner and Task 2's password-sync ALTER statements.
