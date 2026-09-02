#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-gitlab-runner.sh
#  Schreibt das GitLab Instance Runner Token nach Vault. Das ExternalSecret
#  'gitlab-runner-secret' (Namespace gitlab) übernimmt von dort die Pflege
#  des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - GitLab läuft unter https://gitlab.homelab.local
#  - homelab-ca Secret existiert im gitlab Namespace
#  - Instance Runner Token aus GitLab Admin Area vorhanden
#    (Admin Area → CI/CD → Runners → New instance runner)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    export GITLAB_RUNNER_TOKEN="glrt-xxxxxxxxxxxxxxxxxxxx"
#    ./scripts/setup-gitlab-runner.sh
#
#  ODER:
#    ./scripts/setup-gitlab-runner.sh --token glrt-xxxxxxxxxxxxxxxxxxxx
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="gitlab/runner-secret"
NAMESPACE="gitlab"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_put() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

# ─── Token aus Argument oder Env ─────────────────────────────────────────────
TOKEN=""

for arg in "$@"; do
  case $arg in
    --token)
      shift
      TOKEN="${1:-}"
      shift
      ;;
    --token=*)
      TOKEN="${arg#*=}"
      ;;
    --help)
      echo "Usage: $0 [--token glrt-xxxx]"
      echo ""
      echo "Token kann auch als Env-Variable übergeben werden:"
      echo "  export GITLAB_RUNNER_TOKEN=glrt-xxxx"
      echo "  $0"
      exit 0
      ;;
  esac
done

if [ -z "${TOKEN}" ]; then
  TOKEN="${GITLAB_RUNNER_TOKEN:-}"
fi

if [ -z "${TOKEN}" ]; then
  echo ""
  echo "GitLab Instance Runner Token fehlt."
  echo ""
  echo "Token holen:"
  echo "  GitLab → Admin Area → CI/CD → Runners → New instance runner"
  echo "  Tags: k8s, Run untagged jobs: ✅"
  echo ""
  read -rsp "Runner Token eingeben (wird nicht angezeigt): " TOKEN
  echo ""
fi

if [ -z "${TOKEN}" ]; then
  echo "FEHLER: Kein Token angegeben. Abbruch."
  exit 1
fi

# ─── Voraussetzungen prüfen ───────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  GitLab Runner Setup"
echo "============================================"
echo ""
echo "==> Prüfe Voraussetzungen..."

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "    FEHLER: Namespace '${NAMESPACE}' nicht gefunden."
  echo "    Stelle sicher dass GitLab deployed ist: make apps"
  exit 1
fi
echo "    Namespace '${NAMESPACE}': OK"

if ! kubectl get secret homelab-ca -n "${NAMESPACE}" &>/dev/null; then
  echo "    FEHLER: Secret 'homelab-ca' nicht im Namespace '${NAMESPACE}'."
  echo "    Führe zuerst aus: make bootstrap-certs"
  exit 1
fi
echo "    homelab-ca Secret: OK"

# ─── Token nach Vault schreiben ──────────────────────────────────────────────
echo ""
echo "==> Schreibe Runner Token nach Vault ('homelab/${VAULT_PATH}')..."

# runner-registration-token bleibt leer - GitLab vergibt darüber nur
# einmalig neue Registrierungen, der eigentliche Runner läuft über
# runner-token weiter.
vault_kv_put "${VAULT_PATH}" \
  "runner-registration-token=" \
  "runner-token=${TOKEN}"

echo "    Geschrieben."

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret gitlab-runner-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

# ─── Hinweis ArgoCD ───────────────────────────────────────────────────────────
echo ""
echo "==> Prüfe ob ArgoCD Application existiert..."

if kubectl get application gitlab-runner -n argocd &>/dev/null; then
  echo "    ArgoCD Application gefunden, erzwinge Sync..."
  kubectl patch application gitlab-runner -n argocd \
    --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' \
    2>/dev/null || true
  echo "    Sync angestoßen."
else
  echo "    ArgoCD Application noch nicht vorhanden."
  echo "    Committe und pushe k8s/argocd/applications/gitlab-runner.yaml"
  echo "    ArgoCD deployed den Runner automatisch."
fi

# ─── Warten bis Runner Pod läuft ─────────────────────────────────────────────
echo ""
echo "==> Warte auf Runner Pod..."
sleep 5

for i in $(seq 1 24); do
  POD=$(kubectl get pods -n "${NAMESPACE}" \
    -l app=gitlab-runner \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -n "${POD}" ]; then
    echo "    Runner Pod läuft: ${POD}"
    break
  fi

  echo "    Warte... (${i}/24)"
  sleep 5
done

if [ -z "${POD:-}" ]; then
  echo ""
  echo "    Runner Pod noch nicht bereit – prüfe manuell:"
  echo "    kubectl get pods -n ${NAMESPACE} | grep runner"
  echo "    kubectl logs -n ${NAMESPACE} -l app=gitlab-runner"
else
  echo ""
  echo "==> Runner Logs (letzte 10 Zeilen):"
  kubectl logs -n "${NAMESPACE}" "${POD}" --tail=10 2>/dev/null || true
fi

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Runner prüfen:"
echo "    kubectl get pods -n ${NAMESPACE} | grep runner"
echo ""
echo "  In GitLab:"
echo "    Admin Area → CI/CD → Runners"
echo "    → k3s-instance-runner sollte grün sein"
echo ""
echo "  Alle Repos nutzen den Runner automatisch"
echo "  sobald die Pipeline tags: [k8s] enthält."
echo "============================================"
