#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-restic-ssh.sh
#  Generiert ein SSH Key-Paar für den Restic Backup CronJob, hinterlegt den
#  Public Key auf der Hetzner Storage Box, und schreibt Key-Paar + Storage
#  Box Verbindungsdaten nach Vault. Das ExternalSecret 'restic-ssh-key'
#  (Namespace infrastructure) übernimmt von dort die Pflege des Kubernetes
#  Secrets.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - ssh-keygen, curl verfügbar
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  IDEMPOTENT: Wenn in Vault bereits ein Key-Paar hinterlegt ist, wird nichts
#  neu generiert (ein neuer Key würde den alten Public Key auf der Storage
#  Box nicht ungültig machen, aber Restic könnte den alten Private Key aus
#  dem laufenden Secret nicht mehr nutzen sobald ESO synct). Für ein
#  bewusstes Rotieren: ./scripts/setup-restic-ssh.sh --force
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-restic-ssh.sh [--force]
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="infrastructure/restic-ssh"
NAMESPACE="infrastructure"
SFTP_PORT="23"
KEY_FILE="/tmp/restic_storage_box"
FORCE=0

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=1
done

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
echo "  Restic SSH Key Setup"
echo "============================================"
echo ""

if [[ ${FORCE} -eq 0 ]] && [[ -n "$(vault_kv_get "${VAULT_PATH}" "ssh-privatekey")" ]]; then
  echo "==> Vault-Pfad 'homelab/${VAULT_PATH}' hat bereits ein Key-Paar."
  echo "    Nichts zu tun. Zum bewussten Rotieren: $0 --force"
  exit 0
fi

# ─── Storage Box Verbindungsdaten abfragen ───────────────────────────────────
echo "==> Storage Box Verbindungsdaten"
echo "    Hetzner Console → Storage Box → Zugangsdaten"
echo ""
read -rp  "    Host (z.B. u123456.your-storagebox.de): " STORAGE_BOX_HOST
read -rp  "    Username (z.B. u123456): " STORAGE_BOX_USER
read -rsp "    Passwort (wird nicht angezeigt): " STORAGE_BOX_PASSWORD
echo ""

if [[ -z "${STORAGE_BOX_HOST}" ]] || [[ -z "${STORAGE_BOX_USER}" ]] || [[ -z "${STORAGE_BOX_PASSWORD}" ]]; then
  echo "    FEHLER: Felder dürfen nicht leer sein. Abbruch."
  exit 1
fi

# ─── SSH Key-Paar generieren ─────────────────────────────────────────────────
echo ""
echo "==> Generiere SSH Key-Paar..."

rm -f "${KEY_FILE}" "${KEY_FILE}.pub"

ssh-keygen \
  -t ed25519 \
  -C "restic-backup@homelab" \
  -N "" \
  -f "${KEY_FILE}"

echo "    SSH Key generiert. ✅"

# ─── Public Key auf Storage Box hinterlegen ──────────────────────────────────
echo ""
echo "==> Hinterlege Public Key auf Storage Box..."

PUBLIC_KEY=$(cat "${KEY_FILE}.pub")

curl -sf \
  -u "${STORAGE_BOX_USER}:${STORAGE_BOX_PASSWORD}" \
  -X MKCOL \
  "https://${STORAGE_BOX_HOST}/.ssh/" 2>/dev/null || true

EXISTING_KEYS=$(curl -sf \
  -u "${STORAGE_BOX_USER}:${STORAGE_BOX_PASSWORD}" \
  "https://${STORAGE_BOX_HOST}/.ssh/authorized_keys" 2>/dev/null || echo "")

if echo "${EXISTING_KEYS}" | grep -q "restic-backup@homelab"; then
  echo "    Key bereits vorhanden – wird aktualisiert..."
  NEW_KEYS=$(echo "${EXISTING_KEYS}" | grep -v "restic-backup@homelab")
  NEW_KEYS="${NEW_KEYS}
${PUBLIC_KEY}"
else
  NEW_KEYS="${EXISTING_KEYS}
${PUBLIC_KEY}"
fi

curl -sf \
  -u "${STORAGE_BOX_USER}:${STORAGE_BOX_PASSWORD}" \
  -X PUT \
  --data "${NEW_KEYS}" \
  "https://${STORAGE_BOX_HOST}/.ssh/authorized_keys"

echo "    Public Key auf Storage Box hinterlegt. ✅"

# ─── Restic Verzeichnis auf Storage Box anlegen ──────────────────────────────
echo ""
echo "==> Restic Verzeichnis auf Storage Box anlegen..."

curl -sf \
  -u "${STORAGE_BOX_USER}:${STORAGE_BOX_PASSWORD}" \
  -X MKCOL \
  "https://${STORAGE_BOX_HOST}/restic-minio/" 2>/dev/null \
  && echo "    Verzeichnis /restic-minio/ angelegt. ✅" \
  || echo "    Verzeichnis /restic-minio/ existiert bereits. ✅"

# ─── Nach Vault schreiben ─────────────────────────────────────────────────────
echo ""
echo "==> Schreibe Key-Paar + Verbindungsdaten nach Vault ('homelab/${VAULT_PATH}')..."

vault_kv_put "${VAULT_PATH}" \
  "ssh-privatekey=$(cat "${KEY_FILE}")" \
  "ssh-publickey=${PUBLIC_KEY}" \
  "storage-box-host=${STORAGE_BOX_HOST}" \
  "storage-box-user=${STORAGE_BOX_USER}" \
  "storage-box-port=${SFTP_PORT}"

echo "    Geschrieben."

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret restic-ssh-key -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

# ─── SSH Keys sicher löschen ─────────────────────────────────────────────────
echo ""
echo "==> SSH Keys von lokalem Dateisystem löschen..."
shred -u "${KEY_FILE}" "${KEY_FILE}.pub" 2>/dev/null || rm -f "${KEY_FILE}" "${KEY_FILE}.pub"
echo "    Keys gelöscht. ✅"

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. Restic Backup manuell testen:"
echo "     kubectl create job restic-test-\$(date +%s) \\"
echo "       --from=cronjob/minio-backup-restic -n ${NAMESPACE}"
echo "============================================"
