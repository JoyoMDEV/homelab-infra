#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-restic-ssh.sh
#  Generiert ein SSH Key-Paar für den Restic Backup CronJob und
#  hinterlegt den Public Key auf der Hetzner Storage Box.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - ssh-keygen verfügbar
#  - curl verfügbar
#
#  USAGE:
#    ./scripts/setup-restic-ssh.sh
# =============================================================================

NAMESPACE="infrastructure"
SECRET_NAME="restic-ssh-key"
SFTP_PORT="23"
KEY_FILE="/tmp/restic_storage_box"

echo ""
echo "============================================"
echo "  Restic SSH Key Setup"
echo "============================================"
echo ""

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

# .ssh Verzeichnis anlegen falls nicht vorhanden
curl -sf \
  -u "${STORAGE_BOX_USER}:${STORAGE_BOX_PASSWORD}" \
  -X MKCOL \
  "https://${STORAGE_BOX_HOST}/.ssh/" 2>/dev/null || true

# Bestehende authorized_keys lesen
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

# ─── Kubernetes Secret anlegen ───────────────────────────────────────────────
echo ""
echo "==> Erstelle Kubernetes Secret '${SECRET_NAME}'..."

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "    Secret existiert bereits – wird aktualisiert..."
  kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

kubectl create secret generic "${SECRET_NAME}" \
  --from-file=ssh-privatekey="${KEY_FILE}" \
  --from-file=ssh-publickey="${KEY_FILE}.pub" \
  --from-literal=storage-box-host="${STORAGE_BOX_HOST}" \
  --from-literal=storage-box-user="${STORAGE_BOX_USER}" \
  --from-literal=storage-box-port="${SFTP_PORT}" \
  -n "${NAMESPACE}"

echo "    Secret '${SECRET_NAME}' erstellt. ✅"

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
echo "  1. Committen und deployen:"
echo "     git add k8s/infrastructure/minio-backup-restic.yaml"
echo "     git add scripts/setup-restic-ssh.sh"
echo "     git commit -m 'feat(backup): add Restic SFTP backup to Storage Box'"
echo "     git push"
echo ""
echo "  2. Restic Backup manuell testen:"
echo "     kubectl create job restic-test-\$(date +%s) \\"
echo "       --from=cronjob/minio-backup-restic -n ${NAMESPACE}"
echo ""
echo "  HINWEIS: SSH Key liegt nur im Kubernetes Secret '${SECRET_NAME}'."
echo "  Später zu Vault migrieren (Issue #7)."
echo "============================================"
