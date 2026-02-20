#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-nextcloud-storage.sh
#  Konfiguriert die Hetzner Storage Box als External Storage in Nextcloud.
#
#  PROTOKOLL: WebDAV (nicht SFTP)
#  Das Nextcloud fpm-alpine Image enthält keine php-ssh2 Extension, daher
#  funktioniert SFTP nicht. Die Storage Box unterstützt WebDAV (Port 443),
#  das funktioniert out-of-the-box ohne zusätzliche PHP-Extensions.
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
# Kein Leerzeichen im Mount-Namen – Nextcloud 32 erzeugt sonst //Mount-Name
MOUNT_NAME="StorageBox"

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
occ() {
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" \
    -- su -s /bin/sh www-data -c "php /var/www/html/occ $*"
}

occ_output() {
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" \
    -- su -s /bin/sh www-data -c "php /var/www/html/occ $*" 2>&1
}

# =============================================================================
echo ""
echo "============================================"
echo "  Nextcloud Storage Box Setup (WebDAV)"
if $DRY_RUN; then
  echo "  Modus: DRY-RUN (keine Änderungen)"
fi
echo "============================================"
echo ""

# ─── Step 1: Voraussetzungen prüfen ──────────────────────────────────────────
info "Schritt 1/6: Voraussetzungen prüfen..."

if ! command -v kubectl &>/dev/null; then
  error "kubectl nicht gefunden."
  exit 1
fi
success "kubectl verfügbar"

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  error "Namespace '${NAMESPACE}' nicht gefunden."
  exit 1
fi
success "Namespace '${NAMESPACE}' existiert"

POD_NAME=$(kubectl get pod -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=nextcloud \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${POD_NAME}" ]]; then
  error "Kein laufender Nextcloud Pod gefunden."
  exit 1
fi
success "Nextcloud Pod: ${POD_NAME}"

if ! kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  error "Secret '${SECRET_NAME}' nicht gefunden."
  exit 1
fi
success "Secret '${SECRET_NAME}' gefunden"

STORAGE_BOX_PW=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
  -o jsonpath="{.data.${STORAGE_BOX_SECRET_KEY}}" 2>/dev/null | base64 -d || true)

if [[ -z "${STORAGE_BOX_PW}" ]]; then
  error "Key '${STORAGE_BOX_SECRET_KEY}' nicht im Secret gefunden."
  exit 1
fi
success "Storage Box Passwort aus Secret gelesen"

# ─── Step 2: Storage Box Verbindungsdaten ermitteln ──────────────────────────
info "Schritt 2/6: Storage Box Verbindungsdaten ermitteln..."

STORAGE_BOX_HOST=""
STORAGE_BOX_USER=""

if [[ -d "terraform" ]] && command -v terraform &>/dev/null; then
  info "  Lese Storage Box Daten aus Terraform Outputs..."
  cd terraform
  STORAGE_BOX_HOST=$(terraform output -raw storage_box_host 2>/dev/null || true)
  STORAGE_BOX_USER=$(terraform output -raw storage_box_username 2>/dev/null || true)
  cd ..
fi

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

WEBDAV_URL="https://${STORAGE_BOX_HOST}"

success "Storage Box Host: ${STORAGE_BOX_HOST}"
success "Storage Box User: ${STORAGE_BOX_USER}"
success "WebDAV URL:       ${WEBDAV_URL}"
success "Remote Path:      ${STORAGE_BOX_REMOTE_PATH}"

# ─── Step 3: WebDAV-Verbindung testen ────────────────────────────────────────
info "Schritt 3/6: WebDAV-Verbindung zur Storage Box testen..."

WEBDAV_TEST=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c nextcloud -- \
  curl -sf \
    --user "${STORAGE_BOX_USER}:${STORAGE_BOX_PW}" \
    -X PROPFIND \
    "${WEBDAV_URL}${STORAGE_BOX_REMOTE_PATH}/" \
    -o /dev/null -w "%{http_code}" 2>&1 || true)

if [[ "${WEBDAV_TEST}" == "207" ]]; then
  success "WebDAV-Verbindung erfolgreich (HTTP 207)"
elif [[ "${WEBDAV_TEST}" == "404" ]]; then
  warn "Verzeichnis '${STORAGE_BOX_REMOTE_PATH}' nicht gefunden – wird angelegt..."
  if ! $DRY_RUN; then
    kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c nextcloud -- \
      curl -sf \
        --user "${STORAGE_BOX_USER}:${STORAGE_BOX_PW}" \
        -X MKCOL \
        "${WEBDAV_URL}${STORAGE_BOX_REMOTE_PATH}/" 2>&1 || true
    success "Verzeichnis angelegt"
  fi
else
  warn "WebDAV-Test: HTTP ${WEBDAV_TEST} – möglicherweise Verbindungsproblem"
  echo ""
  read -rp "    Trotzdem fortfahren? (j/N): " CONTINUE
  if [[ "${CONTINUE}" != "j" ]] && [[ "${CONTINUE}" != "J" ]]; then
    echo "Abbruch."
    exit 1
  fi
fi

# ─── Step 4: files_external App aktivieren ───────────────────────────────────
info "Schritt 4/6: External Storage App in Nextcloud aktivieren..."

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

# ─── Step 5: Bestehende Konfiguration prüfen / zurücksetzen ──────────────────
info "Schritt 5/6: Bestehende External Storage Konfiguration prüfen..."

SKIP_CREATE=false
EXISTING_MOUNTS=$(occ_output "files_external:list --output=json" 2>/dev/null || echo "[]")

EXISTING_ID=$(echo "${EXISTING_MOUNTS}" | \
  python3 -c "
import sys, json
try:
    mounts = json.load(sys.stdin)
    for m in mounts:
        config = m.get('configuration', {})
        name = m.get('mount_point', '')
        host = config.get('host', '')
        if '${MOUNT_NAME}' in name or '${STORAGE_BOX_HOST}' in host:
            print(m.get('mount_id', ''))
            break
except: pass
" 2>/dev/null || true)

if [[ -n "${EXISTING_ID}" ]]; then
  if $RESET; then
    warn "Bestehende Konfiguration gefunden (ID: ${EXISTING_ID}). Wird entfernt (--reset)..."
    if ! $DRY_RUN; then
      occ "files_external:delete ${EXISTING_ID} --yes" 2>&1 || true
      success "Alte Konfiguration entfernt"
      EXISTING_ID=""
    fi
  else
    warn "Storage Box bereits konfiguriert (Mount ID: ${EXISTING_ID})."
    warn "Zum Neu-Anlegen: $0 --reset"
    echo ""
    echo "    Aktuelle Konfiguration:"
    occ_output "files_external:list" 2>/dev/null || true
    SKIP_CREATE=true
  fi
fi

# ─── Step 6: WebDAV Mount anlegen ────────────────────────────────────────────
info "Schritt 6/6: Storage Box als WebDAV External Storage einrichten..."

if [[ "${SKIP_CREATE}" == "true" ]]; then
  warn "Mount bereits vorhanden, überspringe."
else
  if $DRY_RUN; then
    dryrun "occ files_external:create '${MOUNT_NAME}' 'dav' 'password::password' \\"
    dryrun "  --config host=${WEBDAV_URL} \\"
    dryrun "  --config root=${STORAGE_BOX_REMOTE_PATH} \\"
    dryrun "  --config user=${STORAGE_BOX_USER} \\"
    dryrun "  --config secure=true"
  else
    occ "files_external:create \
      '${MOUNT_NAME}' \
      'dav' \
      'password::password' \
      --config host='${WEBDAV_URL}' \
      --config root='${STORAGE_BOX_REMOTE_PATH}' \
      --config user='${STORAGE_BOX_USER}' \
      --config password='${STORAGE_BOX_PW}' \
      --config secure='true'" 2>&1

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
      occ "files_external:applicable --add-group everyone ${NEW_ID}" 2>&1 || true
      success "Mount für alle Benutzer freigegeben"
    else
      warn "Mount wurde angelegt, ID konnte nicht ermittelt werden."
    fi

    # Files-Cache aktualisieren
    occ "files:scan --path='/admin/files' --quiet" 2>&1 || true

    # Mount-Status anzeigen
    echo ""
    echo "    Aktuelle External Storage Konfiguration:"
    occ_output "files_external:list" 2>/dev/null || true
  fi
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
echo "  Storage Box: ${WEBDAV_URL}"
echo "  User:        ${STORAGE_BOX_USER}"
echo "  Protokoll:   WebDAV (HTTPS Port 443)"
echo "  Remote Path: ${STORAGE_BOX_REMOTE_PATH}"
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
