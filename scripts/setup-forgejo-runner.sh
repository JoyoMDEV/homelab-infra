#!/bin/bash
set -euo pipefail
# =============================================================================
#  setup-forgejo-runner.sh
#  Registers the in-cluster Forgejo Actions runner (global scope) via offline
#  registration and writes its uuid + token to Vault at
#  'homelab/forgejo/forgejo-runner-secret'. The ExternalSecret
#  'forgejo-runner-secret' (namespace forgejo) picks them up from there.
#
#  The 40-hex secret is generated locally: the first 16 chars identify the
#  runner, the rest is the actual token (see Forgejo docs, "Offline
#  registration"). Neither value is printed.
#
#  IDEMPOTENT: if the Vault path already exists, nothing is changed.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert, Forgejo und Vault laufen
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-forgejo-runner.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/forgejo/forgejo-runner-secret"
RUNNER_NAME="k8s-runner"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_exec() {
  kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" vault "$@"
}

if vault_exec kv get "secret/${VAULT_PATH}" &>/dev/null; then
  echo "==> ${VAULT_PATH} existiert bereits in Vault - nichts zu tun."
  exit 0
fi

# A rerun after a failed Vault write would register a second runner with the
# same name; the orphan can be deleted under /admin/actions/runners.
echo "==> Generiere Runner-Secret..."
SECRET=$(openssl rand -hex 20)

echo "==> Registriere Runner '${RUNNER_NAME}' in Forgejo..."
# The runner secret goes in via stdin and a short-lived 0600 file, never as a
# CLI argument (would be visible in the process list). VAULT_TOKEN in
# vault_exec() does still appear in kubectl's argv, same as in every other
# setup-*.sh script.
RUNNER_UUID=$(printf '%s' "$SECRET" | kubectl exec -i -n forgejo deploy/forgejo -- \
  sh -c 'umask 077; f=$(mktemp); cat > "$f";
         forgejo forgejo-cli actions register --name "$1" --secret-file "$f"; rc=$?;
         rm -f "$f"; exit $rc' _ "$RUNNER_NAME" |
  tail -n1 | tr -d '\r\n')
if [[ ! "$RUNNER_UUID" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "    FEHLER: unerwartete Ausgabe von 'forgejo-cli actions register'."
  exit 1
fi

echo "==> Schreibe nach Vault (Werte werden nicht ausgegeben)..."
printf '{"uuid":"%s","token":"%s"}' "$RUNNER_UUID" "$SECRET" |
  vault_exec kv put "secret/${VAULT_PATH}" - >/dev/null

kubectl annotate externalsecret forgejo-runner-secret -n forgejo \
  force-sync="$(date +%s)" --overwrite 2>/dev/null ||
  echo "    (ExternalSecret noch nicht deployt - wird beim naechsten Sync abgeholt)"
kubectl rollout restart deploy/forgejo-runner -n forgejo 2>/dev/null || true
echo "==> Fertig. Runner erscheint unter https://forgejo.homelab.local/admin/actions/runners"
