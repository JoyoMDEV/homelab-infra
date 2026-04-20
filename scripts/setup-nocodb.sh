#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-nocodb.sh
#  Richtet PostgreSQL-Datenbank und Kubernetes Secret für NocoDB ein.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - PostgreSQL (CNPG) läuft: kubectl get cluster -n infrastructure
#  - Namespace 'productivity' existiert
#
#  IDEMPOTENT: Erneutes Ausführen synct DB-Passwort und Secret zusammen.
#
#  USAGE:
#    ./scripts/setup-nocodb.sh
# =============================================================================

NAMESPACE="productivity"
SECRET_NAME="nocodb-secret"
DB_HOST="homelab-pg-rw.infrastructure.svc.cluster.local"
DB_PORT="5432"
DB_NAME="nocodb"
DB_USER="nocodb"

echo ""
echo "============================================"
echo "  NocoDB – Datenbank & Secret Setup"
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

# ─── Passwort generieren ─────────────────────────────────────────────────────
echo ""
echo "==> Generiere Credentials..."
NOCODB_DB_PW=$(openssl rand -base64 24)
NOCODB_JWT_SECRET=$(openssl rand -base64 48)

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

# ALTER ROLE setzt das Passwort auch wenn der User bereits existiert → idempotent
kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
      CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${NOCODB_DB_PW}';
      RAISE NOTICE 'User ${DB_USER} erstellt.';
    ELSE
      ALTER ROLE ${DB_USER} WITH PASSWORD '${NOCODB_DB_PW}';
      RAISE NOTICE 'User ${DB_USER} existiert – Passwort aktualisiert.';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
  ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};
"
echo "    Berechtigungen gesetzt."

# ─── Kubernetes Secret anlegen (altes löschen für saubere Synchronisation) ───
echo ""
echo "==> Erstelle Kubernetes Secret '${SECRET_NAME}'..."

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "    Secret existiert – wird neu erstellt (Passwort-Sync)..."
  kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

kubectl create secret generic "${SECRET_NAME}" \
  --from-literal=db-password="${NOCODB_DB_PW}" \
  --from-literal=db-url="${NOCODB_DB_URL}" \
  --from-literal=jwt-secret="${NOCODB_JWT_SECRET}" \
  -n "${NAMESPACE}"

echo "    Secret '${SECRET_NAME}' erstellt."
echo "    Keys: db-password, db-url, jwt-secret"

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  PostgreSQL:"
echo "    Datenbank: ${DB_NAME}"
echo "    User:      ${DB_USER}"
echo "    Passwort:  ${NOCODB_DB_PW}"
echo "    → In Ansible Vault sichern: make vault-edit"
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
