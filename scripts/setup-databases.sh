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

# Get Redis password
REDIS_PW=$(kubectl get secret redis-secret -n infrastructure -o jsonpath='{.data.redis-password}' | base64 -d)

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
    -n gitlab
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
