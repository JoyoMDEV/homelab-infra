#!/bin/bash
set -euo pipefail

# =============================================================================
#  add-authelia-user.sh
#  Legt einen neuen Authelia-Nutzer an (oder aktualisiert einen bestehenden) -
#  erzeugt den Argon2-Passwort-Hash und schreibt die aktualisierte
#  users_database.yml direkt nach Vault zurück.
#
#  VORAUSSETZUNGEN:
#  - docker (oder podman) lokal verfügbar, um den Hash zu erzeugen
#  - vault-0 Pod läuft im security-Namespace
#  - yq installiert (https://github.com/mikefarah/yq) - für sauberes
#    Parsen/Zusammenbauen der YAML-Struktur statt fragilem String-Gefrickel
#
#  USAGE:
#    ./scripts/add-authelia-user.sh <username> <displayname> <email>
#    (fragt interaktiv nach dem Passwort, damit es nicht in der Shell-History
#    landet)
#
#  Nach dem Schreiben nach Vault noch nötig:
#    kubectl -n public annotate externalsecret authelia-users force-sync=$(date +%s) --overwrite
#    kubectl -n public rollout restart deployment/authelia
# =============================================================================

VAULT_NAMESPACE="security"
VAULT_POD="vault-0"
VAULT_PATH="secret/homelab/public/authelia-users"

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <username> <displayname> <email>"
  echo "Beispiel: $0 jsmith 'John Smith' jsmith@example.com"
  exit 1
fi

USERNAME="$1"
DISPLAYNAME="$2"
EMAIL="$3"

# ─── Farben ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

command -v yq >/dev/null 2>&1 || {
  echo -e "${RED}Fehler: yq nicht gefunden. Installieren: https://github.com/mikefarah/yq${NC}"
  exit 1
}

DOCKER_BIN="docker"
command -v docker >/dev/null 2>&1 || DOCKER_BIN="podman"
command -v "$DOCKER_BIN" >/dev/null 2>&1 || {
  echo -e "${RED}Fehler: weder docker noch podman gefunden - wird zum Erzeugen des Hashes gebraucht.${NC}"
  exit 1
}

echo -e "${YELLOW}Passwort für '$USERNAME' eingeben (nicht sichtbar):${NC}"
read -rs PASSWORD
echo
if [[ -z "$PASSWORD" ]]; then
  echo -e "${RED}Fehler: leeres Passwort.${NC}"
  exit 1
fi

echo -e "${YELLOW}Erzeuge Argon2-Hash...${NC}"
HASH=$("$DOCKER_BIN" run --rm authelia/authelia:latest \
  authelia crypto hash generate argon2 --password "$PASSWORD" \
  | sed -n 's/.*Digest: //p')

if [[ -z "$HASH" ]]; then
  echo -e "${RED}Fehler: Hash konnte nicht erzeugt werden.${NC}"
  exit 1
fi

echo -e "${YELLOW}Hole aktuelle users_database.yml aus Vault...${NC}"
CURRENT_YML=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}" \
  vault kv get -field=users_database.yml "$VAULT_PATH" 2>/dev/null || echo "users: {}")

echo -e "${YELLOW}Füge/aktualisiere Nutzer '$USERNAME'...${NC}"
NEW_YML=$(echo "$CURRENT_YML" | yq eval "
  .users.\"$USERNAME\".displayname = \"$DISPLAYNAME\" |
  .users.\"$USERNAME\".password = \"$HASH\" |
  .users.\"$USERNAME\".email = \"$EMAIL\"
" -)

echo -e "${YELLOW}Schreibe zurück nach Vault...${NC}"
kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
  vault kv put "$VAULT_PATH" users_database.yml="$NEW_YML" >/dev/null

echo -e "${GREEN}✓ Nutzer '$USERNAME' angelegt/aktualisiert.${NC}"
echo -e "${YELLOW}Jetzt noch:${NC}"
echo "  kubectl -n public annotate externalsecret authelia-users force-sync=\$(date +%s) --overwrite"
echo "  kubectl -n public rollout restart deployment/authelia"
