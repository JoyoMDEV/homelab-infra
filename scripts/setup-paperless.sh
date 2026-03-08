#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-paperless.sh
#  Richtet PostgreSQL-Datenbank und Kubernetes Secrets für Paperless-ngx ein.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - PostgreSQL (CNPG) läuft: kubectl get cluster -n infrastructure
#  - Redis läuft: kubectl get pods -n infrastructure | grep redis
#  - Vaultwarden läuft: kubectl get secret vaultwarden -n security
#  - Keycloak Client 'paperless' angelegt (siehe docs/paperless-setup.md)
#
#  USAGE:
#    ./scripts/setup-paperless.sh
# =============================================================================

NAMESPACE="productivity"
SECRET_NAME="paperless-secret"

echo ""
echo "============================================"
echo "  Paperless-ngx – Datenbank & Secrets Setup"
echo "============================================"
echo ""

# ─── Voraussetzungen prüfen ───────────────────────────────────────────────────
echo "==> Prüfe Voraussetzungen..."

if ! kubectl get pod homelab-pg-1 -n infrastructure &>/dev/null; then
  echo "    FEHLER: PostgreSQL Pod 'homelab-pg-1' nicht gefunden."
  exit 1
fi
echo "    PostgreSQL: OK"

if ! kubectl get svc redis-master -n infrastructure &>/dev/null; then
  echo "    FEHLER: Redis Service nicht gefunden."
  exit 1
fi
echo "    Redis: OK"

if ! kubectl get secret vaultwarden -n security &>/dev/null; then
  echo "    FEHLER: Secret 'vaultwarden' in Namespace 'security' nicht gefunden."
  echo "    SMTP-Credentials können nicht gelesen werden."
  exit 1
fi
echo "    Vaultwarden Secret: OK"

kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"
echo "    Namespace '${NAMESPACE}': OK"

# ─── Warten bis PostgreSQL bereit ist ────────────────────────────────────────
echo ""
echo "==> Warte bis PostgreSQL bereit ist..."
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s
echo "    PostgreSQL bereit."

# ─── Datenbank und User anlegen ──────────────────────────────────────────────
echo ""
echo "==> Lege PostgreSQL Datenbank und User an..."

PAPERLESS_DB_PW=$(openssl rand -base64 24)

kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c \
  "CREATE DATABASE paperless;" 2>/dev/null \
  && echo "    Datenbank 'paperless' erstellt." \
  || echo "    Datenbank 'paperless' existiert bereits."

kubectl exec homelab-pg-1 -n infrastructure -c postgres -- psql -U postgres -c "
  DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'paperless') THEN
      CREATE ROLE paperless WITH LOGIN PASSWORD '${PAPERLESS_DB_PW}';
      RAISE NOTICE 'User paperless erstellt.';
    ELSE
      RAISE NOTICE 'User paperless existiert bereits.';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE paperless TO paperless;
  ALTER DATABASE paperless OWNER TO paperless;
"
echo "    Berechtigungen gesetzt."

# ─── Redis Passwort lesen und URL-encoden ─────────────────────────────────────
echo ""
echo "==> Lese Redis Passwort und baue Redis URL..."
REDIS_PW=$(kubectl get secret redis-secret -n infrastructure \
  -o jsonpath='{.data.redis-password}' | base64 -d)

# URL-encode: Sonderzeichen wie / → %2F, sonst parst Python die URL falsch
REDIS_PW_ENCODED=$(python3 -c \
  "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))" \
  <<< "${REDIS_PW}")

REDIS_URL="redis://:${REDIS_PW_ENCODED}@redis-master.infrastructure.svc.cluster.local:6379"
echo "    Redis URL gebaut."

# ─── SMTP Credentials aus Vaultwarden Secret lesen ───────────────────────────
echo ""
echo "==> Lese SMTP Credentials aus vaultwarden-Secret..."
SMTP_USER=$(kubectl get secret vaultwarden -n security \
  -o jsonpath='{.data.SMTP_USERNAME}' | base64 -d)
SMTP_PW=$(kubectl get secret vaultwarden -n security \
  -o jsonpath='{.data.SMTP_PASSWORD}' | base64 -d)
echo "    SMTP User: ${SMTP_USER}"
echo "    SMTP Passwort: gelesen."

# ─── Keycloak OIDC Client Secret abfragen ────────────────────────────────────
echo ""
echo "==> Keycloak OIDC Client Secret"
echo "    Keycloak → Realm homelab → Clients → paperless → Credentials → Client secret"
echo ""
read -rsp "    Client Secret eingeben (wird nicht angezeigt): " OIDC_SECRET
echo ""

if [[ -z "${OIDC_SECRET}" ]]; then
  echo "    HINWEIS: Kein OIDC Secret angegeben – wird als Placeholder gesetzt."
  echo "    Später aktualisieren mit:"
  echo "      kubectl patch secret ${SECRET_NAME} -n ${NAMESPACE} \\"
  echo "        --type merge \\"
  echo "        -p '{\"stringData\":{\"oidc-client-secret\":\"<secret>\"}}'"
  OIDC_SECRET="REPLACE_AFTER_KEYCLOAK_SETUP"
fi

# ─── Secret anlegen oder aktualisieren ───────────────────────────────────────
echo ""
echo "==> Erstelle Kubernetes Secret '${SECRET_NAME}'..."

SECRET_KEY=$(openssl rand -base64 48)

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "    Secret existiert bereits – wird aktualisiert (DB-Passwort bleibt erhalten)."

  kubectl patch secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    --type merge \
    -p "{\"stringData\":{
      \"oidc-client-secret\":\"${OIDC_SECRET}\",
      \"redis-password\":\"${REDIS_PW}\",
      \"redis-url\":\"${REDIS_URL}\",
      \"smtp-username\":\"${SMTP_USER}\",
      \"smtp-password\":\"${SMTP_PW}\"
    }}"
  echo "    Secret aktualisiert."
else
  kubectl create secret generic "${SECRET_NAME}" \
    --from-literal=db-username="paperless" \
    --from-literal=db-password="${PAPERLESS_DB_PW}" \
    --from-literal=redis-password="${REDIS_PW}" \
    --from-literal=redis-url="${REDIS_URL}" \
    --from-literal=secret-key="${SECRET_KEY}" \
    --from-literal=oidc-client-secret="${OIDC_SECRET}" \
    --from-literal=smtp-username="${SMTP_USER}" \
    --from-literal=smtp-password="${SMTP_PW}" \
    -n "${NAMESPACE}"
  echo "    Secret erstellt."
fi

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  PostgreSQL:"
echo "    Datenbank: paperless"
echo "    User:      paperless"
if [[ -n "${PAPERLESS_DB_PW:-}" ]]; then
  echo "    Passwort:  ${PAPERLESS_DB_PW}"
  echo "    → In Ansible Vault sichern!"
fi
echo ""
echo "  SMTP:"
echo "    User: ${SMTP_USER}"
echo "    Host: mail.your-server.de:587"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. Keycloak Client anlegen (falls noch nicht geschehen):"
echo "     → docs/paperless-setup.md"
echo ""
echo "  2. CoreDNS Eintrag setzen:"
echo "     make setup-coredns"
echo ""
echo "  3. ArgoCD Application deployen:"
echo "     git add k8s/argocd/applications/paperless.yaml"
echo "     git commit -m 'feat: add Paperless-ngx'"
echo "     git push"
echo ""
echo "  4. Status prüfen:"
echo "     kubectl get pods -n productivity | grep paperless"
echo ""
echo "  5. Paperless aufrufen:"
echo "     https://paperless.homelab.local"
echo "============================================"
