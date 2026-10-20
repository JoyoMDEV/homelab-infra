#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-garage-samba-backup.sh
#  Creates the Garage bucket 'samba-backup' and a write-scoped access key
#  'samba-backup-key' for the Samba AD backup (ansible/roles/backup).
#
#  The credentials are NOT written to HashiCorp Vault: the backup runs from a
#  systemd timer on the DC host, which gets its secrets from Ansible Vault.
#  The script therefore prints no secret. Copy the values yourself:
#
#    kubectl exec -n infrastructure garage-0 -c garage -- \
#      /garage key info samba-backup-key --show-secret
#
#  and add them with `make vault-edit` (ansible/inventory/group_vars/all/vault.yml):
#
#    vault_garage_backup_access_key_id: "GK..."
#    vault_garage_backup_secret_access_key: "..."
#
#  Then: make ansible-backup
#
#  IDEMPOTENT: existing bucket/key are reused.
#
#  VORAUSSETZUNGEN: kubectl konfiguriert, Garage laeuft (Namespace infrastructure)
# =============================================================================

GARAGE_NS="infrastructure"
GARAGE_POD="garage-0"
BUCKET="samba-backup"
KEY_NAME="samba-backup-key"

garage_exec() {
  kubectl exec -n "${GARAGE_NS}" "${GARAGE_POD}" -c garage -- /garage "$@"
}

echo "==> Lege Garage-Bucket '${BUCKET}' an..."
garage_exec bucket create "${BUCKET}" 2>/dev/null || echo "    Bucket existiert bereits."

echo "==> Lege Access-Key '${KEY_NAME}' an..."
garage_exec key create "${KEY_NAME}" 2>/dev/null || echo "    Key existiert bereits."

echo "==> Erlaube Key '${KEY_NAME}' Lesen/Schreiben auf '${BUCKET}'..."
garage_exec bucket allow --read --write --key "${KEY_NAME}" "${BUCKET}"

echo ""
echo "============================================"
echo "  Fertig. Bucket: ${BUCKET}, Key: ${KEY_NAME}"
echo "  Secret auslesen und in den Ansible Vault eintragen:"
echo "    kubectl exec -n ${GARAGE_NS} ${GARAGE_POD} -c garage -- \\"
echo "      /garage key info ${KEY_NAME} --show-secret"
echo "    make vault-edit"
echo "    make ansible-backup"
echo "============================================"
