#!/bin/bash
set -euo pipefail

# =============================================================================
#  test-velero-recovery.sh
#  Testet die Velero Cluster-State Wiederherstellung.
#
#  Was dieser Test macht:
#  1. Frischen Backup triggern und auf Completion warten
#  2. Restore in temporären Namespace durchführen
#  3. Kritische Ressourcen im wiederhergestellten Namespace prüfen
#  4. Temporären Namespace wieder löschen
#
#  Der originale Cluster wird NICHT berührt.
#
#  VORAUSSETZUNGEN:
#  - Velero läuft: kubectl get pods -n backup
#  - BackupStorageLocation available: kubectl get backupstoragelocation -n backup
#
#  USAGE:
#    ./scripts/test-velero-recovery.sh
#    ./scripts/test-velero-recovery.sh --skip-backup   # vorhandenen Backup nutzen
# =============================================================================

VELERO_NAMESPACE="backup"
TEST_BACKUP_NAME="recovery-test-$(date +%s)"
TEST_RESTORE_NAME="restore-test-$(date +%s)"
# Namespace der für den Restore-Test verwendet wird
SOURCE_NAMESPACE="auth"         # Keycloak – repräsentativer Test-Namespace
TARGET_NAMESPACE="velero-recovery-test"

SKIP_BACKUP=false

for arg in "$@"; do
  case $arg in
    --skip-backup) SKIP_BACKUP=true ;;
    --help)
      echo "Usage: $0 [--skip-backup]"
      echo "  --skip-backup  Neuesten vorhandenen Backup verwenden statt neuen zu erstellen"
      exit 0
      ;;
  esac
done

# ─── Farben ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $*"; }
success() { echo -e "${GREEN}    ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}    ⚠${NC} $*"; }
error()   { echo -e "${RED}    ✗${NC} $*"; exit 1; }

echo ""
echo "============================================"
echo "  Velero Recovery Test"
echo "  Source Namespace: ${SOURCE_NAMESPACE}"
echo "  Target Namespace: ${TARGET_NAMESPACE}"
echo "============================================"
echo ""

# ─── Voraussetzungen prüfen ───────────────────────────────────────────────────
info "Schritt 1/6: Voraussetzungen prüfen..."

VELERO_POD=$(kubectl get pods -n "${VELERO_NAMESPACE}" \
  -l app.kubernetes.io/name=velero \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${VELERO_POD}" ]]; then
  error "Kein laufender Velero Pod gefunden. Prüfe: kubectl get pods -n ${VELERO_NAMESPACE}"
fi
success "Velero Pod: ${VELERO_POD}"

BSL_STATUS=$(kubectl get backupstoragelocation default \
  -n "${VELERO_NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")

if [[ "${BSL_STATUS}" != "Available" ]]; then
  error "BackupStorageLocation nicht verfügbar (Status: ${BSL_STATUS})"
fi
success "BackupStorageLocation: Available"

# Alten Test-Namespace aufräumen falls vorhanden
if kubectl get namespace "${TARGET_NAMESPACE}" &>/dev/null; then
  warn "Alter Test-Namespace gefunden – wird gelöscht..."
  kubectl delete namespace "${TARGET_NAMESPACE}" --wait=true
  success "Alter Test-Namespace gelöscht."
fi

# ─── Backup erstellen oder vorhandenen nutzen ─────────────────────────────────
if [[ "${SKIP_BACKUP}" == "true" ]]; then
  info "Schritt 2/6: Neuesten vorhandenen Backup ermitteln..."

  BACKUP_TO_USE=$(kubectl get backup.velero.io -n "${VELERO_NAMESPACE}" \
    --sort-by='.metadata.creationTimestamp' \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)

  if [[ -z "${BACKUP_TO_USE}" ]]; then
    error "Kein vorhandener Backup gefunden. Führe ohne --skip-backup aus."
  fi
  success "Verwende Backup: ${BACKUP_TO_USE}"
else
  info "Schritt 2/6: Frischen Backup erstellen..."

  kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${TEST_BACKUP_NAME}
  namespace: ${VELERO_NAMESPACE}
spec:
  ttl: 24h
  storageLocation: default
  includedNamespaces:
    - ${SOURCE_NAMESPACE}
  excludedNamespaces: []
  defaultVolumesToFsBackup: false
  snapshotVolumes: false
YAML

  echo "    Warte auf Backup Completion (max. 5 Minuten)..."

  for i in $(seq 1 30); do
    PHASE=$(kubectl get backup.velero.io "${TEST_BACKUP_NAME}" \
      -n "${VELERO_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "${PHASE}" == "Completed" ]]; then
      ITEMS=$(kubectl get backup.velero.io "${TEST_BACKUP_NAME}" \
        -n "${VELERO_NAMESPACE}" \
        -o jsonpath='{.status.progress.itemsBackedUp}' 2>/dev/null || echo "?")
      success "Backup abgeschlossen (${ITEMS} Items gesichert)."
      break
    elif [[ "${PHASE}" == "Failed" ]] || [[ "${PHASE}" == "PartiallyFailed" ]]; then
      error "Backup fehlgeschlagen (Phase: ${PHASE}). Prüfe: kubectl describe backup.velero.io ${TEST_BACKUP_NAME} -n ${VELERO_NAMESPACE}"
    fi

    echo "    Status: ${PHASE:-Pending} – warte... (${i}/30)"
    sleep 10
  done

  if [[ "${PHASE:-}" != "Completed" ]]; then
    error "Backup nicht abgeschlossen nach 5 Minuten."
  fi

  BACKUP_TO_USE="${TEST_BACKUP_NAME}"
fi

# ─── Restore in temporären Namespace ─────────────────────────────────────────
info "Schritt 3/6: Restore in temporären Namespace '${TARGET_NAMESPACE}'..."

kubectl apply -f - <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: ${TEST_RESTORE_NAME}
  namespace: ${VELERO_NAMESPACE}
spec:
  backupName: ${BACKUP_TO_USE}
  includedNamespaces:
    - ${SOURCE_NAMESPACE}
  namespaceMapping:
    ${SOURCE_NAMESPACE}: ${TARGET_NAMESPACE}
  restorePVs: false
  existingResourcePolicy: none
YAML

echo "    Warte auf Restore Completion (max. 5 Minuten)..."

for i in $(seq 1 30); do
  RESTORE_PHASE=$(kubectl get restore.velero.io "${TEST_RESTORE_NAME}" \
    -n "${VELERO_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [[ "${RESTORE_PHASE}" == "Completed" ]] || [[ "${RESTORE_PHASE}" == "PartiallyFailed" ]]; then
    break
  fi

  echo "    Status: ${RESTORE_PHASE:-Pending} – warte... (${i}/30)"
  sleep 10
done

if [[ "${RESTORE_PHASE}" == "Completed" ]]; then
  success "Restore abgeschlossen."
elif [[ "${RESTORE_PHASE}" == "PartiallyFailed" ]]; then
  warn "Restore PartiallyFailed – wird trotzdem validiert."
else
  error "Restore nicht abgeschlossen nach 5 Minuten."
fi

# ─── Wiederhergestellte Ressourcen prüfen ────────────────────────────────────
info "Schritt 4/6: Wiederhergestellte Ressourcen validieren..."

echo ""
echo "    Secrets im wiederhergestellten Namespace:"
SECRETS=$(kubectl get secrets -n "${TARGET_NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l || echo "0")
echo "      Anzahl Secrets: ${SECRETS}"

if [[ "${SECRETS}" -gt 0 ]]; then
  success "Secrets vorhanden."
  kubectl get secrets -n "${TARGET_NAMESPACE}" 2>/dev/null | head -10
else
  warn "Keine Secrets gefunden."
fi

echo ""
echo "    ConfigMaps im wiederhergestellten Namespace:"
CONFIGMAPS=$(kubectl get configmaps -n "${TARGET_NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l || echo "0")
echo "      Anzahl ConfigMaps: ${CONFIGMAPS}"
if [[ "${CONFIGMAPS}" -gt 0 ]]; then
  success "ConfigMaps vorhanden."
else
  warn "Keine ConfigMaps gefunden."
fi

echo ""
echo "    Deployments / StatefulSets im wiederhergestellten Namespace:"
DEPLOYMENTS=$(kubectl get deployments -n "${TARGET_NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l || echo "0")
STATEFULSETS=$(kubectl get statefulsets -n "${TARGET_NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l || echo "0")
WORKLOADS=$((DEPLOYMENTS + STATEFULSETS))
echo "      Deployments: ${DEPLOYMENTS} / StatefulSets: ${STATEFULSETS}"
if [[ "${WORKLOADS}" -gt 0 ]]; then
  success "Workloads vorhanden."
  kubectl get deployments,statefulsets -n "${TARGET_NAMESPACE}" 2>/dev/null || true
else
  warn "Keine Deployments oder StatefulSets gefunden."
fi

echo ""
echo "    Services im wiederhergestellten Namespace:"
SERVICES=$(kubectl get services -n "${TARGET_NAMESPACE}" \
  --no-headers 2>/dev/null | wc -l || echo "0")
echo "      Anzahl Services: ${SERVICES}"
if [[ "${SERVICES}" -gt 0 ]]; then
  success "Services vorhanden."
else
  warn "Keine Services gefunden."
fi

# ─── Restore Details anzeigen ────────────────────────────────────────────────
info "Schritt 5/6: Restore Details..."
echo ""
kubectl describe restore.velero.io "${TEST_RESTORE_NAME}" \
  -n "${VELERO_NAMESPACE}" | grep -A 20 "Status:" || true

# ─── Aufräumen ────────────────────────────────────────────────────────────────
info "Schritt 6/6: Aufräumen..."

echo ""
read -rp "    Test-Namespace '${TARGET_NAMESPACE}' löschen? (J/n): " CONFIRM
CONFIRM=${CONFIRM:-J}

if [[ "${CONFIRM}" == "J" ]] || [[ "${CONFIRM}" == "j" ]]; then
  kubectl delete namespace "${TARGET_NAMESPACE}" --wait=false
  kubectl delete restore.velero.io "${TEST_RESTORE_NAME}" \
    -n "${VELERO_NAMESPACE}" 2>/dev/null || true
  if [[ "${SKIP_BACKUP}" == "false" ]]; then
    kubectl delete backup.velero.io "${TEST_BACKUP_NAME}" \
      -n "${VELERO_NAMESPACE}" 2>/dev/null || true
  fi
  success "Aufgeräumt."
else
  echo ""
  echo "    Test-Namespace bleibt bestehen: ${TARGET_NAMESPACE}"
  echo "    Manuell löschen mit:"
  echo "      kubectl delete namespace ${TARGET_NAMESPACE}"
  echo "      kubectl delete restore.velero.io ${TEST_RESTORE_NAME} -n ${VELERO_NAMESPACE}"
fi

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  Recovery Test abgeschlossen!"
echo ""
echo "  Backup:   ${BACKUP_TO_USE}"
echo "  Restore:  ${TEST_RESTORE_NAME}"
echo "  Items:    Secrets=${SECRETS} ConfigMaps=${CONFIGMAPS} Deployments=${DEPLOYMENTS} StatefulSets=${STATEFULSETS} Services=${SERVICES}"
echo ""
if [[ "${SECRETS}" -gt 0 ]] && [[ "${WORKLOADS}" -gt 0 ]]; then
  echo -e "  Ergebnis: ${GREEN}Backup ist wiederherstellbar ✅${NC}"
elif [[ "${SECRETS}" -gt 0 ]] && [[ "${SERVICES}" -gt 0 ]]; then
  echo -e "  Ergebnis: ${GREEN}Backup ist wiederherstellbar ✅${NC}"
  echo "  (Keine Workloads – Namespace enthält möglicherweise nur Secrets/Services)"
else
  echo -e "  Ergebnis: ${YELLOW}Teilweise wiederhergestellt – manuell prüfen ⚠${NC}"
fi
echo ""
echo "  Empfehlung: Test einmal pro Quartal wiederholen"
echo "============================================"
