#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-monitoring.sh
#  Schreibt Secrets für den Monitoring-Stack (Grafana + Alertmanager) nach
#  Vault. Das ExternalSecret 'grafana-keycloak-secret' (Namespace monitoring)
#  übernimmt von dort die Pflege des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - Kubernetes-Cluster läuft: make status
#  - Keycloak Client 'grafana' angelegt (siehe docs/keycloak-setup.md Abschnitt 6)
#  - Discord Webhook URL bereit (optional – Alertmanager)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-monitoring.sh
#
#  WAS DIESES SCRIPT SCHREIBT:
#  - homelab/monitoring/grafana-keycloak-secret
#      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET  → Keycloak Client Secret für Grafana
#      ALERTMANAGER_DISCORD_WEBHOOK_URL     → Discord Webhook für Alertmanager
#
#  WARUM EIN SHARED SECRET:
#  Alertmanager braucht den Webhook als Datei im Pod-Filesystem.
#  Das Mounten des gleichen Secrets in beide Pods (Grafana + Alertmanager)
#  ist einfacher als zwei separate Secrets zu verwalten.
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="monitoring/grafana-keycloak-secret"
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
echo "  Monitoring Stack – Vault Secret Setup"
echo "============================================"
echo ""

# ─── Namespace erstellen falls noch nicht vorhanden ──────────────────────────
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Erstelle Namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}"
  kubectl label namespace "${NAMESPACE}" \
    homelab.local/inject-ca=true \
    managed-by=argocd
  echo "    Namespace erstellt und CA-Injection aktiviert."
else
  echo "==> Namespace '${NAMESPACE}' existiert bereits."
  kubectl label namespace "${NAMESPACE}" \
    homelab.local/inject-ca=true \
    managed-by=argocd \
    --overwrite 2>/dev/null || true
fi

# ─── Keycloak Client Secret abfragen ─────────────────────────────────────────
echo ""
echo "==> Grafana Keycloak OIDC Client Secret"
echo "    Keycloak → Realm homelab → Clients → grafana → Credentials"
echo ""
read -rsp "    Client Secret eingeben (wird nicht angezeigt): " OIDC_SECRET
echo ""

if [[ -z "${OIDC_SECRET}" ]]; then
  echo "    FEHLER: Kein Client Secret angegeben. Abbruch."
  exit 1
fi

# ─── Discord Webhook URL abfragen (optional) ──────────────────────────────────
echo ""
echo "==> Alertmanager Discord Webhook URL (optional)"
echo "    Discord → Server → Kanal-Einstellungen → Integrationen → Webhook"
echo "    Format: https://discord.com/api/webhooks/..."
echo "    Leer lassen um Alertmanager ohne Discord zu konfigurieren."
echo ""
read -rsp "    Discord Webhook URL (leer = überspringen): " DISCORD_URL
echo ""

# ─── Nach Vault schreiben ─────────────────────────────────────────────────────
echo ""
echo "==> Schreibe Secrets nach Vault ('homelab/${VAULT_PATH}')..."

if [[ -n "${DISCORD_URL}" ]]; then
  vault_kv_put "${VAULT_PATH}" \
    "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${OIDC_SECRET}" \
    "ALERTMANAGER_DISCORD_WEBHOOK_URL=${DISCORD_URL}"
  echo "    Geschrieben (OIDC + Discord Webhook)."
else
  # Ohne Discord: Placeholder eintragen damit der Alertmanager-Mount nicht fehlschlägt
  vault_kv_put "${VAULT_PATH}" \
    "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=${OIDC_SECRET}" \
    "ALERTMANAGER_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/REPLACE_ME"
  echo "    Geschrieben (nur OIDC – Discord Webhook ist Placeholder)."
  echo ""
  echo "    ⚠ Discord Webhook ist Placeholder."
  echo "    Alertmanager-Alerts werden NICHT gesendet bis du ihn ersetzt:"
  echo "      kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \\"
  echo "        VAULT_TOKEN=\$VAULT_TOKEN vault kv patch secret/homelab/${VAULT_PATH} \\"
  echo "        ALERTMANAGER_DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/..."
fi

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret grafana-keycloak-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

# ─── CA-Secret seeden falls cert-sync noch nicht gelaufen ist ────────────────
# (Bootstrap-Mechanismus, kein Operator-Secret - läuft weiterhin direkt über
# kubectl, siehe CLAUDE.md "Never edit directly" Ausnahmen für Bootstrap-Flow.)
echo ""
echo "==> Prüfe homelab-ca Secret im Namespace monitoring..."
if ! kubectl get secret homelab-ca -n "${NAMESPACE}" &>/dev/null; then
  echo "    homelab-ca fehlt, wird aus cert-manager kopiert..."
  CA_CRT=$(kubectl get secret homelab-ca-keypair -n cert-manager \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
  if [[ -n "${CA_CRT}" ]]; then
    kubectl create secret generic homelab-ca \
      --from-literal=homelab-ca.crt="$(echo "${CA_CRT}" | base64 -d)" \
      -n "${NAMESPACE}"
    echo "    homelab-ca Secret erstellt."
  else
    echo "    ⚠ cert-manager CA Secret nicht gefunden – führe erst 'make bootstrap-certs' aus."
  fi
else
  echo "    homelab-ca Secret bereits vorhanden."
fi

# ─── Hinweis ArgoCD ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. CoreDNS-Eintrag hinzufügen:"
echo "     make setup-coredns"
echo ""
echo "  2. ArgoCD Applications committen und pushen:"
echo "     git add k8s/argocd/applications/monitoring.yaml"
echo "     git add k8s/argocd/applications/loki.yaml"
echo "     git commit -m 'feat: add monitoring stack (Prometheus, Grafana, Loki)'"
echo "     git push"
echo ""
echo "  3. Fortschritt beobachten:"
echo "     kubectl get pods -n monitoring -w"
echo "     make apps"
echo ""
echo "  4. Grafana aufrufen:"
echo "     https://grafana.homelab.local"
echo "     → Login via Keycloak"
echo ""
echo "  Vollständiges Runbook: docs/monitoring-setup.md"
echo "============================================"
