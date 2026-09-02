#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-velero.sh
#  Schreibt das Velero Secret (MinIO Credentials im AWS-Format) nach Vault
#  und verifiziert die BackupStorageLocation nach dem Deployment. Das
#  ExternalSecret 'velero-secret' (Namespace backup) übernimmt von Vault aus
#  die Pflege des Kubernetes Secrets.
#
#  VORAUSSETZUNGEN:
#  - kubectl konfiguriert und Cluster erreichbar
#  - MinIO läuft: kubectl get pods -n infrastructure | grep minio
#  - homelab/infrastructure/minio bereits in Vault (siehe setup-minio.sh)
#  - Bucket 'velero-backups' existiert in MinIO
#  - VAULT_TOKEN als Env-Var gesetzt
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-velero.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="backup/velero-secret"
NAMESPACE="backup"

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
echo "  Velero – Vault Secret Setup"
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

MINIO_ACCESS_KEY=$(vault_kv_get "infrastructure/minio" "rootUser")
MINIO_SECRET_KEY=$(vault_kv_get "infrastructure/minio" "rootPassword")

if [[ -z "${MINIO_ACCESS_KEY}" ]] || [[ -z "${MINIO_SECRET_KEY}" ]]; then
  echo "    FEHLER: MinIO Credentials nicht in Vault ('homelab/infrastructure/minio')."
  echo "    Führe zuerst aus: ./scripts/setup-minio.sh"
  exit 1
fi
echo "    MinIO Credentials (aus Vault): OK"

# ─── Namespace anlegen falls noch nicht vorhanden ────────────────────────────
echo ""
echo "==> Stelle sicher dass Namespace '${NAMESPACE}' existiert..."
kubectl get namespace "${NAMESPACE}" &>/dev/null || \
  kubectl create namespace "${NAMESPACE}"
echo "    Namespace: OK"

# ─── Velero Secret nach Vault schreiben ──────────────────────────────────────
# Velero erwartet eine AWS credentials-Datei im Secret
# Key: cloud (Dateiname im Pod: /credentials/cloud)
echo ""
echo "==> Schreibe Velero Secret nach Vault ('homelab/${VAULT_PATH}')..."

CREDENTIALS_CONTENT="[default]
aws_access_key_id=${MINIO_ACCESS_KEY}
aws_secret_access_key=${MINIO_SECRET_KEY}"

vault_kv_put "${VAULT_PATH}" "cloud=${CREDENTIALS_CONTENT}"
echo "    Geschrieben."

echo ""
echo "==> Stoße sofortigen Sync des ExternalSecret an..."
kubectl annotate externalsecret velero-secret -n "${NAMESPACE}" \
  force-sync="$(date +%s)" --overwrite 2>/dev/null || \
  echo "    (ExternalSecret noch nicht deployt - wird beim nächsten ArgoCD-Sync abgeholt)"

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
echo "  1. velero.yaml committen und pushen (falls noch nicht geschehen):"
echo "     git add k8s/argocd/applications/velero.yaml"
echo "     git commit -m 'feat: deploy Velero for cluster state backup'"
echo "     git push"
echo ""
echo "  2. Backup-Status prüfen:"
echo "     kubectl get backup -n backup"
echo "     kubectl get backupstoragelocation -n backup"
echo ""
echo "  3. Recovery-Test (Szenario B aus docs/backup-strategy.md):"
echo "     ./scripts/test-velero-recovery.sh"
echo "============================================"
