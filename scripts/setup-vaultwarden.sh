#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-vaultwarden.sh
#  Schreibt die Vaultwarden Secrets nach Vault:
#
#    - homelab/security/vaultwarden-secret  (admin-token)
#      → ExternalSecret 'vaultwarden-secret', Kubernetes Secret 'vaultwarden-secret'
#      → referenziert in values.yaml unter adminToken.existingSecret
#
#    - homelab/security/vaultwarden-smtp    (SMTP_USERNAME, SMTP_PASSWORD)
#      → ExternalSecret 'vaultwarden-smtp', Kubernetes Secret 'vaultwarden'
#        (chart-eigener Name, siehe values.yaml)
#
#  IDEMPOTENT:
#  - Bestehender Admin-Token in Vault wird NICHT überschrieben
#  - SMTP-Credentials werden immer aktualisiert
#
#  VORAUSSETZUNGEN:
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-vaultwarden.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
ADMIN_PATH="security/vaultwarden-secret"
SMTP_PATH="security/vaultwarden-smtp"
NAMESPACE="security"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_get() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get -field="$2" "secret/$1" 2>/dev/null || true
}

vault_kv_put() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

echo ""
echo "============================================"
echo "  Vaultwarden – Vault Secret Setup"
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

# ─── Admin-Token: nur generieren wenn in Vault noch nicht vorhanden ──────────
echo ""
EXISTING_ADMIN_TOKEN=$(vault_kv_get "${ADMIN_PATH}" "admin-token")

if [[ -n "${EXISTING_ADMIN_TOKEN}" ]]; then
  echo "==> Admin-Token existiert bereits in Vault – wird NICHT überschrieben."
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

  vault_kv_put "${ADMIN_PATH}" "admin-token=${ADMIN_TOKEN}"
  echo "    Admin-Token nach Vault geschrieben ('homelab/${ADMIN_PATH}')."
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

echo ""
echo "==> Schreibe SMTP-Credentials nach Vault ('homelab/${SMTP_PATH}')..."
vault_kv_put "${SMTP_PATH}" \
  "SMTP_USERNAME=${SMTP_USERNAME}" \
  "SMTP_PASSWORD=${SMTP_PASSWORD}"
echo "    Geschrieben."

echo ""
echo "==> Stoße sofortigen Sync der ExternalSecrets an..."
kubectl annotate externalsecret vaultwarden-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (vaultwarden-secret ExternalSecret noch nicht deployt)"
kubectl annotate externalsecret vaultwarden-smtp -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (vaultwarden-smtp ExternalSecret noch nicht deployt)"

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
