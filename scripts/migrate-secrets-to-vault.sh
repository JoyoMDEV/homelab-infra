#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
#  migrate-secrets-to-vault.sh
#
#  One-time migration: seeds Vault with the CURRENT live values of secrets
#  that were created directly by scripts/setup-*.sh (bypassing Vault) instead
#  of being regenerated. This makes each secret's ExternalSecret reconcile as
#  a no-op going forward, instead of failing (path doesn't exist) or - once
#  seeded with a *different* value - silently rotating credentials the
#  running app doesn't know about.
#
#  For every (namespace, k8s-secret, vault-path) triple below:
#    1. Read every key's CURRENT live value from the Kubernetes Secret.
#    2. Read the CURRENT value already in Vault at that path/property, if any.
#    3. Compare. If Vault already has a *different* value for any key, that
#       whole path is SKIPPED (reported as a conflict) rather than silently
#       overwritten - conflicts need manual review.
#    4. Otherwise (Vault empty, or already matches), write the live values to
#       Vault. This is idempotent - safe to re-run.
#
#  Out of scope (bootstrap secrets, not operator-provided values, created
#  before Vault/ESO exist - see bootstrap-certmanager.sh/bootstrap-argocd.sh):
#    homelab-ca-keypair, homelab-wildcard-tls
#
#  Out of scope (no ArgoCD Application deploys to the 'dashboard' namespace
#  currently - confirm with the repo owner before migrating):
#    homarr-secret, db-encryption
#
#  VORAUSSETZUNGEN:
#  - KUBECONFIG zeigt auf den Cluster (z.B. export KUBECONFIG=./kubeconfig)
#  - VAULT_TOKEN als Env-Var gesetzt (root oder ein Token mit admin-Policy)
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/migrate-secrets-to-vault.sh
# =============================================================================

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

VAULT_NS="security"
VAULT_POD="vault-0"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# namespace|k8s-secret-name|vault-path|k8sKey1:vaultProp1,k8sKey2:vaultProp2,...
ENTRIES=(
  "infrastructure|redis-secret|infrastructure/redis-secret|redis-password:redis-password"
  "automation|renovate-secret|automation/renovate-secret|RENOVATE_TOKEN:RENOVATE_TOKEN"
  "backup|velero-secret|backup/velero-secret|cloud:cloud"
  "productivity|nextcloud-secret|productivity/nextcloud-secret|nextcloud-username:nextcloud-username,nextcloud-password:nextcloud-password,db-username:db-username,db-password:db-password,redis-password:redis-password,storage-box-password:storage-box-password,oidc-client-secret:oidc-client-secret"
  "productivity|paperless-secret|productivity/paperless-secret|db-username:db-username,db-password:db-password,redis-password:redis-password,redis-url:redis-url,secret-key:secret-key,oidc-client-secret:oidc-client-secret,smtp-username:smtp-username,smtp-password:smtp-password"
  "auth|keycloak-secret|auth/keycloak-secret|admin-password:admin-password"
  "auth|keycloak-db-secret|auth/keycloak-db-secret|password:password"
  "gitlab|gitlab-secret|gitlab/gitlab-secret|db-password:db-password,redis-password:redis-password,oidc-client-secret:oidc-client-secret"
  "gitlab|gitlab-rails-secrets|gitlab/rails-secrets|secret_key_base:secret-key-base,db_key_base:db-key-base,otp_key_base:otp-key-base,ci_job_token_signing_key:ci-job-token-signing-key"
  "gitlab|gitlab-runner-secret|gitlab/runner-secret|runner-registration-token:runner-registration-token,runner-token:runner-token"
  "infrastructure|minio-secret|infrastructure/minio|rootUser:rootUser,rootPassword:rootPassword,storage-box-password:storage-box-password"
  "monitoring|grafana-keycloak-secret|monitoring/grafana-keycloak-secret|GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET,ALERTMANAGER_DISCORD_WEBHOOK_URL:ALERTMANAGER_DISCORD_WEBHOOK_URL"
  "productivity|nocodb-secret|productivity/nocodb-secret|db-password:db-password,db-url:db-url,jwt-secret:jwt-secret"
  "security|vaultwarden-secret|security/vaultwarden-secret|admin-token:admin-token"
  "security|vaultwarden|security/vaultwarden-smtp|SMTP_USERNAME:SMTP_USERNAME,SMTP_PASSWORD:SMTP_PASSWORD"
  "infrastructure|restic-ssh-key|infrastructure/restic-ssh|ssh-privatekey:ssh-privatekey,ssh-publickey:ssh-publickey,storage-box-host:storage-box-host,storage-box-user:storage-box-user,storage-box-port:storage-box-port"
)

k8s_get() {
  # k8s_get <namespace> <secret> <key>
  kubectl get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}

vault_get() {
  # vault_get <path> <field>
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv get -field="$2" "secret/$1" 2>/dev/null || true
}

vault_put() {
  # vault_put <path> "key1=val1" "key2=val2" ...
  local path="$1"; shift
  kubectl exec -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" \
    vault kv put "secret/${path}" "$@" >/dev/null
}

TOTAL=0
SEEDED=0
UNCHANGED=0
CONFLICTS=0
MISSING=0

for entry in "${ENTRIES[@]}"; do
  IFS='|' read -r ns secret vpath pairs <<<"$entry"
  TOTAL=$((TOTAL + 1))

  echo -e "${CYAN}=== ${secret} (namespace: ${ns}, vault path: homelab/${vpath}) ===${NC}"

  if ! kubectl get secret "$secret" -n "$ns" &>/dev/null; then
    echo -e "  ${YELLOW}SKIP - Kubernetes Secret existiert nicht live, nichts zu migrieren.${NC}"
    MISSING=$((MISSING + 1))
    echo ""
    continue
  fi

  declare -a put_args=()
  has_conflict=0

  IFS=',' read -ra kv_pairs <<<"$pairs"
  for pair in "${kv_pairs[@]}"; do
    k8s_key="${pair%%:*}"
    vault_prop="${pair##*:}"

    live_val=$(k8s_get "$ns" "$secret" "$k8s_key")
    if [[ -z "$live_val" ]]; then
      echo -e "  ${YELLOW}${k8s_key}: leer/nicht im Secret vorhanden, überspringe Key.${NC}"
      continue
    fi

    vault_val=$(vault_get "homelab/${vpath}" "$vault_prop")

    if [[ -z "$vault_val" ]]; then
      echo -e "  ${GREEN}${k8s_key}: wird nach Vault geschrieben (bisher leer).${NC}"
      put_args+=("${vault_prop}=${live_val}")
    elif [[ "$vault_val" == "$live_val" ]]; then
      echo -e "  ${GREEN}${k8s_key}: stimmt bereits mit Vault überein.${NC}"
      put_args+=("${vault_prop}=${live_val}")
    else
      echo -e "  ${RED}${k8s_key}: KONFLIKT - Vault-Wert weicht vom Live-Secret ab, wird NICHT überschrieben.${NC}"
      has_conflict=1
    fi
  done

  if [[ $has_conflict -eq 1 ]]; then
    echo -e "  ${RED}=> Pfad wird NICHT geschrieben (mindestens ein Konflikt). Manuell prüfen:${NC}"
    echo -e "     kubectl exec -n ${VAULT_NS} ${VAULT_POD} -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=\$VAULT_TOKEN vault kv get secret/homelab/${vpath}"
    CONFLICTS=$((CONFLICTS + 1))
  elif [[ ${#put_args[@]} -eq 0 ]]; then
    echo -e "  ${YELLOW}=> Keine Keys zu schreiben (alle leer).${NC}"
  else
    vault_put "${vpath}" "${put_args[@]}"
    echo -e "  ${GREEN}=> Vault-Pfad geschrieben/bestätigt.${NC}"
    SEEDED=$((SEEDED + 1))
  fi

  unset put_args
  echo ""
done

echo "============================================"
echo "  Migration abgeschlossen"
echo "============================================"
echo "  Verarbeitet:        ${TOTAL}"
echo "  Vault geschrieben:  ${SEEDED}"
echo "  Fehlend im Cluster: ${MISSING}"
echo "  Konflikte:          ${CONFLICTS}"
echo ""
if [[ $CONFLICTS -gt 0 ]]; then
  echo "  ⚠ ${CONFLICTS} Pfad(e) mit Konflikten wurden übersprungen - siehe oben."
fi
echo "  Nächster Schritt: ExternalSecrets zum sofortigen Re-Sync anstoßen"
echo "  (sonst warten sie bis zu ihrem nächsten refreshInterval):"
echo "    kubectl get externalsecret -A -o json | \\"
echo "      jq -r '.items[] | \"\\(.metadata.namespace) \\(.metadata.name)\"' | \\"
echo "      while read -r ns name; do"
echo "        kubectl annotate externalsecret \"\$name\" -n \"\$ns\" \\"
echo "          force-sync=\$(date +%s) --overwrite"
echo "      done"
