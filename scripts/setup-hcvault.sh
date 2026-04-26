#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-vault.sh
#  Initialisiert HashiCorp Vault und konfiguriert alle Auth Methods.
#
#  ABLAUF:
#  1. Warten bis Vault Pod läuft
#  2. Vault initialisieren (Root Token + Unseal Keys generieren)
#  3. Vault unsealen
#  4. Audit Log aktivieren
#  5. Keycloak OIDC Auth Method konfigurieren
#  6. Kubernetes Auth Method aktivieren
#  7. Policies anlegen (admin, reader)
#  8. KV Secrets Engine aktivieren (kv-v2)
#  9. Erstes Test-Secret anlegen
#
#  VORAUSSETZUNGEN:
#  - Vault Pod läuft: kubectl get pods -n security | grep vault
#  - Keycloak läuft und Realm homelab existiert
#  - homelab-ca Secret im security Namespace
#
#  IDEMPOTENT:
#  Bereits initialisiertes Vault wird erkannt. Script kann erneut
#  ausgeführt werden um Auth Methods zu aktualisieren.
#
#  USAGE:
#    ./scripts/setup-vault.sh
#    ./scripts/setup-vault.sh --skip-init   # Nur Auth Methods konfigurieren
# =============================================================================

NAMESPACE="security"
VAULT_POD=""
VAULT_ADDR="http://127.0.0.1:8200"
SKIP_INIT=false

# ─── Flags ────────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case $arg in
    --skip-init) SKIP_INIT=true ;;
    --help)
      echo "Usage: $0 [--skip-init]"
      echo "  --skip-init  Initialisierung überspringen (Vault bereits initialisiert)"
      exit 0
      ;;
  esac
done

# ─── Farben ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $*"; }
success() { echo -e "${GREEN}    ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}    ⚠${NC} $*"; }
error()   { echo -e "${RED}    ✗${NC} $*"; exit 1; }

# ─── Helper: vault exec ──────────────────────────────────────────────────────
vault_exec() {
  kubectl exec -n "${NAMESPACE}" "${VAULT_POD}" \
    -- env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${ROOT_TOKEN:-}" vault "$@"
}

vault_exec_noauth() {
  kubectl exec -n "${NAMESPACE}" "${VAULT_POD}" \
    -- env VAULT_ADDR="${VAULT_ADDR}" vault "$@"
}

echo ""
echo "============================================"
echo "  HashiCorp Vault – Bootstrap Setup"
echo "============================================"
echo ""

# ─── Step 1: Warten bis Vault Pod läuft ──────────────────────────────────────
info "Schritt 1/9: Vault Pod ermitteln..."

for i in $(seq 1 30); do
  VAULT_POD=$(kubectl get pods -n "${NAMESPACE}" \
    -l app.kubernetes.io/name=vault \
    -l component=server \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -n "${VAULT_POD}" ]]; then
    success "Vault Pod: ${VAULT_POD}"
    break
  fi

  if [[ $i -eq 30 ]]; then
    error "Vault Pod nicht gefunden nach 5 Minuten."
  fi

  echo "    Warte auf Vault Pod... (${i}/30)"
  sleep 10
done

# ─── Step 2: Vault initialisieren ─────────────────────────────────────────────
info "Schritt 2/9: Vault initialisieren..."

INIT_STATUS=$(vault_exec_noauth status -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('initialized','false'))" \
  2>/dev/null || echo "false")

if [[ "${SKIP_INIT}" == "true" ]] || [[ "${INIT_STATUS}" == "True" ]]; then
  warn "Vault bereits initialisiert – Initialisierung wird übersprungen."

  echo ""
  read -rsp "    Root Token eingeben: " ROOT_TOKEN
  echo ""

  if [[ -z "${ROOT_TOKEN}" ]]; then
    error "Root Token darf nicht leer sein."
  fi

  # Vault unsealen falls nötig
  SEALED=$(vault_exec_noauth status -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sealed','true'))" \
    2>/dev/null || echo "true")

  if [[ "${SEALED}" == "True" ]]; then
    warn "Vault ist sealed – bitte Unseal Keys eingeben."
    echo ""
    echo "    Tipp: Keys aus Ansible Vault lesen:"
    echo "      make vault-view"
    echo ""
    for i in 1 2 3; do
      read -rsp "    Unseal Key ${i}/3: " UNSEAL_KEY
      echo ""
      vault_exec_noauth operator unseal "${UNSEAL_KEY}" > /dev/null
    done
    success "Vault unsealed."
  else
    success "Vault bereits unsealed."
  fi
else
  info "  Initialisiere Vault (5 Key Shares, Threshold 3)..."

  INIT_OUTPUT=$(vault_exec_noauth operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json 2>/dev/null)

  # Keys extrahieren
  UNSEAL_KEY_1=$(echo "${INIT_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
  UNSEAL_KEY_2=$(echo "${INIT_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][1])")
  UNSEAL_KEY_3=$(echo "${INIT_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][2])")
  UNSEAL_KEY_4=$(echo "${INIT_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][3])")
  UNSEAL_KEY_5=$(echo "${INIT_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][4])")
  ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")

  echo ""
  echo "  ┌──────────────────────────────────────────────────────────────┐"
  echo "  │  KRITISCH: Vault Init Credentials – JETZT SICHERN!           │"
  echo "  │                                                              │"
  echo "  │  Root Token:    ${ROOT_TOKEN}"
  echo "  │                                                              │"
  echo "  │  Unseal Key 1:  ${UNSEAL_KEY_1}"
  echo "  │  Unseal Key 2:  ${UNSEAL_KEY_2}"
  echo "  │  Unseal Key 3:  ${UNSEAL_KEY_3}"
  echo "  │  Unseal Key 4:  ${UNSEAL_KEY_4}"
  echo "  │  Unseal Key 5:  ${UNSEAL_KEY_5}"
  echo "  │                                                              │"
  echo "  │  → In Ansible Vault sichern: make vault-edit                 │"
  echo "  │  vault_vault_root_token: \"...\"                              │"
  echo "  │  vault_vault_unseal_keys:                                    │"
  echo "  │    - \"...\"                                                  │"
  echo "  └──────────────────────────────────────────────────────────────┘"
  echo ""
  read -rsp "  Enter drücken wenn Keys gesichert wurden..." _
  echo ""

  # Vault unsealen (3 von 5 Keys nötig)
  info "  Vault unsealen..."
  vault_exec_noauth operator unseal "${UNSEAL_KEY_1}" > /dev/null
  vault_exec_noauth operator unseal "${UNSEAL_KEY_2}" > /dev/null
  vault_exec_noauth operator unseal "${UNSEAL_KEY_3}" > /dev/null
  success "Vault initialisiert und unsealed."
fi

# ─── Step 3: Verbindung verifizieren ─────────────────────────────────────────
info "Schritt 3/9: Verbindung verifizieren..."

VAULT_STATUS=$(vault_exec status -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sealed','?'))" \
  2>/dev/null || echo "error")

if [[ "${VAULT_STATUS}" == "False" ]]; then
  success "Vault ist erreichbar und unsealed."
else
  error "Vault ist sealed oder nicht erreichbar (sealed=${VAULT_STATUS}). Abbruch."
fi

# ─── Step 4: Audit Log aktivieren ────────────────────────────────────────────
info "Schritt 4/9: Audit Log aktivieren..."

AUDIT_EXISTS=$(vault_exec audit list -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('file/' in d)" \
  2>/dev/null || echo "False")

if [[ "${AUDIT_EXISTS}" == "True" ]]; then
  success "Audit Log bereits aktiv."
else
  vault_exec audit enable file file_path=/vault/data/audit.log 2>/dev/null || true
  success "Audit Log aktiviert (/vault/data/audit.log)."
fi

# ─── Step 5: KV Secrets Engine aktivieren ────────────────────────────────────
info "Schritt 5/9: KV Secrets Engine (v2) aktivieren..."

KV_EXISTS=$(vault_exec secrets list -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('secret/' in d)" \
  2>/dev/null || echo "False")

if [[ "${KV_EXISTS}" == "True" ]]; then
  success "KV Engine bereits aktiv unter 'secret/'."
else
  vault_exec secrets enable -path=secret kv-v2 2>/dev/null || true
  success "KV Engine aktiviert (kv-v2 unter 'secret/')."
fi

# ─── Step 6: Policies anlegen ────────────────────────────────────────────────
info "Schritt 6/9: Policies anlegen..."

# Heredocs funktionieren nicht über kubectl exec (stdin wird nicht weitergeleitet).
# Lösung: Policy-Inhalte per kubectl cp als Dateien in den Pod schreiben,
# dann vault policy write <name> /tmp/policy.hcl aufrufen.

# Helper: Policy-Datei in den Pod schreiben und anwenden
write_policy() {
  local NAME="$1"
  local CONTENT="$2"
  local TMP_FILE="/tmp/vault-policy-${NAME}.hcl"

  # Lokal schreiben
  echo "${CONTENT}" > "${TMP_FILE}"

  # In den Pod kopieren
  kubectl cp "${TMP_FILE}" "${NAMESPACE}/${VAULT_POD}:/tmp/policy-${NAME}.hcl" 2>/dev/null

  # Policy anwenden
  kubectl exec -n "${NAMESPACE}" "${VAULT_POD}" \
    -- env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${ROOT_TOKEN}" \
    vault policy write "${NAME}" "/tmp/policy-${NAME}.hcl"

  # Aufräumen
  rm -f "${TMP_FILE}"
}

# Admin Policy: Vollzugriff auf alles
write_policy "admin" 'path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}'
success "Policy 'admin' angelegt."

# Reader Policy: Lesezugriff auf secret/ (für ESO und Pods)
write_policy "reader" 'path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}'
success "Policy 'reader' angelegt."

# Namespace-spezifische Policies
for NS in gitlab auth productivity monitoring security automation dashboard infrastructure; do
  write_policy "ns-${NS}" "path \"secret/data/homelab/${NS}/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/homelab/${NS}/*\" {
  capabilities = [\"list\", \"read\"]
}
path \"auth/token/renew-self\" {
  capabilities = [\"update\"]
}"
  success "Policy 'ns-${NS}' angelegt."
done

# ─── Step 7: Kubernetes Auth Method aktivieren ───────────────────────────────
info "Schritt 7/9: Kubernetes Auth Method aktivieren..."

K8S_AUTH_EXISTS=$(vault_exec auth list -format=json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('kubernetes/' in d)" \
  2>/dev/null || echo "False")

if [[ "${K8S_AUTH_EXISTS}" == "True" ]]; then
  success "Kubernetes Auth Method bereits aktiv."
else
  vault_exec auth enable kubernetes 2>/dev/null || true
  success "Kubernetes Auth Method aktiviert."
fi

# Kubernetes Auth konfigurieren
# Vault liest den eigenen ServiceAccount Token für die K8s API-Verifikation
K8S_HOST=$(kubectl config view --raw \
  -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "https://kubernetes.default.svc")

vault_exec auth configure kubernetes \
  -kubernetes-host="${K8S_HOST}" \
  -kubernetes-ca-cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  -token-reviewer-jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  2>/dev/null || \
vault_exec write auth/kubernetes/config \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

success "Kubernetes Auth konfiguriert."

# Rollen für Namespaces anlegen
# ServiceAccounts in diesen Namespaces können sich mit 'ns-<namespace>' Policy authentifizieren
for NS in gitlab auth productivity monitoring security automation dashboard infrastructure; do
  vault_exec write "auth/kubernetes/role/${NS}" \
    bound_service_account_names="*" \
    bound_service_account_namespaces="${NS}" \
    policies="ns-${NS},reader" \
    ttl=1h \
    2>/dev/null || true
  success "Kubernetes Role '${NS}' angelegt."
done

# Spezielle Rolle für External Secrets Operator
vault_exec write auth/kubernetes/role/external-secrets \
  bound_service_account_names="external-secrets" \
  bound_service_account_namespaces="external-secrets" \
  policies="reader" \
  ttl=1h \
  2>/dev/null || true
success "Kubernetes Role 'external-secrets' angelegt."

# ─── Step 8: Keycloak OIDC Auth konfigurieren ────────────────────────────────
info "Schritt 8/9: Keycloak OIDC Auth Method konfigurieren..."
echo ""
echo "    Voraussetzung: Keycloak Client 'vault' anlegen"
echo "    → https://auth.homelab.local → Realm homelab → Clients → Create"
echo "    → Client ID: vault"
echo "    → Client authentication: ON"
echo "    → Valid redirect URIs:"
echo "      https://hcvault.homelab.local/ui/vault/auth/oidc/oidc/callback"
echo "      https://hcvault.homelab.local/oidc/callback"
echo "    → Web origins: https://hcvault.homelab.local"
echo ""

read -rsp "    Keycloak Client Secret für 'vault' (leer = überspringen): " OIDC_SECRET
echo ""

if [[ -n "${OIDC_SECRET}" ]]; then
  OIDC_AUTH_EXISTS=$(vault_exec auth list -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('oidc/' in d)" \
    2>/dev/null || echo "False")

  if [[ "${OIDC_AUTH_EXISTS}" == "False" ]]; then
    vault_exec auth enable oidc 2>/dev/null || true
  fi

  vault_exec write auth/oidc/config \
    oidc_discovery_url="https://auth.homelab.local/realms/homelab" \
    oidc_client_id="vault" \
    oidc_client_secret="${OIDC_SECRET}" \
    default_role="homelab-user" \
    oidc_discovery_ca_pem=@/usr/local/share/ca-certificates/homelab-ca.crt

  # Default Role: alle eingeloggten Keycloak-User → reader
  vault_exec write auth/oidc/role/homelab-user \
    bound_audiences="vault" \
    allowed_redirect_uris="https://hcvault.homelab.local/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="https://hcvault.homelab.local/oidc/callback" \
    user_claim="preferred_username" \
    groups_claim="groups" \
    policies="reader" \
    ttl=8h

  # Admin Role: Keycloak-Gruppe homelab-admins → admin Policy
  # bound_claims muss als JSON-Datei übergeben werden (vault write akzeptiert
  # keinen JSON-String als Parameter, sondern erwartet @datei.json Syntax)
  cat > /tmp/vault-admin-role.json <<JSONEOF
{
  "bound_audiences": "vault",
  "allowed_redirect_uris": [
    "https://hcvault.homelab.local/ui/vault/auth/oidc/oidc/callback",
    "https://hcvault.homelab.local/oidc/callback"
  ],
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "bound_claims": {"groups": ["homelab-admins"]},
  "token_policies": ["admin"],
  "token_ttl": "8h"
}
JSONEOF
  kubectl cp /tmp/vault-admin-role.json \
    "${NAMESPACE}/${VAULT_POD}:/tmp/vault-admin-role.json" 2>/dev/null
  kubectl exec -n "${NAMESPACE}" "${VAULT_POD}" \
    -- env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${ROOT_TOKEN}" \
    vault write auth/oidc/role/homelab-admin @/tmp/vault-admin-role.json
  rm -f /tmp/vault-admin-role.json

  # External Groups für Keycloak-Gruppen-Mapping
  OIDC_ACCESSOR=$(vault_exec auth list -format=json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('oidc/','').get('accessor','') if isinstance(d.get('oidc/',''), dict) else '')" \
    2>/dev/null || echo "")

  if [[ -n "${OIDC_ACCESSOR}" ]]; then
    vault_exec write identity/group \
      name="homelab-admins" \
      type="external" \
      policies="admin" \
      2>/dev/null || true

    GROUP_ID=$(vault_exec read -format=json identity/group/name/homelab-admins \
      2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])" \
      2>/dev/null || echo "")

    if [[ -n "${GROUP_ID}" ]]; then
      vault_exec write "identity/group-alias" \
        name="homelab-admins" \
        mount_accessor="${OIDC_ACCESSOR}" \
        canonical_id="${GROUP_ID}" \
        2>/dev/null || true
      success "Keycloak-Gruppe 'homelab-admins' → Vault Admin Policy gemappt."
    fi
  fi

  success "Keycloak OIDC Auth konfiguriert."
else
  warn "OIDC übersprungen. Später ausführen mit: $0 --skip-init"
fi

# ─── Step 9: Ersten Secret anlegen (Demo) ────────────────────────────────────
info "Schritt 9/9: Demo-Secret anlegen..."

vault_exec kv put secret/homelab/test/demo \
  hello="world" \
  setup_by="setup-vault.sh" \
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  2>/dev/null || true

success "Demo-Secret angelegt unter 'secret/homelab/test/demo'."

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Vault Bootstrap abgeschlossen!"
echo ""
echo "  URL:          https://hcvault.homelab.local"
echo "  Auth:         OIDC (Keycloak) + Kubernetes ServiceAccount"
echo "  Secrets:      secret/homelab/<namespace>/<name>"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. Keycloak Client 'vault' anlegen (falls nicht geschehen):"
echo "     → docs/vault-setup.md"
echo ""
echo "  2. External Secrets Operator deployen:"
echo "     git add k8s/argocd/applications/external-secrets.yaml"
echo "     git commit -m 'feat: add External Secrets Operator'"
echo "     git push"
echo ""
echo "  3. ClusterSecretStore anlegen:"
echo "     kubectl apply -f k8s/security/vault-cluster-secret-store.yaml"
echo ""
echo "  4. Ersten ExternalSecret testen:"
echo "     kubectl apply -f k8s/security/vault-demo-external-secret.yaml"
echo ""
echo "  5. Vollständiges Runbook:"
echo "     docs/vault-setup.md"
echo "============================================"
