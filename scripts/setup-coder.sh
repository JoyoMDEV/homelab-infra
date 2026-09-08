#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-coder.sh
#  Legt die Postgres-Datenbank/Rolle für Coder an und schreibt die
#  zugehörigen Secrets (DB-Passwort, OIDC-Client-Secret-Platzhalter,
#  Git-SSH-Deploy-Key, Registry-Pull-Credentials) nach Vault. Das
#  ExternalSecret 'coder-secret' (Namespace coder) übernimmt von dort die
#  Pflege des Kubernetes Secrets.
#
#  IDEMPOTENT: Ist 'homelab/coder/coder-secret' schon vollständig befüllt,
#  wird nur das DB-Passwort mit der Postgres-Rolle synchronisiert (ALTER
#  ROLE) - Secret/SSH-Key werden nicht neu generiert. Gleiches für
#  'homelab/coder/registry-pull-secret'.
#
#  VORAUSSETZUNGEN:
#  - VAULT_TOKEN als Env-Var gesetzt
#  - kubectl konfiguriert und Cluster erreichbar
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-coder.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="coder/coder-secret"
REGISTRY_VAULT_PATH="coder/registry-pull-secret"

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_kv_get() {
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get -field="$2" "secret/$1" 2>/dev/null || true
}

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

echo "==> Creating Coder Postgres database/role..."
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s

CODER_DB_PW=$(vault_kv_get "${VAULT_PATH}" "db-password")
[[ -z "${CODER_DB_PW}" ]] && CODER_DB_PW=$(openssl rand -base64 24)

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE coder;" 2>/dev/null || echo "    coder database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'coder') THEN
      CREATE ROLE coder WITH LOGIN PASSWORD '$CODER_DB_PW';
    ELSE
      ALTER ROLE coder WITH PASSWORD '$CODER_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE coder TO coder;
  ALTER DATABASE coder OWNER TO coder;
"
echo "    Coder database created"

if vault_kv_path_exists "${VAULT_PATH}"; then
  echo "    homelab/${VAULT_PATH} existiert bereits - Secret wird nicht neu angelegt (nur db-password oben synchronisiert)."
else
  echo ""
  echo "==> SSH-Deploy-Key für Git-Zugriff (GitHub + self-hosted GitLab)"
  SSH_KEY_DIR=$(mktemp -d)
  ssh-keygen -t ed25519 -N "" -C "coder-workspace@homelab.local" -f "${SSH_KEY_DIR}/id_ed25519" >/dev/null
  GIT_SSH_PRIVATE_KEY=$(cat "${SSH_KEY_DIR}/id_ed25519")
  GIT_SSH_PUBLIC_KEY=$(cat "${SSH_KEY_DIR}/id_ed25519.pub")
  rm -rf "${SSH_KEY_DIR}"

  vault_kv_put "${VAULT_PATH}" \
    "db-password=${CODER_DB_PW}" \
    "oidc-client-secret=REPLACE_AFTER_KEYCLOAK_SETUP" \
    "git-ssh-private-key=${GIT_SSH_PRIVATE_KEY}"

  force_sync coder-secret coder

  echo ""
  echo "    Öffentlicher Schlüssel (als Deploy Key/SSH-Key hinterlegen, siehe docs/coder-setup.md):"
  echo ""
  echo "${GIT_SSH_PUBLIC_KEY}"
fi

echo ""
if vault_kv_path_exists "${REGISTRY_VAULT_PATH}"; then
  echo "    homelab/${REGISTRY_VAULT_PATH} existiert bereits - nichts zu tun."
else
  echo "==> GitLab Registry-Pull-Credentials (für registry.homelab.local)"
  echo "    Personal/Deploy Access Token mit 'read_registry'-Scope für das"
  echo "    Projekt 'homelab/projects/coder-workspace'."
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

  force_sync coder-workspace-registry-pull coder
fi

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  DB Password: $CODER_DB_PW"
echo ""
echo "  Nächste Schritte: siehe docs/coder-setup.md"
echo "============================================"
