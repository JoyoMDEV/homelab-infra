#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-minio.sh
#  Erstellt das Kubernetes Secret für MinIO mit Credentials und
#  Storage Box Passwort für den Restic-Backup-CronJob.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - Namespace 'infrastructure' existiert
#
#  USAGE:
#    ./scripts/setup-minio.sh
# =============================================================================

NAMESPACE="infrastructure"
SECRET_NAME="minio-secret"

echo ""
echo "============================================"
echo "  MinIO – Secret Setup"
echo "============================================"
echo ""

# ─── MinIO Credentials ───────────────────────────────────────────────────────
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

# ─── Storage Box Passwort ────────────────────────────────────────────────────
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

# ─── Secret anlegen oder aktualisieren ───────────────────────────────────────
echo ""
echo "==> Erstelle Secret '${SECRET_NAME}' in Namespace '${NAMESPACE}'..."

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "    Secret existiert bereits – wird aktualisiert..."
  kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

kubectl create secret generic "${SECRET_NAME}" \
  --from-literal=rootUser="${MINIO_USER}" \
  --from-literal=rootPassword="${MINIO_PASSWORD}" \
  --from-literal=storage-box-password="${STORAGE_BOX_PASSWORD}" \
  -n "${NAMESPACE}"

echo "    Secret erstellt mit Keys: rootUser, rootPassword, storage-box-password"

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. MinIO deployen:"
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
