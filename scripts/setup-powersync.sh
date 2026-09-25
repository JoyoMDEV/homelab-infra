#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-powersync.sh
#  Sets powersync_role's password on supabase-pg (the role itself is
#  created by everything-app's supabase/migrations/0006_powersync_
#  replication.sql - run that first via the deploying-supabase-migrations
#  runbook), reads powersync-pg's CNPG-generated app credentials, and
#  writes both connection strings + the reused Supabase JWT secret to
#  Vault. The ExternalSecret 'powersync-secret' (namespace powersync)
#  picks these up from there.
#
#  IDEMPOTENT: reuses an already-generated password/URIs from Vault rather
#  than regenerating them, matching this repo's other setup-<service>.sh
#  scripts.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Cluster erreichbar
#  - supabase-pg-1 Running, powersync_role bereits angelegt (siehe oben)
#  - powersync-pg-1 Running (ArgoCD hat den 'powersync'-Namespace + die
#    powersync-pg-postgres-cluster.yaml bereits synced)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-powersync.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/powersync/powersync-secret"

SUPABASE_PG_NS="supabase"
SUPABASE_PG_POD="supabase-pg-1"

POWERSYNC_PG_NS="powersync"
POWERSYNC_PG_POD="powersync-pg-1"

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

echo "==> Warte bis supabase-pg und powersync-pg bereit sind..."
kubectl wait --for=condition=Ready pod/"${SUPABASE_PG_POD}" -n "${SUPABASE_PG_NS}" --timeout=120s
kubectl wait --for=condition=Ready pod/"${POWERSYNC_PG_POD}" -n "${POWERSYNC_PG_NS}" --timeout=120s

echo ""
echo "==> Setze powersync_role-Passwort auf supabase-pg..."
REPLICATION_PW=$(vault_kv_get "${VAULT_PATH}" "replication-password")
[[ -z "${REPLICATION_PW}" ]] && REPLICATION_PW=$(openssl rand -base64 32 | tr -d '\n')

kubectl exec "${SUPABASE_PG_POD}" -n "${SUPABASE_PG_NS}" -c postgres -- psql -U postgres -d postgres -c "
  ALTER ROLE powersync_role WITH PASSWORD '${REPLICATION_PW}';
" >/dev/null
echo "    powersync_role-Passwort gesetzt."

echo ""
echo "==> Lese powersync-pg's App-Credentials (CNPG-generiert)..."
STORAGE_USER=$(kubectl get secret powersync-pg-app -n "${POWERSYNC_PG_NS}" -o jsonpath='{.data.username}' | base64 -d)
STORAGE_PW=$(kubectl get secret powersync-pg-app -n "${POWERSYNC_PG_NS}" -o jsonpath='{.data.password}' | base64 -d)
STORAGE_DB=$(kubectl get secret powersync-pg-app -n "${POWERSYNC_PG_NS}" -o jsonpath='{.data.dbname}' | base64 -d)

DATA_SOURCE_URI="postgresql://powersync_role:${REPLICATION_PW}@supabase-pg-rw.supabase.svc.cluster.local:5432/postgres"
STORAGE_URI="postgresql://${STORAGE_USER}:${STORAGE_PW}@powersync-pg-rw.powersync.svc.cluster.local:5432/${STORAGE_DB}"

echo ""
echo "==> Schreibe Secrets nach Vault..."
vault_kv_put "${VAULT_PATH}" \
  "replication-password=${REPLICATION_PW}" \
  "data-source-uri=${DATA_SOURCE_URI}" \
  "storage-uri=${STORAGE_URI}"

force_sync powersync-secret powersync

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo "  PowerSync sollte jetzt an supabase-pg replizieren, sobald ArgoCD"
echo "  den powersync-Deployment synced hat."
echo "============================================"
