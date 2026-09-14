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
VAULT_PATH="homelab/supabase/supabase-storage-secret"
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
  # The garage binary is at an absolute path and isn't on $PATH - there's no
  # shell at all in this image (confirmed live: `sh`/`which` both fail with
  # "executable file not found"), so the container's own entrypoint invokes
  # it the same way.
  kubectl exec -n "${GARAGE_NS}" "${GARAGE_POD}" -- /garage "$@"
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
