#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-forgejo.sh
#  Generates Forgejo's SECRET_KEY and INTERNAL_TOKEN and writes them to Vault
#  at 'homelab/forgejo/forgejo-secret'. The ExternalSecret 'forgejo-secret'
#  (namespace forgejo) picks them up from there.
#
#  IDEMPOTENT: if the Vault path already exists, nothing is changed. Rotating
#  SECRET_KEY invalidates 2FA secrets and stored tokens, so this script never
#  overwrites it.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Vault laeuft (Namespace security)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-forgejo.sh
#
#  Danach den Admin-User anlegen (Passwort wird nur abgefragt, nirgends
#  gespeichert):
#    kubectl exec -it -n forgejo deploy/forgejo -- forgejo admin user create \
#      --admin --username <name> --email <mail> --must-change-password=false
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/forgejo/forgejo-secret"
IMAGE="codeberg.org/forgejo/forgejo:15.0.10-rootless"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_exec() {
  kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" vault "$@"
}

forgejo_generate() {
  kubectl run "forgejo-gen-$RANDOM" --rm -i --restart=Never -q \
    --image="$IMAGE" --command -- forgejo generate secret "$1" | tr -d '\r\n'
}

if vault_exec kv get "secret/${VAULT_PATH}" &>/dev/null; then
  echo "==> ${VAULT_PATH} existiert bereits in Vault - nichts zu tun."
  exit 0
fi

echo "==> Generiere Secrets..."
SECRET_KEY=$(forgejo_generate SECRET_KEY)
INTERNAL_TOKEN=$(forgejo_generate INTERNAL_TOKEN)

echo "==> Schreibe nach Vault (Werte werden nicht ausgegeben)..."
printf '{"secret-key":"%s","internal-token":"%s"}' "$SECRET_KEY" "$INTERNAL_TOKEN" |
  vault_exec kv put "secret/${VAULT_PATH}" - >/dev/null

kubectl annotate externalsecret forgejo-secret -n forgejo \
  force-sync="$(date +%s)" --overwrite 2>/dev/null ||
  echo "    (ExternalSecret noch nicht deployt - wird beim naechsten Sync abgeholt)"

echo "==> Fertig. Admin-User anlegen: siehe Kopfkommentar dieses Skripts."
