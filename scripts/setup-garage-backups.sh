#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-garage-backups.sh
#  Replaces setup-velero.sh / the MinIO backup target. Creates the Garage
#  buckets 'velero-backups' and 'cnpg-backups' plus one scoped access key and
#  writes the credentials to Vault:
#
#    homelab/infrastructure/garage-backup-secret  access-key-id, secret-access-key
#       -> ExternalSecret garage-backup-secret (ns infrastructure), used by CNPG
#    homelab/backup/velero-garage-secret          cloud (AWS credentials file)
#       -> ExternalSecret velero-secret (ns backup), used by Velero
#
#  The old MinIO-based Vault paths are left untouched, so this script can run
#  BEFORE the PR that switches Velero/CNPG to Garage is merged without
#  breaking the running backups.
#
#  IDEMPOTENT: if both Vault paths already exist, nothing is changed.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Garage laeuft (Namespace infrastructure)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-garage-backups.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
CNPG_PATH="homelab/infrastructure/garage-backup-secret"
VELERO_PATH="homelab/backup/velero-garage-secret"
GARAGE_NS="infrastructure"
GARAGE_POD="garage-0"
BUCKETS=("velero-backups" "cnpg-backups")
KEY_NAME="backup-key"

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

garage_exec() {
  # Absolute path, no shell in the image.
  kubectl exec -n "${GARAGE_NS}" "${GARAGE_POD}" -- /garage "$@"
}

if vault_kv_path_exists "${CNPG_PATH}" && vault_kv_path_exists "${VELERO_PATH}"; then
  echo "==> Beide Vault-Pfade existieren bereits - nichts zu tun."
  exit 0
fi

for b in "${BUCKETS[@]}"; do
  echo "==> Lege Garage-Bucket '${b}' an..."
  garage_exec bucket create "${b}" 2>/dev/null || echo "    Bucket existiert bereits."
done

echo "==> Lege Access-Key '${KEY_NAME}' an..."
garage_exec key create "${KEY_NAME}" 2>/dev/null || echo "    Key existiert bereits."

for b in "${BUCKETS[@]}"; do
  echo "==> Erlaube Key '${KEY_NAME}' Lesen/Schreiben auf '${b}'..."
  garage_exec bucket allow --read --write --key "${KEY_NAME}" "${b}"
done

echo "==> Lese Access-Key-Details aus (Secret wird nicht ausgegeben)..."
KEY_INFO=$(garage_exec key info "${KEY_NAME}" --show-secret)
ACCESS_KEY_ID=$(echo "${KEY_INFO}" | grep -i "Key ID:" | awk '{print $NF}')
SECRET_ACCESS_KEY=$(echo "${KEY_INFO}" | grep -i "Secret key:" | awk '{print $NF}')

if [[ -z "${ACCESS_KEY_ID}" ]] || [[ -z "${SECRET_ACCESS_KEY}" ]]; then
  echo "    FEHLER: Konnte Key ID/Secret nicht aus 'garage key info' parsen."
  echo "    Pruefe das Output-Format (garage-0: /garage key info ${KEY_NAME} --show-secret)"
  echo "    und passe die grep-Muster in diesem Skript an."
  exit 1
fi

vault_kv_put "${CNPG_PATH}" \
  "access-key-id=${ACCESS_KEY_ID}" \
  "secret-access-key=${SECRET_ACCESS_KEY}"

CREDENTIALS_CONTENT=$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
  "${ACCESS_KEY_ID}" "${SECRET_ACCESS_KEY}")
vault_kv_put "${VELERO_PATH}" "cloud=${CREDENTIALS_CONTENT}"

echo ""
echo "============================================"
echo "  Fertig. Buckets: ${BUCKETS[*]}"
echo "  Jetzt den PR mit der Umstellung auf Garage mergen."
echo "============================================"
