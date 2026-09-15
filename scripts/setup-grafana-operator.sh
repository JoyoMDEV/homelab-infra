#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-grafana-operator.sh
#  Schreibt das Grafana Service-Account-Token für grafana-operator nach
#  Vault. Das ExternalSecret 'grafana-operator-secret' (Namespace monitoring)
#  übernimmt von dort die Pflege des Kubernetes Secrets, das die Grafana CR
#  (k8s/monitoring/dashboards/grafana-instance.yaml) für API-Auth mountet.
#
#  VORAUSSETZUNGEN:
#  - Grafana läuft und ist per OIDC erreichbar: https://grafana.homelab.local
#  - Service Account manuell angelegt (kein API-Weg möglich - das bestehende
#    Coder-MCP-Token ist absichtlich auf Viewer/Editor beschränkt, kein
#    serviceaccounts:write):
#      Grafana -> Administration -> Users and access -> Service accounts
#      -> New service account "grafana-operator", Role "Editor"
#      -> Add service account token -> Token kopieren (nur einmal sichtbar!)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-grafana-operator.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/monitoring/grafana-operator-secret"
NAMESPACE="monitoring"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_put() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

echo ""
echo "============================================"
echo "  grafana-operator - Vault Secret Setup"
echo "============================================"
echo ""
echo "==> Grafana Service Account Token"
echo "    Grafana -> Administration -> Users and access -> Service accounts"
echo "    -> New service account 'grafana-operator', Role 'Editor'"
echo "    -> Add service account token"
echo ""
read -rsp "    Token eingeben (wird nicht angezeigt): " GF_API_TOKEN
echo ""

if [[ -z "${GF_API_TOKEN}" ]]; then
  echo "    FEHLER: Kein Token angegeben. Abbruch."
  exit 1
fi

echo ""
echo "==> Schreibe Secret nach Vault ('${VAULT_PATH}')..."
vault_kv_put "${VAULT_PATH}" "GF_API_TOKEN=${GF_API_TOKEN}"
echo "    Geschrieben."

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret grafana-operator-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo "  1. ArgoCD Apps committen/pushen (grafana-operator, monitoring-rules,"
echo "     monitoring-dashboards) falls noch nicht geschehen."
echo "  2. Sync beobachten: kubectl get grafana,grafanadashboard -n monitoring"
echo "  3. Dashboards in Grafana prüfen: https://grafana.homelab.local"
echo "============================================"
