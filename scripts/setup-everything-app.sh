#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-everything-app.sh
#  Schreibt die Registry-Pull-Credentials für everything-app nach Vault.
#  Das ExternalSecret 'everything-app-registry-pull' (Namespace
#  everything-app) übernimmt von dort die Pflege des Kubernetes Secrets,
#  das der Deployment für den Image-Pull von registry.homelab.local
#  braucht - siehe k8s/security/external-secrets/everything-app/.
#
#  IDEMPOTENT: Ist 'homelab/everything-app/registry-pull-secret' schon
#  befüllt, wird nichts überschrieben.
#
#  VORAUSSETZUNGEN:
#  - VAULT_TOKEN als Env-Var gesetzt
#  - kubectl konfiguriert und Cluster erreichbar
#  - Ein Deploy Token (oder Access Token) mit 'read_registry'-Scope für
#    das Projekt 'homelab/projects/everything-app' - siehe GitLab:
#    Settings > Repository > Deploy tokens
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-everything-app.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
REGISTRY_VAULT_PATH="homelab/everything-app/registry-pull-secret"

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
    echo "    (ExternalSecret $1 noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"
}

if vault_kv_path_exists "${REGISTRY_VAULT_PATH}"; then
  echo "    ${REGISTRY_VAULT_PATH} existiert bereits - nichts zu tun."
else
  echo "==> GitLab Registry-Pull-Credentials (für registry.homelab.local)"
  echo "    Deploy Token mit 'read_registry'-Scope für das Projekt"
  echo "    'homelab/projects/everything-app'."
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

  force_sync everything-app-registry-pull everything-app
fi

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo "============================================"
