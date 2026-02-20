#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-nextcloud-storage.sh
#  Konfiguriert die Hetzner Storage Box als External Storage in Nextcloud.
#
#  VORAUSSETZUNGEN:
#  - Nextcloud Pod läuft in Namespace 'productivity'
#  - Secret 'nextcloud-secret' existiert mit Key 'storage-box-password'
#  - Verzeichnis /nextcloud existiert auf der Storage Box (sonst wird es angelegt)
#  - Terraform Outputs sind verfügbar (für Storage Box Host/User)
#
#  USAGE:
#    ./setup-nextcloud-storage.sh
#    ./setup-nextcloud-storage.sh --dry-run   # Nur prüfen, nichts ändern
#    ./setup-nextcloud-storage.sh --reset     # External Storage entfernen und neu anlegen
# =============================================================================

# ─── Konfiguration ────────────────────────────────────────────────────────────
NAMESPACE="productivity"
SECRET_NAME="nextcloud-secret"
STORAGE_BOX_SECRET_KEY="storage-box-password"
STORAGE_BOX_REMOTE_PATH="/nextcloud"
STORAGE_BOX_PORT=23
MOUNT_NAME="Storage Box"

# ─── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=false
RESET=false

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --reset)   RESET=true ;;
    --help)
      echo "Usage: $0 [--dry-run] [--reset]"
      echo "  --dry-run  Nur prüfen, nichts ändern"
      echo "  --reset    External Storage entfernen und neu anlegen"
      exit 0
      ;;
    *) echo "Unbekannter Parameter: $arg"; exit 1 ;;
  esac
done

# ─── Farben ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $*"; }
success() { echo -e "${GREEN}    ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}    ⚠${NC} $*"; }
error()   { echo -e "${RED}    ✗${NC} $*"; }
dryrun()  { echo -e "${YELLOW}    [DRY-RUN]${NC} $*"; }

# ─── Helper: occ ausführen ────────────────────────────────────────────────────
# Führt einen occ-Befehl im Nextcloud Pod aus.
occ() {
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" \
    -- su -s /bin/sh www-data -c "php /var/www/html/occ $*"
}

# ─── Helper: occ mit Output ───────────────────────────────────────────────────
occ_output() {
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" \
    -- su -s /bin/sh www-data -c "php /var/www/html/occ $*" 2>&1
}

# =============================================================================
echo ""
echo "============================================"
echo "  Nextcloud Storage Box Setup"
if $DRY_RUN; then
  echo "  Modus: DRY-RUN (keine Änderungen)"
fi
echo "============================================"
echo ""

# ─── Step 1: Voraussetzungen prüfen ──────────────────────────────────────────
info "Schritt 1/7: Voraussetzungen prüfen..."

# kubectl verfügbar?
if ! command -v kubectl &>/dev/null; then
  error "kubectl nicht gefunden. Bitte installieren."
  exit 1
fi
success "kubectl verfügbar"

# Namespace existiert?
if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  error "Namespace '${NAMESPACE}' nicht gefunden. Nextcloud noch nicht deployed?"
  exit 1
fi
success "Namespace '${NAMESPACE}' existiert"

# Pod läuft?
POD_NAME=$(kubectl get pod -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=nextcloud \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${POD_NAME}" ]]; then
  error "Kein laufender Nextcloud Pod gefunden in Namespace '${NAMESPACE}'."
  error "Status prüfen: kubectl get pods -n ${NAMESPACE}"
  exit 1
fi
success "Nextcloud Pod: ${POD_NAME}"

# Secret existiert?
if ! kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  error "Secret '${SECRET_NAME}' nicht gefunden in Namespace '${NAMESPACE}'."
  error "Bitte zuerst setup-databases.sh ausführen."
  exit 1
fi
success "Secret '${SECRET_NAME}' gefunden"

# Storage Box Passwort im Secret?
STORAGE_BOX_PW=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
  -o jsonpath="{.data.${STORAGE_BOX_SECRET_KEY}}" 2>/dev/null | base64 -d || true)

if [[ -z "${STORAGE_BOX_PW}" ]]; then
  error "Key '${STORAGE_BOX_SECRET_KEY}' nicht im Secret '${SECRET_NAME}' gefunden."
  error "Secret updaten: kubectl patch secret ${SECRET_NAME} -n ${NAMESPACE} \\"
  error "  --type merge -p '{\"stringData\":{\"${STORAGE_BOX_SECRET_KEY}\":\"<PASSWORT>\"}}'"
  exit 1
fi
success "Storage Box Passwort aus Secret gelesen"

# ─── Step 2: Storage Box Verbindungsdaten ermitteln ──────────────────────────
info "Schritt 2/7: Storage Box Verbindungsdaten ermitteln..."

# Versuche Terraform Outputs zu lesen
STORAGE_BOX_HOST=""
STORAGE_BOX_USER=""

if [[ -d "terraform" ]] && command -v terraform &>/dev/null; then
  info "  Lese Storage Box Daten aus Terraform Outputs..."
  cd terraform
  STORAGE_BOX_HOST=$(terraform output -raw storage_box_host 2>/dev/null || true)
  STORAGE_BOX_USER=$(terraform output -raw storage_box_username 2>/dev/null || true)
  cd ..
fi

# Fallback: Manuell eingeben
if [[ -z "${STORAGE_BOX_HOST}" ]]; then
  warn "Terraform Output nicht verfügbar. Bitte manuell eingeben."
  echo ""
  read -rp "    Storage Box Host (z.B. u123456.your-storagebox.de): " STORAGE_BOX_HOST
fi

if [[ -z "${STORAGE_BOX_USER}" ]]; then
  read -rp "    Storage Box Username (z.B. u123456): " STORAGE_BOX_USER
fi

if [[ -z "${STORAGE_BOX_HOST}" ]] || [[ -z "${STORAGE_BOX_USER}" ]]; then
  error "Storage Box Host oder Username leer. Abbruch."
  exit 1
fi

success "Storage Box Host: ${STORAGE_BOX_HOST}"
success "Storage Box User: ${STORAGE_BOX_USER}"
success "Storage Box Port: ${STORAGE_BOX_PORT}"
success "Remote Path:      ${STORAGE_BOX_REMOTE_PATH}"

# ─── Step 3: SFTP-Verbindung zur Storage Box testen ──────────────────────────
info "Schritt 3/7: SFTP-Verbindung zur Storage Box testen..."

# Teste Verbindung über einen temporären Pod (Nextcloud Pod hat kein sftp-client)
SFTP_TEST=$(kubectl run sftp-test-$$ \
  --image=alpine \
  --restart=Never \
  --rm \
  --timeout=30s \
  -i \
  --namespace="${NAMESPACE}" \
  -- sh -c "
    apk add --no-cache openssh-client sshpass -q 2>/dev/null
    sshpass -p '${STORAGE_BOX_PW}' sftp \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -P ${STORAGE_BOX_PORT} \
      ${STORAGE_BOX_USER}@${STORAGE_BOX_HOST} <<EOF
ls /
bye
EOF
  " 2>&1 || true)

if echo "${SFTP_TEST}" | grep -q "sftp>"; then
  success "SFTP-Verbindung zur Storage Box erfolgreich"
else
  warn "SFTP-Test nicht eindeutig. Verbindungsfehler möglich."
  warn "Ausgabe: ${SFTP_TEST}"
  echo ""
  read -rp "    Trotzdem fortfahren? (j/N): " CONTINUE
  if [[ "${CONTINUE}" != "j" ]] && [[ "${CONTINUE}" != "J" ]]; then
    echo "Abbruch."
    exit 1
  fi
fi

# ─── Step 4: Remote-Verzeichnis auf Storage Box anlegen ──────────────────────
info "Schritt 4/7: Verzeichnis '${STORAGE_BOX_REMOTE_PATH}' auf Storage Box sicherstellen..."

if $DRY_RUN; then
  dryrun "sftp mkdir ${STORAGE_BOX_REMOTE_PATH} (übersprungen)"
else
  kubectl run sftp-mkdir-$$ \
    --image=alpine \
    --restart=Never \
    --rm \
    --timeout=30s \
    -i \
    --namespace="${NAMESPACE}" \
    -- sh -c "
      apk add --no-cache openssh-client sshpass -q 2>/dev/null
      sshpass -p '${STORAGE_BOX_PW}' sftp \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        -P ${STORAGE_BOX_PORT} \
        ${STORAGE_BOX_USER}@${STORAGE_BOX_HOST} <<EOF 2>&1 || true
mkdir ${STORAGE_BOX_REMOTE_PATH}
bye
EOF
    " &>/dev/null || true
  success "Verzeichnis sichergestellt (existiert bereits oder wurde angelegt)"
fi

# ─── Step 5: Nextcloud External Storage App aktivieren ───────────────────────
info "Schritt 5/7: External Storage App in Nextcloud aktivieren..."

# Prüfen ob App bereits aktiv
APPS_ENABLED=$(occ_output "app:list --enabled" 2>/dev/null || true)

if echo "${APPS_ENABLED}" | grep -q "files_external"; then
  success "files_external App bereits aktiv"
else
  if $DRY_RUN; then
    dryrun "occ app:enable files_external"
  else
    occ "app:enable files_external" 2>&1 | grep -v "^$" || true
    success "files_external App aktiviert"
  fi
fi

# ─── Step 6: Bestehende Storage Box Konfiguration prüfen / zurücksetzen ──────
info "Schritt 6/7: Bestehende External Storage Konfiguration prüfen..."

EXISTING_MOUNTS=$(occ_output "files_external:list --output=json" 2>/dev/null || echo "[]")

# Suche nach einem Mount mit gleichem Namen oder gleicher Host-Konfiguration
EXISTING_ID=$(echo "${EXISTING_MOUNTS}" | \
  python3 -c "
import sys, json
try:
    mounts = json.load(sys.stdin)
    for m in mounts:
        config = m.get('configuration', {})
        name = m.get('mount_point', '')
        if '${MOUNT_NAME}' in name or '${STORAGE_BOX_HOST}' in config.get('host', ''):
            print(m.get('mount_id', ''))
            break
except: pass
" 2>/dev/null || true)

if [[ -n "${EXISTING_ID}" ]]; then
  if $RESET; then
    warn "Bestehende Konfiguration gefunden (ID: ${EXISTING_ID}). Wird entfernt (--reset)..."
    if $DRY_RUN; then
      dryrun "occ files_external:delete ${EXISTING_ID}"
    else
      occ "files_external:delete ${EXISTING_ID} --yes" 2>&1 || true
      success "Alte Konfiguration entfernt"
      EXISTING_ID=""
    fi
  else
    warn "Storage Box bereits konfiguriert (Mount ID: ${EXISTING_ID})."
    warn "Zum Neu-Anlegen: $0 --reset"
    echo ""
    echo "    Aktuelle Konfiguration:"
    occ_output "files_external:list" 2>/dev/null | grep -A5 "${EXISTING_ID}" || true
    echo ""
    echo "    Überspringe Schritt 7 (Mount anlegen)."
    SKIP_CREATE=true
  fi
fi

# ─── Step 7: External Storage Mount anlegen ───────────────────────────────────
info "Schritt 7/7: Storage Box als External Storage einrichten..."

if [[ "${SKIP_CREATE:-false}" == "true" ]]; then
  warn "Mount bereits vorhanden, überspringe."
else
  if $DRY_RUN; then
    dryrun "occ files_external:create '${MOUNT_NAME}' 'sftp' 'password::password' \\"
    dryrun "  --config host=${STORAGE_BOX_HOST} \\"
    dryrun "  --config port=${STORAGE_BOX_PORT} \\"
    dryrun "  --config user=${STORAGE_BOX_USER} \\"
    dryrun "  --config root=${STORAGE_BOX_REMOTE_PATH} \\"
    dryrun "  --config password=***"
  else
    # Mount anlegen
    occ "files_external:create \
      '${MOUNT_NAME}' \
      'sftp' \
      'password::password' \
      --config host='${STORAGE_BOX_HOST}' \
      --config port='${STORAGE_BOX_PORT}' \
      --config user='${STORAGE_BOX_USER}' \
      --config root='${STORAGE_BOX_REMOTE_PATH}' \
      --config password='${STORAGE_BOX_PW}'" 2>&1

    # Mount ID der neu angelegten Konfiguration ermitteln
    NEW_ID=$(occ_output "files_external:list --output=json" 2>/dev/null | \
      python3 -c "
import sys, json
try:
    mounts = json.load(sys.stdin)
    for m in sorted(mounts, key=lambda x: x.get('mount_id', 0), reverse=True):
        if '${MOUNT_NAME}' in m.get('mount_point', ''):
            print(m.get('mount_id', ''))
            break
except: pass
" 2>/dev/null || true)

    if [[ -n "${NEW_ID}" ]]; then
      success "Mount angelegt (ID: ${NEW_ID})"

      # Mount für alle Benutzer verfügbar machen (applicable_users = all)
      occ "files_external:applicable \
        --add-group everyone \
        ${NEW_ID}" 2>&1 || true

      success "Mount für alle Benutzer freigegeben"
    else
      warn "Mount wurde angelegt, ID konnte nicht ermittelt werden."
    fi
  fi
fi

# ─── Verbindungstest ──────────────────────────────────────────────────────────
info "Verbindungstest von Nextcloud zur Storage Box..."

if ! $DRY_RUN; then
  # Nextcloud Files-Cache aktualisieren
  occ "files:scan --all --quiet" 2>&1 | tail -3 || true

  # Mount-Status prüfen
  MOUNT_STATUS=$(occ_output "files_external:list" 2>/dev/null || true)
  echo ""
  echo "    Aktuelle External Storage Konfiguration:"
  echo "    $(echo "${MOUNT_STATUS}" | head -20)"
fi

# ─── Zusammenfassung ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
if $DRY_RUN; then
  echo "  DRY-RUN abgeschlossen – keine Änderungen"
else
  echo "  Setup abgeschlossen!"
fi
echo ""
echo "  Storage Box:  ${STORAGE_BOX_HOST}"
echo "  User:         ${STORAGE_BOX_USER}"
echo "  Port:         ${STORAGE_BOX_PORT}"
echo "  Remote Path:  ${STORAGE_BOX_REMOTE_PATH}"
echo ""
if ! $DRY_RUN; then
  echo "  Die Storage Box erscheint in Nextcloud unter:"
  echo "  https://nextcloud.homelab.local → Dateien → ${MOUNT_NAME}"
  echo ""
  echo "  Verify:"
  echo "    kubectl exec -n ${NAMESPACE} ${POD_NAME} -- \\"
  echo "      su -s /bin/sh www-data -c 'php /var/www/html/occ files_external:list'"
fi
echo "============================================"
