#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-velero.sh
#  Erstellt das Kubernetes Secret für Velero (MinIO Credentials)
#  und verifiziert die BackupStorageLocation nach dem Deployment.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - MinIO läuft: kubectl get pods -n infrastructure | grep minio
#  - minio-secret existiert in Namespace infrastructure
#  - Bucket 'velero-backups' existiert in MinIO
#    (wird automatisch von bootstrap-argocd.sh angelegt – siehe minio.yaml)
#
#  USAGE:
#    ./scripts/setup-velero.sh
# =============================================================================

NAMESPACE="backup"
SECRET_NAME="velero-secret"

echo ""
echo "============================================"
echo "  Velero – Secret Setup"
echo "============================================"
echo ""

# ─── Voraussetzungen prüfen ───────────────────────────────────────────────────
echo "==> Prüfe Voraussetzungen..."

if ! kubectl get pods -n infrastructure -l app=minio 2>/dev/null | grep -q Running; then
  echo "    FEHLER: MinIO läuft nicht."
  echo "    Stelle sicher dass MinIO deployed ist: make apps"
  exit 1
fi
echo "    MinIO: OK"

if ! kubectl get secret minio-secret -n infrastructure &>/dev/null; then
  echo "    FEHLER: minio-secret nicht gefunden."
  echo "    Führe zuerst aus: ./scripts/setup-minio.sh"
  exit 1
fi
echo "    minio-secret: OK"

# ─── MinIO Credentials aus bestehendem Secret lesen ──────────────────────────
echo ""
echo "==> Lese MinIO Credentials aus minio-secret..."

MINIO_ACCESS_KEY=$(kubectl get secret minio-secret -n infrastructure \
  -o jsonpath='{.data.rootUser}' | base64 -d)
MINIO_SECRET_KEY=$(kubectl get secret minio-secret -n infrastructure \
  -o jsonpath='{.data.rootPassword}' | base64 -d)

echo "    MinIO Access Key: ${MINIO_ACCESS_KEY}"
echo "    MinIO Secret Key: gelesen."

# ─── Namespace anlegen falls noch nicht vorhanden ────────────────────────────
echo ""
echo "==> Stelle sicher dass Namespace '${NAMESPACE}' existiert..."
kubectl get namespace "${NAMESPACE}" &>/dev/null || \
  kubectl create namespace "${NAMESPACE}"
echo "    Namespace: OK"

# ─── Velero Secret anlegen ───────────────────────────────────────────────────
# Velero erwartet eine AWS credentials-Datei im Secret
# Key: cloud (Dateiname im Pod: /credentials/cloud)
echo ""
echo "==> Erstelle Velero Secret '${SECRET_NAME}'..."

CREDENTIALS_CONTENT="[default]
aws_access_key_id=${MINIO_ACCESS_KEY}
aws_secret_access_key=${MINIO_SECRET_KEY}"

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "    Secret existiert bereits – wird aktualisiert..."
  kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

kubectl create secret generic "${SECRET_NAME}" \
  --from-literal=cloud="${CREDENTIALS_CONTENT}" \
  -n "${NAMESPACE}"

echo "    Secret erstellt."

# ─── Warten bis Velero deployed ist ──────────────────────────────────────────
echo ""
echo "==> Warte auf Velero Deployment..."
echo "    (Erst committen und pushen, dann hier warten)"
echo ""

for i in $(seq 1 30); do
  VELERO_READY=$(kubectl get deployment velero -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "${VELERO_READY}" == "1" ]]; then
    echo "    Velero Deployment bereit. ✅"
    break
  fi

  if [[ $i -eq 30 ]]; then
    echo "    Velero noch nicht bereit – manuell prüfen:"
    echo "      kubectl get pods -n ${NAMESPACE}"
    exit 0
  fi

  echo "    Warte... (${i}/30)"
  sleep 10
done

# ─── BackupStorageLocation verifizieren ──────────────────────────────────────
echo ""
echo "==> Prüfe BackupStorageLocation..."
sleep 5

BSL_STATUS=$(kubectl get backupstoragelocation default -n "${NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

if [[ "${BSL_STATUS}" == "Available" ]]; then
  echo "    BackupStorageLocation: Available ✅"
else
  echo "    BackupStorageLocation Status: ${BSL_STATUS}"
  echo "    Falls 'Unavailable': MinIO-Verbindung prüfen"
  echo "      kubectl describe backupstoragelocation default -n ${NAMESPACE}"
fi

# ─── Ersten manuellen Backup triggern ────────────────────────────────────────
echo ""
echo "==> Ersten manuellen Test-Backup triggern..."

if command -v velero &>/dev/null; then
  velero backup create initial-test-backup \
    --namespace "${NAMESPACE}" \
    --wait \
    --exclude-namespaces kube-system
  echo "    Test-Backup abgeschlossen."
  velero backup describe initial-test-backup --namespace "${NAMESPACE}"
else
  echo "    velero CLI nicht installiert – manuell triggern:"
  echo ""
  echo "    kubectl create job --from=cronjob/velero-daily-cluster-backup \\"
  echo "      velero-test-\$(date +%s) -n ${NAMESPACE}"
  echo ""
  echo "    Oder via kubectl:"
  cat <<'EOF'
    kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: initial-test-backup
  namespace: backup
spec:
  ttl: 336h
  storageLocation: default
  excludedNamespaces:
    - kube-system
  defaultVolumesToFsBackup: true
YAML
EOF
fi

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Setup abgeschlossen!"
echo ""
echo "  Täglicher Schedule: täglich 02:00 Uhr"
echo "  Retention:          14 Tage"
echo "  Storage:            MinIO → velero-backups"
echo "  PVC-Backup:         Kopia (node-agent)"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. velero.yaml committen und pushen:"
echo "     git add k8s/argocd/applications/velero.yaml"
echo "     git commit -m 'feat: deploy Velero for cluster state backup'"
echo "     git push"
echo ""
echo "  2. Dieses Script ausführen nachdem ArgoCD synct:"
echo "     ./scripts/setup-velero.sh"
echo ""
echo "  3. Kritische Secrets in Ansible Vault sichern:"
echo "     kubectl get secret gitlab-rails-secrets -n gitlab \\"
echo "       -o jsonpath='{.data}' | python3 -m json.tool"
echo "     kubectl get secret homelab-ca-keypair -n cert-manager \\"
echo "       -o jsonpath='{.data.tls\\.crt}' | base64 -d"
echo "     make vault-edit"
echo ""
echo "  4. Backup-Status prüfen:"
echo "     kubectl get backup -n backup"
echo "     kubectl get backupstoragelocation -n backup"
echo ""
echo "  5. Recovery-Test (Szenario B aus docs/backup-strategy.md):"
echo "     ./scripts/test-velero-recovery.sh"
echo "============================================"
