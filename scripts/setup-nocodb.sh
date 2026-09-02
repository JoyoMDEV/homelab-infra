#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-nocodb.sh
#  Richtet PostgreSQL-Datenbank für NocoDB ein und schreibt die Credentials
#  nach Vault. Das ExternalSecret 'nocodb-secret' (Namespace productivity)
#  übernimmt von dort die Pflege des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - PostgreSQL (CNPG) läuft: kubectl get cluster -n infrastructure
#  - Namespace 'productivity' existiert
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  IDEMPOTENT: Wenn in Vault schon ein DB-Passwort hinterlegt ist, wird
#  dieses wiederverwendet (Postgres-Rolle und Vault bleiben so synchron)
#  statt bei jedem Lauf ein neues zu generieren.
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-nocodb.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="productivity/nocodb-secret"
NAMESPACE="productivity"
DB_HOST="homelab-pg-rw.infrastructure.svc.cluster.local"
DB_PORT="5432"
DB_NAME="nocodb"
DB_USER="nocodb"

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
echo "  NocoDB – Datenbank & Vault Secret Setup"
echo "============================================"
echo ""

# ─── Voraussetzungen prüfen ───────────────────────────────────────────────────
echo "==> Prüfe Voraussetzungen..."

if ! kubectl get pod homelab-pg-1 -n infrastructure &>/dev/null; then
  echo "    FEHLER: PostgreSQL Pod 'homelab-pg-1' nicht gefunden."
  exit 1
fi
echo "    PostgreSQL: OK"

kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"
echo "    Namespace '${NAMESPACE}': OK"

# ─── Warten bis PostgreSQL bereit ist ────────────────────────────────────────
echo ""
echo "==> Warte bis PostgreSQL bereit ist..."
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s
echo "    PostgreSQL bereit."

# ─── Passwort aus Vault wiederverwenden oder neu generieren ──────────────────
echo ""
echo "==> Prüfe Vault auf bestehendes DB-Passwort..."
NOCODB_DB_PW=$(vault_kv_get "${VAULT_PATH}" "db-password")

if [[ -n "${NOCODB_DB_PW}" ]]; then
  echo "    Bestehendes Passwort aus Vault wird wiederverwendet."
else
  echo "    Kein bestehendes Passwort - generiere neues."
  NOCODB_DB_PW=$(openssl rand -base64 24)
fi

NOCODB_JWT_SECRET=$(vault_kv_get "${VAULT_PATH}" "jwt-secret")
if [[ -z "${NOCODB_JWT_SECRET}" ]]; then
  NOCODB_JWT_SECRET=$(openssl rand -base64 48)
fi

# NC_DB URL komplett zusammenbauen – Passwort und URL werden synchron gespeichert.
# Das verhindert den 28P01 Auth-Fehler durch URL/Secret-Mismatch.
NOCODB_DB_URL="pg://${DB_HOST}:${DB_PORT}?u=${DB_USER}&p=${NOCODB_DB_PW}&d=${DB_NAME}"

# ─── Datenbank und User anlegen / Passwort setzen ────────────────────────────
echo ""
echo "==> Lege PostgreSQL Datenbank und User an..."

kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c \
  "CREATE DATABASE ${DB_NAME};" 2>/dev/null \
  && echo "    Datenbank '${DB_NAME}' erstellt." \
  || echo "    Datenbank '${DB_NAME}' existiert bereits."

# ALTER ROLE setzt das Passwort auch wenn der User bereits existiert -
# mit dem aus Vault wiederverwendeten Passwort bleibt das idempotent.
kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
      CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${NOCODB_DB_PW}';
      RAISE NOTICE 'User ${DB_USER} erstellt.';
    ELSE
      ALTER ROLE ${DB_USER} WITH PASSWORD '${NOCODB_DB_PW}';
      RAISE NOTICE 'User ${DB_USER} existiert – Passwort synchronisiert.';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
  ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};
"
echo "    Berechtigungen gesetzt."

# ─── Nach Vault schreiben ─────────────────────────────────────────────────────
echo ""
echo "==> Schreibe Credentials nach Vault ('homelab/${VAULT_PATH}')..."

vault_kv_put "${VAULT_PATH}" \
  "db-password=${NOCODB_DB_PW}" \
  "db-url=${NOCODB_DB_URL}" \
  "jwt-secret=${NOCODB_JWT_SECRET}"

echo "    Geschrieben mit Keys: db-password, db-url, jwt-secret"

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret nocodb-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  PostgreSQL:"
echo "    Datenbank: ${DB_NAME}"
echo "    User:      ${DB_USER}"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. Falls Pod läuft – neu starten damit neues Secret greift:"
echo "     kubectl rollout restart deployment/nocodb -n ${NAMESPACE}"
echo ""
echo "  2. CoreDNS Eintrag setzen (falls noch nicht geschehen):"
echo "     make setup-coredns"
echo ""
echo "  3. ArgoCD Application deployen:"
echo "     git add k8s/argocd/applications/nocodb.yaml"
echo "     git commit -m 'feat: add NocoDB spreadsheet UI'"
echo "     git push"
echo ""
echo "  4. NocoDB aufrufen:"
echo "     https://nocodb.homelab.local"
echo "     → Beim ersten Aufruf Admin-Account anlegen"
echo "============================================"
