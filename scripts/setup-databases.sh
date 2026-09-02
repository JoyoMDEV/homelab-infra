#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-databases.sh
#  Legt die Postgres-Datenbanken/Rollen für Keycloak, GitLab, Backstage,
#  Nextcloud und Paperless an, und schreibt die zugehörigen Secrets nach
#  Vault. Die jeweiligen ExternalSecrets übernehmen von dort die Pflege der
#  Kubernetes Secrets.
#
#  IDEMPOTENT: Wenn in Vault für einen Pfad schon Werte hinterlegt sind,
#  werden diese für die Postgres-Rolle wiederverwendet (ALTER ROLE) statt
#  bei jedem Lauf neue Passwörter zu generieren. nextcloud-secret/
#  paperless-secret werden nur beim allerersten Lauf initial angelegt -
#  Paperless' übrige Felder (Redis/SMTP/OIDC) pflegt danach
#  setup-paperless.sh per Merge.
#
#  VORAUSSETZUNGEN:
#  - VAULT_TOKEN als Env-Var gesetzt
#  - homelab/infrastructure/redis-secret bereits in Vault (siehe
#    migrate-secrets-to-vault.sh oder bootstrap-argocd.sh)
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-databases.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"

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
  # force_sync <externalsecret-name> <namespace>
  kubectl annotate externalsecret "$1" -n "$2" \
    force-sync="$(date +%s)" --overwrite 2>/dev/null || \
    echo "    (ExternalSecret $1 noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"
}

# db_password_for <vault-path> -> gibt bestehendes Passwort aus Vault zurück,
# oder generiert (und druckt) ein neues wenn noch keins hinterlegt ist.
db_password_for() {
  local existing
  existing=$(vault_kv_get "$1" "db-password")
  if [[ -n "$existing" ]]; then
    echo "$existing"
  else
    openssl rand -base64 24
  fi
}

echo "==> Creating databases for Keycloak, GitLab, Backstage, Nextcloud, Paperless..."

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s

REDIS_PW=$(vault_kv_get "infrastructure/redis-secret" "redis-password")
if [[ -z "${REDIS_PW}" ]]; then
  echo "    FEHLER: Redis-Passwort nicht in Vault ('homelab/infrastructure/redis-secret')."
  echo "    Führe zuerst aus: ./scripts/migrate-secrets-to-vault.sh"
  exit 1
fi

# ─── Keycloak DB ──────────────────────────────────────────────────────────────
KEYCLOAK_DB_PW=$(vault_kv_get "auth/keycloak-db-secret" "password")
[[ -z "${KEYCLOAK_DB_PW}" ]] && KEYCLOAK_DB_PW=$(openssl rand -base64 24)

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE keycloak;" 2>/dev/null || echo "    keycloak database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
      CREATE ROLE keycloak WITH LOGIN PASSWORD '$KEYCLOAK_DB_PW';
    ELSE
      ALTER ROLE keycloak WITH PASSWORD '$KEYCLOAK_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
  ALTER DATABASE keycloak OWNER TO keycloak;
"
echo "    Keycloak database created"

# ─── GitLab DB ─────────────────────────────────────────────────────────────────
GITLAB_DB_PW=$(vault_kv_get "gitlab/gitlab-secret" "db-password")
[[ -z "${GITLAB_DB_PW}" ]] && GITLAB_DB_PW=$(openssl rand -base64 24)

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE gitlab;" 2>/dev/null || echo "    gitlab database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gitlab') THEN
      CREATE ROLE gitlab WITH LOGIN PASSWORD '$GITLAB_DB_PW';
    ELSE
      ALTER ROLE gitlab WITH PASSWORD '$GITLAB_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE gitlab TO gitlab;
  ALTER DATABASE gitlab OWNER TO gitlab;
"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -d gitlab -c "
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  CREATE EXTENSION IF NOT EXISTS btree_gist;
"
echo "    GitLab database created"

# ─── Backstage DB ──────────────────────────────────────────────────────────────
# backstage-secret ist bereits Vault-nativ befüllt (siehe docs/vault-setup.md) -
# hier nur die Postgres-Rolle auf das dort hinterlegte Passwort synchronisieren.
BACKSTAGE_DB_PW=$(vault_kv_get "backstage/backstage-secret" "db-password")
if [[ -z "${BACKSTAGE_DB_PW}" ]]; then
  echo "    WARNUNG: kein db-password unter homelab/backstage/backstage-secret in Vault -"
  echo "    generiere eins, aber es muss danach dort hinterlegt werden:"
  BACKSTAGE_DB_PW=$(openssl rand -base64 24)
  echo "      kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \\"
  echo "        VAULT_TOKEN=\$VAULT_TOKEN vault kv patch secret/homelab/backstage/backstage-secret \\"
  echo "        db-password='${BACKSTAGE_DB_PW}'"
fi

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE backstage;" 2>/dev/null || echo "    backstage database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backstage') THEN
      CREATE ROLE backstage WITH LOGIN PASSWORD '$BACKSTAGE_DB_PW';
    ELSE
      ALTER ROLE backstage WITH PASSWORD '$BACKSTAGE_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE backstage TO backstage;
  ALTER DATABASE backstage OWNER TO backstage;
"
echo "    Backstage database created"

# ─── Nextcloud DB + Secret (nur initial) ──────────────────────────────────────
if vault_kv_path_exists "productivity/nextcloud-secret"; then
  echo "    nextcloud-secret existiert bereits in Vault - Datenbank/Secret werden nicht neu angelegt."
  NEXTCLOUD_DB_PW=$(vault_kv_get "productivity/nextcloud-secret" "db-password")
else
  NEXTCLOUD_DB_PW=$(openssl rand -base64 24)
fi

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE nextcloud;" 2>/dev/null || echo "    nextcloud database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nextcloud') THEN
      CREATE ROLE nextcloud WITH LOGIN PASSWORD '$NEXTCLOUD_DB_PW';
    ELSE
      ALTER ROLE nextcloud WITH PASSWORD '$NEXTCLOUD_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
  ALTER DATABASE nextcloud OWNER TO nextcloud;
"

if ! vault_kv_path_exists "productivity/nextcloud-secret"; then
  NEXTCLOUD_ADMIN_PW=$(openssl rand -base64 16)
  echo ""
  echo "==> Hetzner Storage Box Passwort für Nextcloud"
  read -rsp "    Storage Box Passwort (wird nicht angezeigt, leer = Platzhalter): " STORAGE_BOX_PW
  echo ""
  [[ -z "${STORAGE_BOX_PW}" ]] && STORAGE_BOX_PW="REPLACE_ME"

  vault_kv_put "productivity/nextcloud-secret" \
    "nextcloud-username=admin" \
    "nextcloud-password=${NEXTCLOUD_ADMIN_PW}" \
    "db-username=nextcloud" \
    "db-password=${NEXTCLOUD_DB_PW}" \
    "redis-password=${REDIS_PW}" \
    "storage-box-password=${STORAGE_BOX_PW}" \
    "oidc-client-secret=REPLACE_AFTER_KEYCLOAK_SETUP"

  force_sync nextcloud-secret productivity

  echo "Nextcloud Admin: admin / $NEXTCLOUD_ADMIN_PW"
  echo "DB Password: $NEXTCLOUD_DB_PW"
fi

# ─── Paperless DB + Secret (Phase 1 - Initialbefüllung) ──────────────────────
# Redis/SMTP/OIDC-Felder werden von setup-paperless.sh per Merge ergänzt/
# aktualisiert. Existiert der Vault-Pfad schon (egal ob nur Phase 1 oder
# schon vollständig durch Phase 2), wird hier NICHTS mehr angefasst - ein
# put würde die von Phase 2 gemergten Felder sonst überschreiben.
if vault_kv_path_exists "productivity/paperless-secret"; then
  echo "    paperless-secret existiert bereits in Vault - Datenbank/Secret werden nicht neu angelegt."
  PAPERLESS_DB_PW=$(vault_kv_get "productivity/paperless-secret" "db-password")
else
  PAPERLESS_DB_PW=$(openssl rand -base64 24)
fi

kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE paperless;" 2>/dev/null || echo "    paperless database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'paperless') THEN
      CREATE ROLE paperless WITH LOGIN PASSWORD '$PAPERLESS_DB_PW';
    ELSE
      ALTER ROLE paperless WITH PASSWORD '$PAPERLESS_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE paperless TO paperless;
  ALTER DATABASE paperless OWNER TO paperless;
"
echo "    Paperless database created"

if ! vault_kv_path_exists "productivity/paperless-secret"; then
  PAPERLESS_SECRET_KEY=$(openssl rand -base64 48)
  vault_kv_put "productivity/paperless-secret" \
    "db-username=paperless" \
    "db-password=${PAPERLESS_DB_PW}" \
    "redis-password=${REDIS_PW}" \
    "secret-key=${PAPERLESS_SECRET_KEY}" \
    "oidc-client-secret=REPLACE_AFTER_KEYCLOAK_SETUP"
  echo "    paperless-secret initial in Vault angelegt (Phase 1). Führe danach setup-paperless.sh"
  echo "    aus, um Redis-URL/SMTP/OIDC zu ergänzen."
  echo "Paperless DB Password: $PAPERLESS_DB_PW"
fi

# ─── Keycloak Secrets ───────────────────────────────────────────────────────
echo "==> Writing Keycloak secrets to Vault..."
KEYCLOAK_ADMIN_PW=$(vault_kv_get "auth/keycloak-secret" "admin-password")
if [[ -z "${KEYCLOAK_ADMIN_PW}" ]]; then
  KEYCLOAK_ADMIN_PW=$(openssl rand -base64 16)
  vault_kv_put "auth/keycloak-secret" "admin-password=${KEYCLOAK_ADMIN_PW}"
  force_sync keycloak-secret auth
fi

if [[ -z "$(vault_kv_get "auth/keycloak-db-secret" "password")" ]]; then
  vault_kv_put "auth/keycloak-db-secret" "password=${KEYCLOAK_DB_PW}"
  force_sync keycloak-db-secret auth
fi

# ─── GitLab Secrets ─────────────────────────────────────────────────────────
echo "==> Writing GitLab secrets to Vault..."
if ! vault_kv_path_exists "gitlab/gitlab-secret"; then
  vault_kv_put "gitlab/gitlab-secret" \
    "db-password=${GITLAB_DB_PW}" \
    "redis-password=${REDIS_PW}" \
    "oidc-client-secret=REPLACE_AFTER_KEYCLOAK_SETUP"
  force_sync gitlab-secret gitlab
fi

echo "==> Writing GitLab Rails secrets (encryption keys) to Vault..."
if ! vault_kv_path_exists "gitlab/rails-secrets"; then
  SECRET_KEY_BASE=$(openssl rand -hex 64)
  DB_KEY_BASE=$(openssl rand -hex 64)
  OTP_KEY_BASE=$(openssl rand -hex 64)
  # CI job token signing key must be an RSA 2048 private key in PEM format
  CI_JOB_TOKEN_SIGNING_KEY=$(openssl genrsa 2048 2>/dev/null)
  vault_kv_put "gitlab/rails-secrets" \
    "secret-key-base=${SECRET_KEY_BASE}" \
    "db-key-base=${DB_KEY_BASE}" \
    "otp-key-base=${OTP_KEY_BASE}" \
    "ci-job-token-signing-key=${CI_JOB_TOKEN_SIGNING_KEY}"
  force_sync gitlab-rails-secrets gitlab
  echo "    GitLab Rails secrets created"
  echo "    IMPORTANT: These keys encrypt data in the database."
  echo "    They now live in Vault at homelab/gitlab/rails-secrets."
  echo "    Do NOT delete/overwrite this path or you will lose access to encrypted data!"
else
  echo "    GitLab Rails secrets already exist in Vault, skipping"
fi

echo ""
echo "============================================"
echo "  Secrets written to Vault!"
echo ""
echo "  Keycloak Admin:  admin / $KEYCLOAK_ADMIN_PW"
echo "  Keycloak DB:     keycloak / $KEYCLOAK_DB_PW"
echo "  GitLab DB:       gitlab / $GITLAB_DB_PW"
echo "============================================"
