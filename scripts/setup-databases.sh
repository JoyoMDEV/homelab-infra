#!/bin/bash
set -euo pipefail

echo "==> Creating databases for Keycloak and GitLab..."

# Wait for PostgreSQL to be ready
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s

# Create Keycloak database and user
KEYCLOAK_DB_PW=$(openssl rand -base64 24)
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE keycloak;" 2>/dev/null || echo "    keycloak database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') THEN
      CREATE ROLE keycloak WITH LOGIN PASSWORD '$KEYCLOAK_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
  ALTER DATABASE keycloak OWNER TO keycloak;
"
echo "    Keycloak database created"

# Create GitLab database and user
GITLAB_DB_PW=$(openssl rand -base64 24)
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE gitlab;" 2>/dev/null || echo "    gitlab database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gitlab') THEN
      CREATE ROLE gitlab WITH LOGIN PASSWORD '$GITLAB_DB_PW' SUPERUSER;
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

# Nextcloud DB
NEXTCLOUD_DB_PW=$(openssl rand -base64 24)
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "CREATE DATABASE nextcloud;" 2>/dev/null || echo "    nextcloud database already exists"
kubectl exec homelab-pg-1 -n infrastructure -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'nextcloud') THEN
      CREATE ROLE nextcloud WITH LOGIN PASSWORD '$NEXTCLOUD_DB_PW';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
  ALTER DATABASE nextcloud OWNER TO nextcloud;
"

# Nextcloud Admin + Secrets
NEXTCLOUD_ADMIN_PW=$(openssl rand -base64 16)
REDIS_PW=$(kubectl get secret redis-secret -n infrastructure -o jsonpath='{.data.redis-password}' | base64 -d)
STORAGE_BOX_PW="<dein-storage-box-passwort>"  # aus terraform.tfvars

kubectl create secret generic nextcloud-secret \
  --from-literal=nextcloud-username="admin" \
  --from-literal=nextcloud-password="$NEXTCLOUD_ADMIN_PW" \
  --from-literal=db-username="nextcloud" \
  --from-literal=db-password="$NEXTCLOUD_DB_PW" \
  --from-literal=redis-password="$REDIS_PW" \
  --from-literal=storage-box-password="$STORAGE_BOX_PW" \
  --from-literal=oidc-client-secret="REPLACE_AFTER_KEYCLOAK_SETUP" \
  -n productivity 2>/dev/null || echo "    nextcloud-secret already exists, skipping"

echo "Nextcloud Admin: admin / $NEXTCLOUD_ADMIN_PW"
echo "DB Password: $NEXTCLOUD_DB_PW"

echo "==> Creating Keycloak secrets..."
KEYCLOAK_ADMIN_PW=$(openssl rand -base64 16)
if ! kubectl get secret keycloak-secret -n auth &>/dev/null; then
  kubectl create secret generic keycloak-secret \
    --from-literal=admin-password="$KEYCLOAK_ADMIN_PW" \
    -n auth
fi
if ! kubectl get secret keycloak-db-secret -n auth &>/dev/null; then
  kubectl create secret generic keycloak-db-secret \
    --from-literal=password="$KEYCLOAK_DB_PW" \
    -n auth
fi

echo "==> Creating GitLab secrets..."
if ! kubectl get secret gitlab-secret -n gitlab &>/dev/null; then
  kubectl create secret generic gitlab-secret \
    --from-literal=db-password="$GITLAB_DB_PW" \
    --from-literal=redis-password="$REDIS_PW" \
    --from-literal=oidc-client-secret="REPLACE_AFTER_KEYCLOAK_SETUP" \
    -n gitlab
fi

echo "==> Creating GitLab Rails secrets (encryption keys)..."
if ! kubectl get secret gitlab-rails-secrets -n gitlab &>/dev/null; then
  SECRET_KEY_BASE=$(openssl rand -hex 64)
  DB_KEY_BASE=$(openssl rand -hex 64)
  OTP_KEY_BASE=$(openssl rand -hex 64)
  CI_JOB_TOKEN_SIGNING_KEY=$(openssl rand -hex 32)
  kubectl create secret generic gitlab-rails-secrets \
    --from-literal=secret_key_base="$SECRET_KEY_BASE" \
    --from-literal=db_key_base="$DB_KEY_BASE" \
    --from-literal=otp_key_base="$OTP_KEY_BASE" \
    --from-literal=ci_job_token_signing_key="$CI_JOB_TOKEN_SIGNING_KEY" \
    -n gitlab
  echo "    GitLab Rails secrets created"
  echo "    IMPORTANT: These keys encrypt data in the database."
  echo "    They are stored in the gitlab-rails-secrets Kubernetes secret."
  echo "    Do NOT delete this secret or you will lose access to encrypted data!"
else
  echo "    GitLab Rails secrets already exist, skipping"
fi

echo ""
echo "============================================"
echo "  Secrets created!"
echo ""
echo "  Keycloak Admin:  admin / $KEYCLOAK_ADMIN_PW"
echo "  Keycloak DB:     keycloak / $KEYCLOAK_DB_PW"
echo "  GitLab DB:       gitlab / $GITLAB_DB_PW"
echo ""
echo "  Save these passwords somewhere safe!"
echo "============================================"
