#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-vaultwarden.sh
#  Verwaltet die Kubernetes Secrets für Vaultwarden:
#
#    - vaultwarden-secret  (admin-token)
#      → referenziert in values.yaml unter adminToken.existingSecret
#
#    - vaultwarden         (SMTP_USERNAME, SMTP_PASSWORD)
#      → chart-eigenes Secret, wird von ArgoCD/Helm angelegt
#      → dieses Script patcht nur die Credentials rein
#
#  IDEMPOTENT:
#  - Existierender Admin-Token wird NICHT überschrieben
#  - SMTP-Credentials werden immer aktualisiert
#
#  USAGE:
#    ./scripts/setup-vaultwarden.sh
# =============================================================================

NAMESPACE="security"
ADMIN_SECRET="vaultwarden-secret"
CHART_SECRET="vaultwarden"

echo ""
echo "============================================"
echo "  Vaultwarden Secret Setup"
echo "============================================"
echo ""

# ─── Namespace sicherstellen ──────────────────────────────────────────────────
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo "==> Erstelle Namespace '${NAMESPACE}'..."
  kubectl create namespace "${NAMESPACE}"
  kubectl label namespace "${NAMESPACE}" \
    homelab.local/inject-ca=true \
    managed-by=argocd
  echo "    Namespace erstellt."
else
  echo "==> Namespace '${NAMESPACE}' existiert bereits."
  kubectl label namespace "${NAMESPACE}" \
    homelab.local/inject-ca=true \
    managed-by=argocd \
    --overwrite 2>/dev/null || true
fi

# ─── Admin-Token: nur generieren wenn Secret noch nicht existiert ─────────────
echo ""
if kubectl get secret "${ADMIN_SECRET}" -n "${NAMESPACE}" &>/dev/null; then
  echo "==> Secret '${ADMIN_SECRET}' existiert bereits – Admin-Token wird NICHT überschrieben."
else
  echo "==> Generiere neuen Admin-Token..."
  ADMIN_TOKEN=$(openssl rand -base64 48)

  echo ""
  echo "    ┌──────────────────────────────────────────────────────────┐"
  echo "    │  WICHTIG: Admin-Token (einmalig sichtbar!)               │"
  echo "    │                                                          │"
  echo "    │  ${ADMIN_TOKEN}"
  echo "    │                                                          │"
  echo "    │  → Jetzt in Ansible Vault sichern:                       │"
  echo "    │    make vault-edit                                       │"
  echo "    │    vault_vaultwarden_admin_token: \"<token>\"              │"
  echo "    └──────────────────────────────────────────────────────────┘"
  echo ""
  read -rsp "    Enter drücken um fortzufahren (Token wurde gesichert)..." _
  echo ""

  kubectl create secret generic "${ADMIN_SECRET}" \
    --from-literal=admin-token="${ADMIN_TOKEN}" \
    -n "${NAMESPACE}"
  echo "    Secret '${ADMIN_SECRET}' mit Admin-Token erstellt."
fi

# ─── SMTP-Credentials abfragen ────────────────────────────────────────────────
echo ""
echo "==> SMTP Konfiguration"
echo "    Passwort: Hetzner Console → Webhosting → E-Mail → Postfächer → Zugangsdaten"
echo ""
read -rp  "    SMTP Username eingeben: " SMTP_USERNAME
read -rsp "    SMTP Passwort eingeben (wird nicht angezeigt): " SMTP_PASSWORD
echo ""

if [[ -z "${SMTP_USERNAME}" ]]; then
  echo "    FEHLER: Kein SMTP Username angegeben. Abbruch."
  exit 1
fi

if [[ -z "${SMTP_PASSWORD}" ]]; then
  echo "    FEHLER: Kein SMTP Passwort angegeben. Abbruch."
  exit 1
fi

# ─── SMTP ins chart-eigene Secret 'vaultwarden' schreiben ────────────────────
# Das Chart legt dieses Secret selbst an (Keys: SMTP_USERNAME, SMTP_PASSWORD).
# Falls es noch nicht existiert (erster Run vor ArgoCD-Sync), vorab anlegen.
echo ""
echo "==> Schreibe SMTP-Credentials ins Secret '${CHART_SECRET}'..."
if kubectl get secret "${CHART_SECRET}" -n "${NAMESPACE}" &>/dev/null; then
  kubectl patch secret "${CHART_SECRET}" -n "${NAMESPACE}" \
    --type merge \
    -p "{\"stringData\":{\"SMTP_USERNAME\":\"${SMTP_USERNAME}\",\"SMTP_PASSWORD\":\"${SMTP_PASSWORD}\"}}"
  echo "    SMTP-Credentials gepatcht."
else
  echo "    Secret '${CHART_SECRET}' existiert noch nicht – wird vorab angelegt."
  kubectl create secret generic "${CHART_SECRET}" \
    --from-literal=SMTP_USERNAME="${SMTP_USERNAME}" \
    --from-literal=SMTP_PASSWORD="${SMTP_PASSWORD}" \
    -n "${NAMESPACE}"
  echo "    Secret '${CHART_SECRET}' erstellt."
fi

# ─── Altes separates SMTP Secret aufräumen falls vorhanden ───────────────────
if kubectl get secret vaultwarden-smtp-secret -n "${NAMESPACE}" &>/dev/null; then
  echo ""
  echo "==> Altes 'vaultwarden-smtp-secret' wird entfernt..."
  kubectl delete secret vaultwarden-smtp-secret -n "${NAMESPACE}"
  echo "    Entfernt."
fi

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. vault.homelab.local in CoreDNS eintragen:"
echo "     make setup-coredns"
echo ""
echo "  2. ArgoCD Application anwenden:"
echo "     kubectl apply -f k8s/argocd/applications/vaultwarden.yaml"
echo ""
echo "  3. Status prüfen:"
echo "     kubectl get pods -n security"
echo ""
echo "  4. Falls Pod bereits läuft, neu starten damit SMTP greift:"
echo "     kubectl rollout restart deployment vaultwarden -n security"
echo ""
echo "  5. Vaultwarden aufrufen:"
echo "     https://vault.homelab.local"
echo "     Admin Panel: https://vault.homelab.local/admin"
echo "============================================"
