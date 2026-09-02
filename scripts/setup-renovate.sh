#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-renovate.sh
#  Schreibt den GitHub Fine-grained PAT für Renovate nach Vault. Das
#  ExternalSecret 'renovate-secret' (Namespace automation) übernimmt von dort
#  die Pflege des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-renovate.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="automation/renovate-secret"
NAMESPACE="automation"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_put() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

echo ""
echo "============================================"
echo "  Renovate Bot – Vault Secret Setup"
echo "============================================"
echo ""

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  kubectl create namespace "${NAMESPACE}"
fi

echo "==> GitHub Fine-grained Personal Access Token"
echo "    Berechtigungen für JoyoMDEV/homelab-infra:"
echo "      Contents:      Read and Write"
echo "      Pull requests: Read and Write"
echo ""
read -rsp "    Token eingeben (wird nicht angezeigt): " GITHUB_TOKEN
echo ""

if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "FEHLER: Kein Token angegeben."
  exit 1
fi

echo ""
echo "==> Schreibe Token nach Vault ('homelab/${VAULT_PATH}')..."
# RENOVATE_TOKEN ist der Key den Renovate via existingSecret erwartet
vault_kv_put "${VAULT_PATH}" "RENOVATE_TOKEN=${GITHUB_TOKEN}"
echo "    Geschrieben mit Key: RENOVATE_TOKEN"

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret renovate-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

echo ""
echo "Nächster Schritt – manuellen Lauf triggern:"
echo "  kubectl create job renovate-test-\$(date +%s) --from=cronjob/renovate -n ${NAMESPACE}"
