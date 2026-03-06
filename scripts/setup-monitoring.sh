#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-monitoring.sh
#  Erstellt Secrets für den Monitoring-Stack (Grafana + Alertmanager).
#
#  VORAUSSETZUNGEN:
#  - Kubernetes-Cluster läuft: make status
#  - Keycloak Client 'grafana' angelegt (siehe docs/keycloak-setup.md Abschnitt 6)
#  - Discord Webhook URL bereit (optional – Alertmanager)
#
#  USAGE:
#    ./scripts/setup-monitoring.sh
#
#  WAS DIESES SCRIPT ERSTELLT:
#  - grafana-keycloak-secret (Namespace: monitoring)
#      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET  → Keycloak Client Secret für Grafana
#      ALERTMANAGER_DISCORD_WEBHOOK_URL     → Discord Webhook für Alertmanager
#
#  WARUM EIN SHARED SECRET:
#  Alertmanager braucht den Webhook als Datei im Pod-Filesystem.
#  Das Mounten des gleichen Secrets in beide Pods (Grafana + Alertmanager)
#  ist einfacher als zwei separate Secrets zu verwalten.
# =============================================================================

NAMESPACE="monitoring"
SECRET_NAME="grafana-keycloak-secret"

echo ""
echo "============================================"
echo "  Monitoring Stack – Secret Setup"
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
  # CA-Injection Label sicherstellen
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

# ─── Bestehendes Secret löschen falls vorhanden ──────────────────────────────
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo ""
  echo "==> Secret '${SECRET_NAME}' existiert bereits, wird aktualisiert..."
  kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

# ─── Secret erstellen ────────────────────────────────────────────────────────
echo ""
echo "==> Erstelle Secret '${SECRET_NAME}'..."

if [[ -n "${DISCORD_URL}" ]]; then
  kubectl create secret generic "${SECRET_NAME}" \
    --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${OIDC_SECRET}" \
    --from-literal=ALERTMANAGER_DISCORD_WEBHOOK_URL="${DISCORD_URL}" \
    -n "${NAMESPACE}"
  echo "    Secret erstellt (OIDC + Discord Webhook)."
else
  # Ohne Discord: Placeholder eintragen damit der Alertmanager-Mount nicht fehlschlägt
  kubectl create secret generic "${SECRET_NAME}" \
    --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET="${OIDC_SECRET}" \
    --from-literal=ALERTMANAGER_DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/REPLACE_ME" \
    -n "${NAMESPACE}"
  echo "    Secret erstellt (nur OIDC – Discord Webhook ist Placeholder)."
  echo ""
  echo "    ⚠ Discord Webhook ist Placeholder."
  echo "    Alertmanager-Alerts werden NICHT gesendet bis du ihn ersetzt:"
  echo "      kubectl patch secret ${SECRET_NAME} -n ${NAMESPACE} \\"
  echo "        --type merge \\"
  echo "        -p '{\"stringData\":{\"ALERTMANAGER_DISCORD_WEBHOOK_URL\":\"https://discord.com/api/webhooks/...\"}}"
fi

# ─── CA-Secret seeden falls cert-sync noch nicht gelaufen ist ────────────────
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
