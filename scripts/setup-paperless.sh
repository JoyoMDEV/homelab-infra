#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-paperless.sh
#  Richtet PostgreSQL-Datenbank ein und schreibt/merged die restlichen
#  Paperless-ngx Secrets (Redis, SMTP, OIDC) nach Vault. Läuft typischerweise
#  NACH setup-databases.sh, welches den Vault-Pfad initial mit
#  db-username/db-password/secret-key anlegt, falls er noch nicht existiert.
#  Das ExternalSecret 'paperless-secret' (Namespace productivity) übernimmt
#  von Vault aus die Pflege des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - PostgreSQL (CNPG) läuft: kubectl get cluster -n infrastructure
#  - Redis läuft: kubectl get pods -n infrastructure | grep redis
#  - Vaultwarden läuft: kubectl exec -n security vault-0 -- vault kv get
#    secret/homelab/security/vaultwarden-smtp
#  - Keycloak Client 'paperless' angelegt (siehe docs/paperless-setup.md)
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-paperless.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="productivity/paperless-secret"
NAMESPACE="productivity"

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

vault_kv_patch() {
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv patch "secret/${path}" "$@" >/dev/null
}

echo ""
echo "============================================"
echo "  Paperless-ngx – Datenbank & Vault Secret Setup"
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

SMTP_USER=$(vault_kv_get "security/vaultwarden-smtp" "SMTP_USERNAME")
SMTP_PW=$(vault_kv_get "security/vaultwarden-smtp" "SMTP_PASSWORD")
if [[ -z "${SMTP_USER}" ]] || [[ -z "${SMTP_PW}" ]]; then
  echo "    FEHLER: SMTP-Credentials nicht in Vault ('homelab/security/vaultwarden-smtp')."
  echo "    Führe zuerst aus: ./scripts/setup-vaultwarden.sh"
  exit 1
fi
echo "    SMTP Credentials (aus Vault): OK"

kubectl get namespace "${NAMESPACE}" &>/dev/null || kubectl create namespace "${NAMESPACE}"
echo "    Namespace '${NAMESPACE}': OK"

# ─── Warten bis PostgreSQL bereit ist ────────────────────────────────────────
echo ""
echo "==> Warte bis PostgreSQL bereit ist..."
kubectl wait --for=condition=Ready pod/homelab-pg-1 -n infrastructure --timeout=120s
echo "    PostgreSQL bereit."

# ─── Datenbank und User anlegen (Passwort aus Vault wiederverwenden) ────────
echo ""
echo "==> Lege PostgreSQL Datenbank und User an..."

PAPERLESS_DB_PW=$(vault_kv_get "${VAULT_PATH}" "db-password")
if [[ -n "${PAPERLESS_DB_PW}" ]]; then
  echo "    Bestehendes DB-Passwort aus Vault wird wiederverwendet."
else
  echo "    Kein bestehendes Passwort - generiere neues."
  PAPERLESS_DB_PW=$(openssl rand -base64 24)
fi

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
      ALTER ROLE paperless WITH PASSWORD '${PAPERLESS_DB_PW}';
      RAISE NOTICE 'User paperless existiert – Passwort synchronisiert.';
    END IF;
  END \$\$;
  GRANT ALL PRIVILEGES ON DATABASE paperless TO paperless;
  ALTER DATABASE paperless OWNER TO paperless;
"
echo "    Berechtigungen gesetzt."

# ─── Redis Passwort lesen und URL-encoden ─────────────────────────────────────
echo ""
echo "==> Lese Redis Passwort und baue Redis URL..."
REDIS_PW=$(vault_kv_get "infrastructure/redis-secret" "redis-password")
if [[ -z "${REDIS_PW}" ]]; then
  echo "    FEHLER: Redis-Passwort nicht in Vault ('homelab/infrastructure/redis-secret')."
  echo "    Führe zuerst aus: ./scripts/migrate-secrets-to-vault.sh"
  exit 1
fi

REDIS_PW_ENCODED=$(python3 -c \
  "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip(), safe=''))" \
  <<< "${REDIS_PW}")

REDIS_URL="redis://:${REDIS_PW_ENCODED}@redis-master.infrastructure.svc.cluster.local:6379"
echo "    Redis URL gebaut."

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
  echo "      kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \\"
  echo "        VAULT_TOKEN=\$VAULT_TOKEN vault kv patch secret/homelab/${VAULT_PATH} \\"
  echo "        oidc-client-secret=<secret>"
  OIDC_SECRET="REPLACE_AFTER_KEYCLOAK_SETUP"
fi

# ─── Nach Vault schreiben (patch falls Pfad existiert, sonst voller put) ─────
echo ""
echo "==> Schreibe Credentials nach Vault ('homelab/${VAULT_PATH}')..."

SECRET_KEY=$(vault_kv_get "${VAULT_PATH}" "secret-key")
[[ -z "${SECRET_KEY}" ]] && SECRET_KEY=$(openssl rand -base64 48)

if vault_kv_path_exists "${VAULT_PATH}"; then
  echo "    Vault-Pfad existiert bereits – merge (db-username/db-password/secret-key bleiben erhalten)."
  vault_kv_patch "${VAULT_PATH}" \
    "oidc-client-secret=${OIDC_SECRET}" \
    "redis-password=${REDIS_PW}" \
    "redis-url=${REDIS_URL}" \
    "smtp-username=${SMTP_USER}" \
    "smtp-password=${SMTP_PW}"
  echo "    Gemerged."
else
  vault_kv_put "${VAULT_PATH}" \
    "db-username=paperless" \
    "db-password=${PAPERLESS_DB_PW}" \
    "redis-password=${REDIS_PW}" \
    "redis-url=${REDIS_URL}" \
    "secret-key=${SECRET_KEY}" \
    "oidc-client-secret=${OIDC_SECRET}" \
    "smtp-username=${SMTP_USER}" \
    "smtp-password=${SMTP_PW}"
  echo "    Vollständig neu geschrieben."
fi

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret paperless-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  PostgreSQL:"
echo "    Datenbank: paperless"
echo "    User:      paperless"
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
