#!/bin/bash
set -euo pipefail
# =============================================================================
#  setup-forgejo-backup.sh
#  Creates the Garage bucket 'forgejo-backups' plus an access key scoped to
#  it and writes the key to Vault at 'homelab/forgejo/forgejo-backup-secret'.
#  The ExternalSecret 'forgejo-backup-secret' (namespace forgejo) feeds the
#  nightly forgejo-backup CronJob.
#
#  IDEMPOTENT: if the Vault path already exists, nothing is changed.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Garage (Namespace infrastructure) und Vault laufen
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-forgejo-backup.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/forgejo/forgejo-backup-secret"
GARAGE_NS="infrastructure"
GARAGE_POD="garage-0"
BUCKET="forgejo-backups"
KEY_NAME="forgejo-backup-key"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_exec() {
  kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" vault "$@"
}

garage_exec() {
  # Absolute path, no shell in the image.
  kubectl exec -n "$GARAGE_NS" "$GARAGE_POD" -c garage -- /garage "$@"
}

# Runs a create command; "already exists" is fine, any other error aborts.
garage_create() {
  local out
  if ! out=$(garage_exec "$@" 2>&1); then
    if grep -qi "already exists\|already in use" <<<"$out"; then
      echo "    existiert bereits."
    else
      echo "    FEHLER: $(grep -v INFO <<<"$out" | tail -n3)"
      exit 1
    fi
  fi
}

if vault_exec kv get "secret/${VAULT_PATH}" &>/dev/null; then
  echo "==> ${VAULT_PATH} existiert bereits in Vault - nichts zu tun."
  exit 0
fi

echo "==> Lege Garage-Bucket '${BUCKET}' an..."
garage_create bucket create "$BUCKET"

echo "==> Lege Access-Key '${KEY_NAME}' an..."
garage_create key create "$KEY_NAME"
garage_exec bucket allow --read --write --key "$KEY_NAME" "$BUCKET" >/dev/null 2>&1

echo "==> Lese Access-Key-Details aus (Secret wird nicht ausgegeben)..."
KEY_INFO=$(garage_exec key info "$KEY_NAME" --show-secret 2>/dev/null)
ACCESS_KEY_ID=$(echo "$KEY_INFO" | grep -i "Key ID:" | awk '{print $NF}')
SECRET_ACCESS_KEY=$(echo "$KEY_INFO" | grep -i "Secret key:" | awk '{print $NF}')
if [[ -z "$ACCESS_KEY_ID" || -z "$SECRET_ACCESS_KEY" ]]; then
  echo "    FEHLER: Konnte Key ID/Secret nicht aus 'garage key info' parsen."
  exit 1
fi

echo "==> Schreibe nach Vault..."
printf '{"access-key-id":"%s","secret-access-key":"%s"}' "$ACCESS_KEY_ID" "$SECRET_ACCESS_KEY" |
  vault_exec kv put "secret/${VAULT_PATH}" - >/dev/null

kubectl annotate externalsecret forgejo-backup-secret -n forgejo \
  force-sync="$(date +%s)" --overwrite 2>/dev/null ||
  echo "    (ExternalSecret noch nicht deployt - wird beim naechsten Sync abgeholt)"
echo "==> Fertig. Testlauf: kubectl -n forgejo create job --from=cronjob/forgejo-backup forgejo-backup-test"
