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

  # The migrations set assumes a "pgbouncer" schema/role/get_auth() function
  # already exist (several migrations ALTER/GRANT objects inside it), but
  # that bootstrap SQL only ships in supabase/postgres's own AMI-provisioning
  # ansible role (ansible/files/pgbouncer_config/pgbouncer_auth_schema.sql),
  # never in the migrations/db/init-scripts this loop runs. Discovered live
  # (2026-09-14): 20250312095419_pgbouncer_ownership.sql is the first
  # migration to reference it and fails with "schema pgbouncer does not
  # exist" if this step is skipped. We don't run pgbouncer itself in this
  # deployment (no separate pgbouncer component in the Helm chart) - the
  # schema/function existing is still required for the migrations to apply
  # cleanly and matches upstream's real self-host schema exactly.
  echo "==> Bootstrappe pgbouncer-Schema (wird von mehreren Migrationen vorausgesetzt)..."
  kubectl exec -i "${POSTGRES_POD}" -n "${POSTGRES_NS}" -c postgres -- \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - <<'PGBOUNCER_SQL'
CREATE USER pgbouncer;

REVOKE ALL PRIVILEGES ON SCHEMA public FROM pgbouncer;

CREATE SCHEMA pgbouncer AUTHORIZATION pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename TEXT)
RETURNS TABLE(username TEXT, password TEXT) AS
$$
BEGIN
    RAISE WARNING 'PgBouncer auth request: %', p_usename;

    RETURN QUERY
    SELECT usename::TEXT, passwd::TEXT FROM pg_catalog.pg_shadow
    WHERE usename = p_usename;
END;
$$ LANGUAGE plpgsql
SET search_path = ''
SECURITY DEFINER;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(p_usename TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(p_usename TEXT) TO pgbouncer;
PGBOUNCER_SQL

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
