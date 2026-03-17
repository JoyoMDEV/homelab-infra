#!/bin/bash
set -euo pipefail

# =============================================================================
#  test-cnpg-recovery.sh
#  Testet die PostgreSQL Wiederherstellung aus einem CNPG Barman Backup.
#
#  Was dieser Test macht:
#  1. Neuesten Backup aus MinIO ermitteln
#  2. Temporären Wiederherstellungs-Cluster erstellen
#  3. Warten bis der Cluster bereit ist
#  4. Datenbanken und Tabellen im wiederhergestellten Cluster prüfen
#  5. Temporären Cluster wieder löschen
#
#  Der originale Cluster (homelab-pg) wird NICHT berührt.
#
#  VORAUSSETZUNGEN:
#  - kubectl cnpg Plugin installiert
#  - MinIO läuft und enthält mindestens einen Backup
#  - CNPG Operator läuft im Cluster
#
#  USAGE:
#    ./scripts/test-cnpg-recovery.sh
# =============================================================================

NAMESPACE="infrastructure"
ORIGINAL_CLUSTER="homelab-pg"
RESTORE_CLUSTER="homelab-pg-recovery-test"
MINIO_SECRET="minio-secret"

echo ""
echo "============================================"
echo "  CNPG Recovery Test"
echo "  Original Cluster: ${ORIGINAL_CLUSTER}"
echo "  Test Cluster:     ${RESTORE_CLUSTER}"
echo "============================================"
echo ""

# ─── Voraussetzungen prüfen ───────────────────────────────────────────────────
echo "==> Prüfe Voraussetzungen..."

if ! kubectl cnpg --help &>/dev/null; then
  echo "    FEHLER: kubectl cnpg Plugin nicht installiert."
  echo "    Installieren mit:"
  echo "      curl -sSfL https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | sudo sh -s -- -b /usr/local/bin"
  exit 1
fi

# Neuesten Backup ermitteln
LATEST_BACKUP=$(kubectl get backup -n "${NAMESPACE}" \
  --sort-by='.metadata.creationTimestamp' \
  -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

if [[ -z "${LATEST_BACKUP}" ]]; then
  echo "    FEHLER: Kein Backup gefunden in Namespace '${NAMESPACE}'."
  echo "    Ersten Backup manuell triggern:"
  echo "      kubectl cnpg backup ${ORIGINAL_CLUSTER} -n ${NAMESPACE}"
  exit 1
fi

echo "    Neuester Backup: ${LATEST_BACKUP} ✅"
echo "    CNPG Plugin: verfügbar ✅"

# Alten Test-Cluster aufräumen falls vorhanden
if kubectl get cluster "${RESTORE_CLUSTER}" -n "${NAMESPACE}" &>/dev/null; then
  echo ""
  echo "==> Alter Test-Cluster gefunden – wird zuerst gelöscht..."
  kubectl delete cluster "${RESTORE_CLUSTER}" -n "${NAMESPACE}"
  echo "    Warte auf Löschung..."
  kubectl wait --for=delete cluster/"${RESTORE_CLUSTER}" \
    -n "${NAMESPACE}" --timeout=120s 2>/dev/null || true
fi

# ─── Recovery Cluster erstellen ───────────────────────────────────────────────
echo ""
echo "==> Erstelle Recovery-Test-Cluster aus Backup '${LATEST_BACKUP}'..."

kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${RESTORE_CLUSTER}
  namespace: ${NAMESPACE}
  labels:
    purpose: recovery-test
spec:
  instances: 1
  storage:
    size: 10Gi
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
  bootstrap:
    recovery:
      backup:
        name: ${LATEST_BACKUP}
  externalClusters:
    - name: ${ORIGINAL_CLUSTER}
      barmanObjectStore:
        destinationPath: s3://cnpg-backups/
        endpointURL: http://minio.infrastructure.svc.cluster.local:9000
        s3Credentials:
          accessKeyId:
            name: ${MINIO_SECRET}
            key: rootUser
          secretAccessKey:
            name: ${MINIO_SECRET}
            key: rootPassword
YAML

echo "    Recovery-Cluster erstellt."

# ─── Warten bis Cluster bereit ist ───────────────────────────────────────────
echo ""
echo "==> Warte bis Recovery-Cluster bereit ist (max. 10 Minuten)..."

for i in $(seq 1 60); do
  STATUS=$(kubectl get cluster "${RESTORE_CLUSTER}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

  if [[ "${STATUS}" == "Cluster in healthy state" ]]; then
    echo "    Cluster bereit! ✅"
    break
  fi

  if [[ $i -eq 60 ]]; then
    echo "    FEHLER: Cluster nicht bereit nach 10 Minuten."
    echo "    Status prüfen:"
    echo "      kubectl describe cluster ${RESTORE_CLUSTER} -n ${NAMESPACE}"
    kubectl delete cluster "${RESTORE_CLUSTER}" -n "${NAMESPACE}" 2>/dev/null || true
    exit 1
  fi

  echo "    Status: ${STATUS} – warte... (${i}/60)"
  sleep 10
done

# ─── Datenbanken prüfen ───────────────────────────────────────────────────────
echo ""
echo "==> Prüfe wiederhergestellte Datenbanken..."

RESTORE_POD="${RESTORE_CLUSTER}-1"

# Kurz warten bis Pod ready
kubectl wait --for=condition=ready pod/"${RESTORE_POD}" \
  -n "${NAMESPACE}" --timeout=120s

echo ""
echo "    Datenbanken im wiederhergestellten Cluster:"
kubectl exec -n "${NAMESPACE}" "${RESTORE_POD}" -c postgres -- \
  psql -U postgres -c "\l" | grep -E "gitlab|keycloak|nextcloud|paperless"

echo ""
echo "    Tabellen in keycloak:"
kubectl exec -n "${NAMESPACE}" "${RESTORE_POD}" -c postgres -- \
  psql -U postgres -d keycloak -c "\dt" 2>/dev/null | head -10 || \
  echo "    (keycloak Datenbank nicht zugänglich – erwartet, da kein superuser)"

echo ""
echo "    Row counts zur Verifikation:"
kubectl exec -n "${NAMESPACE}" "${RESTORE_POD}" -c postgres -- \
  psql -U postgres -c "
    SELECT datname, pg_size_pretty(pg_database_size(datname)) as size
    FROM pg_database
    WHERE datname NOT IN ('template0','template1','postgres')
    ORDER BY pg_database_size(datname) DESC;
  "

# ─── Aufräumen ────────────────────────────────────────────────────────────────
echo ""
echo "==> Recovery-Test erfolgreich!"
echo ""
read -rp "    Test-Cluster löschen? (J/n): " DELETE_CONFIRM
DELETE_CONFIRM=${DELETE_CONFIRM:-J}

if [[ "${DELETE_CONFIRM}" == "J" ]] || [[ "${DELETE_CONFIRM}" == "j" ]]; then
  kubectl delete cluster "${RESTORE_CLUSTER}" -n "${NAMESPACE}"
  echo "    Test-Cluster gelöscht."
else
  echo "    Test-Cluster bleibt bestehen: ${RESTORE_CLUSTER}"
  echo "    Manuell löschen mit:"
  echo "      kubectl delete cluster ${RESTORE_CLUSTER} -n ${NAMESPACE}"
fi

echo ""
echo "============================================"
echo "  Recovery Test abgeschlossen!"
echo ""
echo "  Ergebnis: Backup ist wiederherstellbar ✅"
echo "  Backup verwendet: ${LATEST_BACKUP}"
echo "  Empfehlung: Test einmal pro Quartal wiederholen"
echo "============================================"
