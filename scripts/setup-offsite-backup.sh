#!/bin/bash
set -euo pipefail
# =============================================================================
#  setup-offsite-backup.sh
#  Seeds Vault for the offsite backup (Garage -> restic -> Hetzner Storage
#  Box, context-hub#36) at 'homelab/backup/offsite-backup-secret':
#
#    restic-password                 new, random (the repository key!)
#    ssh-privatekey / ssh-publickey  new ed25519 key for the Storage Box
#    known-hosts                     pinned host keys of the Storage Box
#    storage-box-host/-user/-port    taken from the old restic path
#                                    homelab/infrastructure/restic-ssh, or
#                                    from STORAGE_BOX_HOST/_USER/_PORT
#    garage-access-key-id / garage-secret-access-key
#                                    new Garage key, READ-ONLY on the buckets
#
#  Prints nothing secret. At the end it prints the public key and the
#  command that installs it on the Storage Box, and how to copy the restic
#  password into your password manager.
#
#  IDEMPOTENT: if the Vault path already exists, nothing is changed.
#
#  USAGE:
#    export VAULT_TOKEN="..."
#    ./scripts/setup-offsite-backup.sh
# =============================================================================

VAULT_NS="security"
VAULT_POD="vault-0"
VAULT_PATH="homelab/backup/offsite-backup-secret"
OLD_PATH="homelab/infrastructure/restic-ssh"
GARAGE_NS="infrastructure"
GARAGE_POD="garage-0"
KEY_NAME="offsite-backup-reader"
BUCKETS=(velero-backups cnpg-backups forgejo-backups archive)

: "${VAULT_TOKEN:?Bitte VAULT_TOKEN als Env-Var setzen}"

vault_exec() {
  kubectl exec -i -n "$VAULT_NS" "$VAULT_POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$VAULT_TOKEN" vault "$@"
}
garage_exec() {
  kubectl exec -n "$GARAGE_NS" "$GARAGE_POD" -c garage -- /garage "$@"
}

if vault_exec kv get "secret/${VAULT_PATH}" &>/dev/null; then
  echo "==> ${VAULT_PATH} existiert bereits in Vault - nichts zu tun."
  exit 0
fi

echo "==> Storage-Box-Zugangsdaten ermitteln..."
H="${STORAGE_BOX_HOST:-$(vault_exec kv get -field=storage-box-host "secret/${OLD_PATH}" 2>/dev/null || true)}"
U="${STORAGE_BOX_USER:-$(vault_exec kv get -field=storage-box-user "secret/${OLD_PATH}" 2>/dev/null || true)}"
P="${STORAGE_BOX_PORT:-$(vault_exec kv get -field=storage-box-port "secret/${OLD_PATH}" 2>/dev/null || echo 23)}"
[[ -n "$H" && -n "$U" ]] || { echo "FEHLER: Host/User weder im alten Pfad noch in STORAGE_BOX_HOST/_USER."; exit 1; }
echo "    ${U}@${H}:${P}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "==> Host-Keys der Storage Box pinnen..."
ssh-keyscan -p "$P" -T 10 "$H" 2>/dev/null > "$TMP/known_hosts"
[[ -s "$TMP/known_hosts" ]] || { echo "FEHLER: ssh-keyscan lieferte nichts."; exit 1; }

echo "==> SSH-Key und Restic-Passwort erzeugen..."
ssh-keygen -q -t ed25519 -N '' -C "homelab-offsite-backup" -f "$TMP/id_ed25519"
openssl rand -base64 48 | tr -d '\n' > "$TMP/restic-password"

echo "==> Garage-Key '${KEY_NAME}' (nur Lesen) anlegen..."
if ! out=$(garage_exec key create "$KEY_NAME" 2>&1); then
  grep -qi "already exists" <<<"$out" || { echo "FEHLER: $out" | tail -3; exit 1; }
fi
for b in "${BUCKETS[@]}"; do
  garage_exec bucket allow --read --key "$KEY_NAME" "$b" >/dev/null 2>&1
done
KEY_INFO=$(garage_exec key info "$KEY_NAME" --show-secret 2>/dev/null)
GID=$(grep -i "Key ID:" <<<"$KEY_INFO" | awk '{print $NF}')
GSEC=$(grep -i "Secret key:" <<<"$KEY_INFO" | awk '{print $NF}')
[[ -n "$GID" && -n "$GSEC" ]] || { echo "FEHLER: Garage-Key nicht lesbar."; exit 1; }

echo "==> Nach Vault schreiben (Werte werden nicht ausgegeben)..."
GID="$GID" GSEC="$GSEC" H="$H" U="$U" P="$P" python3 - "$TMP" <<'PY' | vault_exec kv put "secret/homelab/backup/offsite-backup-secret" - >/dev/null
import json, os, sys
t = sys.argv[1]
read = lambda f: open(os.path.join(t, f)).read()
print(json.dumps({
    "restic-password": read("restic-password"),
    "ssh-privatekey": read("id_ed25519"),
    "ssh-publickey": read("id_ed25519.pub"),
    "known-hosts": read("known_hosts"),
    "storage-box-host": os.environ["H"],
    "storage-box-user": os.environ["U"],
    "storage-box-port": os.environ["P"],
    "garage-access-key-id": os.environ["GID"],
    "garage-secret-access-key": os.environ["GSEC"],
}))
PY

kubectl annotate externalsecret offsite-backup-secret -n backup \
  force-sync="$(date +%s)" --overwrite 2>/dev/null ||
  echo "    (ExternalSecret noch nicht deployt - wird beim naechsten Sync abgeholt)"

cat <<EOF

==> Fertig. Noch zwei Schritte von Hand:

1. Public Key auf der Storage Box eintragen (fragt das Storage-Box-Passwort ab):

   echo '$(cat "$TMP/id_ed25519.pub")' | ssh -p ${P} ${U}@${H} install-ssh-key

2. Restic-Passwort AUSSERHALB des Clusters sichern (Passwortmanager), sonst ist
   das Offsite-Backup bei Totalverlust nicht entschlüsselbar:

   kubectl exec -n ${VAULT_NS} ${VAULT_POD} -- env VAULT_ADDR=http://127.0.0.1:8200 \\
     VAULT_TOKEN="\$VAULT_TOKEN" vault kv get -field=restic-password secret/${VAULT_PATH}

Der alte Pfad ${OLD_PATH} wird danach nicht mehr gebraucht.
EOF
