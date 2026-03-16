#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-minio.sh
#  Erstellt das Kubernetes Secret für MinIO mit sicheren Credentials.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - Namespace 'infrastructure' existiert: kubectl get ns infrastructure
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

# ─── Credentials abfragen ────────────────────────────────────────────────────
echo "==> MinIO Root Credentials"
echo "    Diese Credentials werden für den MinIO Admin-Zugang"
echo "    und für CNPG Barman verwendet."
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
  -n "${NAMESPACE}"

echo "    Secret erstellt."

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. MinIO deployen:"
echo "     git add k8s/argocd/applications/minio.yaml"
echo "     git commit -m 'feat: add MinIO as S3 proxy for CNPG backups'"
echo "     git push"
echo ""
echo "  2. Warten bis MinIO läuft:"
echo "     kubectl get pods -n infrastructure | grep minio"
echo ""
echo "  3. CNPG Backup aktivieren:"
echo "     git add k8s/infrastructure/postgres-cluster.yaml"
echo "     git commit -m 'feat: enable CNPG Barman backup via MinIO'"
echo "     git push"
echo ""
echo "  4. Ersten manuellen Backup triggern:"
echo "     kubectl cnpg backup homelab-pg -n infrastructure"
echo ""
echo "  5. Backup Status prüfen:"
echo "     kubectl get backup -n infrastructure"
echo "     kubectl cnpg status homelab-pg -n infrastructure"
echo "============================================"
