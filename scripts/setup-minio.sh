#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-minio.sh
#  Schreibt die MinIO Root Credentials + Storage Box Passwort nach Vault.
#  Das ExternalSecret 'minio-secret' (Namespace infrastructure) übernimmt
#  von dort aus die Erstellung/Pflege des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  IDEMPOTENT: Wenn in Vault schon alle drei Werte gesetzt sind, wird nichts
#  überschrieben - zum bewussten Rotieren einzelne Keys manuell setzen:
#    kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
#      VAULT_TOKEN=$VAULT_TOKEN vault kv put secret/homelab/infrastructure/minio \
#      rootUser=... rootPassword=... storage-box-password=...
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-minio.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="infrastructure/minio"

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
echo "  MinIO – Vault Secret Setup"
echo "============================================"
echo ""

EXISTING_USER=$(vault_kv_get "${VAULT_PATH}" "rootUser")
EXISTING_PW=$(vault_kv_get "${VAULT_PATH}" "rootPassword")
EXISTING_SB_PW=$(vault_kv_get "${VAULT_PATH}" "storage-box-password")

if [[ -n "${EXISTING_USER}" ]] && [[ -n "${EXISTING_PW}" ]] && [[ -n "${EXISTING_SB_PW}" ]]; then
  echo "==> Vault-Pfad 'homelab/${VAULT_PATH}' ist bereits vollständig befüllt."
  echo "    Nichts zu tun. Zum Rotieren siehe Kommentar am Skriptanfang."
  exit 0
fi

echo "==> MinIO Root Credentials"
echo "    Werden für MinIO Admin-Zugang und CNPG Barman verwendet."
echo "    Außerdem als Restic-Repository-Passwort für die Storage Box."
echo ""
read -rp    "    Root Username (z.B. minioadmin): " MINIO_USER
read -rsp   "    Root Password (mind. 8 Zeichen, wird nicht angezeigt): " MINIO_PASSWORD
echo ""

if [[ -z "${MINIO_USER}" ]] || [[ -z "${MINIO_PASSWORD}" ]]; then
  echo "    FEHLER: Username oder Passwort leer. Abbruch."
  exit 1
fi

if [[ ${#MINIO_PASSWORD} -lt 8 ]]; then
  echo "    FEHLER: Passwort muss mindestens 8 Zeichen haben."
  exit 1
fi

echo ""
echo "==> Hetzner Storage Box Passwort"
echo "    Wird vom Restic CronJob für den Offsite-Backup verwendet."
echo "    Storage Box: u549610.your-storagebox.de"
echo ""
read -rsp "    Storage Box Passwort (wird nicht angezeigt): " STORAGE_BOX_PASSWORD
echo ""

if [[ -z "${STORAGE_BOX_PASSWORD}" ]]; then
  echo "    FEHLER: Storage Box Passwort leer. Abbruch."
  exit 1
fi

echo ""
echo "==> Schreibe Credentials nach Vault ('homelab/${VAULT_PATH}')..."
vault_kv_put "${VAULT_PATH}" \
  "rootUser=${MINIO_USER}" \
  "rootPassword=${MINIO_PASSWORD}" \
  "storage-box-password=${STORAGE_BOX_PASSWORD}"
echo "    Geschrieben mit Keys: rootUser, rootPassword, storage-box-password"

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret minio-secret -n infrastructure \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. MinIO deployen (falls noch nicht geschehen):"
echo "     git add k8s/argocd/applications/minio.yaml"
echo "     git add k8s/infrastructure/minio-backup-restic.yaml"
echo "     git commit -m 'feat: add MinIO + Restic backup to Storage Box'"
echo "     git push"
echo ""
echo "  2. Warten bis MinIO läuft:"
echo "     kubectl get pods -n infrastructure | grep minio"
echo ""
echo "  3. Restic Backup manuell testen:"
echo "     kubectl create job restic-test-\$(date +%s) \\"
echo "       --from=cronjob/minio-backup-restic -n infrastructure"
echo "     kubectl logs -n infrastructure -l job-name -f"
echo ""
echo "  4. CNPG Recovery testen:"
echo "     ./scripts/test-cnpg-recovery.sh"
echo "============================================"
