#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-minecraft-rcon.sh
#  Schreibt die rcon-web-admin Login-Credentials (RWA_USERNAME/RWA_PASSWORD)
#  nach Vault, unter demselben Pfad wie das bereits bestehende RCON_PASSWORD.
#  Das ExternalSecret 'minecraft-secret' (Namespace minecraft) übernimmt von
#  dort aus die Erstellung/Pflege des Kubernetes Secrets.
#
#  Nutzt 'vault kv patch' statt 'kv put', damit das bereits gesetzte
#  RCON_PASSWORD an diesem Pfad NICHT überschrieben wird.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - VAULT_TOKEN als Env-Var gesetzt
#  - RCON_PASSWORD an secret/homelab/minecraft/rcon existiert bereits
#
#  IDEMPOTENT: Wenn RWA_USERNAME und RWA_PASSWORD schon gesetzt sind, wird
#  nichts überschrieben - zum bewussten Rotieren einzeln patchen:
#    kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
#      VAULT_TOKEN=$VAULT_TOKEN vault kv patch secret/homelab/minecraft/rcon \
#      RWA_PASSWORD=<neues-passwort>
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-minecraft-rcon.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/minecraft/rcon"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_get() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get -field="$2" "secret/$1" 2>/dev/null || true
}

vault_kv_patch() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv patch "secret/${path}" "$@" >/dev/null
}

echo ""
echo "============================================"
echo "  Minecraft rcon-web-admin – Vault Secret Setup"
echo "============================================"
echo ""

EXISTING_RCON_PW=$(vault_kv_get "${VAULT_PATH}" "RCON_PASSWORD")
if [[ -z "${EXISTING_RCON_PW}" ]]; then
  echo "    FEHLER: 'secret/${VAULT_PATH}' hat noch kein RCON_PASSWORD."
  echo "    Erst den Minecraft-Server-RCON einrichten, z.B.:"
  echo "      vault kv put secret/${VAULT_PATH} RCON_PASSWORD=<zufälliges-passwort>"
  exit 1
fi

EXISTING_USER=$(vault_kv_get "${VAULT_PATH}" "RWA_USERNAME")
EXISTING_PW=$(vault_kv_get "${VAULT_PATH}" "RWA_PASSWORD")

if [[ -n "${EXISTING_USER}" ]] && [[ -n "${EXISTING_PW}" ]]; then
  echo "==> Vault-Pfad '${VAULT_PATH}' hat bereits RWA_USERNAME/RWA_PASSWORD."
  echo "    Nichts zu tun. Zum Rotieren siehe Kommentar am Skriptanfang."
  exit 0
fi

echo "==> rcon-web-admin Login"
echo "    Wird für den Login in die Browser-Konsole unter"
echo "    https://minecraft-rcon.homelab.local verwendet."
echo ""
read -rp    "    Username (z.B. admin): " RWA_USERNAME
read -rsp   "    Passwort (mind. 8 Zeichen, wird nicht angezeigt): " RWA_PASSWORD
echo ""

if [[ -z "${RWA_USERNAME}" ]] || [[ -z "${RWA_PASSWORD}" ]]; then
  echo "    FEHLER: Username oder Passwort leer. Abbruch."
  exit 1
fi

if [[ ${#RWA_PASSWORD} -lt 8 ]]; then
  echo "    FEHLER: Passwort muss mindestens 8 Zeichen haben."
  exit 1
fi

echo ""
echo "==> Patche Credentials nach Vault ('${VAULT_PATH}')..."
vault_kv_patch "${VAULT_PATH}" \
  "RWA_USERNAME=${RWA_USERNAME}" \
  "RWA_PASSWORD=${RWA_PASSWORD}"
echo "    Ergänzt um Keys: RWA_USERNAME, RWA_PASSWORD (RCON_PASSWORD bleibt unverändert)"

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret minecraft-secret -n minecraft \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. Falls noch nicht geschehen: minecraft.yaml committen + pushen,"
echo "     damit ArgoCD den rcon-web-admin-Sidecar + Ingress ausrollt."
echo "  2. Warten bis der Pod neu startet:"
echo "     kubectl get pods -n minecraft -w"
echo "  3. Browser-Konsole öffnen: https://minecraft-rcon.homelab.local"
echo "============================================"
