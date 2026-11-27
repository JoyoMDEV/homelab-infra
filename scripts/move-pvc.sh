#!/bin/bash
set -euo pipefail
# =============================================================================
#  move-pvc.sh
#  Moves the data of a local-path PVC to another node and rebinds the PVC
#  (same name, same labels/annotations/ownerReferences) to a new hostPath PV
#  there. Written for moving off k3s-server (context-hub#40) and Garage onto
#  the Pi HDD (context-hub#41).
#
#  The workload must already be stopped (no pod may mount the PVC), and must
#  STAY stopped for the whole run:
#    - Turn off auto-sync on BOTH the root app and the service's app, then
#      scale the Deployment/StatefulSet to 0:
#        kubectl -n argocd patch application root      --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
#        kubectl -n argocd patch application <app>     --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
#      (Restore afterwards with a merge patch of {"automated":{"prune":true,"selfHeal":true}}.)
#      The skip-reconcile annotation is NOT enough: on 2026-11-27 an already
#      queued auto-sync scaled Nextcloud back up mid-copy.
#    - CNPG clusters:    kubectl annotate cluster <name> cnpg.io/hibernation=on
#
#  What it does:
#    1. Copies the old PV directory host-to-host: tar (numeric owners,
#       permissions) streamed over socat between two helper pods.
#    2. Verifies source and target with a SHA-256 over every file
#       (path + content) plus file and directory counts.
#    3. Creates a hostPath PV on the target node (Retain), sets the OLD PV to
#       Retain as well, deletes the old PVC and recreates it bound to the
#       new PV.
#  The old PV and its data stay on the source node as a fallback. Delete
#  them later by hand (kubectl delete pv <old-pv>, then the directory).
#
#  USAGE:
#    ./scripts/move-pvc.sh <namespace> <pvc> <target-node> [target-base-dir]
#    target-base-dir defaults to /var/lib/rancher/k3s/storage
#
#  EXAMPLES:
#    ./scripts/move-pvc.sh infrastructure redis-data-redis-master-0 k3s-worker-minipc
#    ./scripts/move-pvc.sh infrastructure data-garage-0 k3s-worker-pi /mnt/data/k3s-storage
# =============================================================================

NS="${1:?namespace}"
PVC="${2:?pvc name}"
TARGET_NODE="${3:?target node}"
TARGET_BASE="${4:-/var/lib/rancher/k3s/storage}"
HELPER_NS="default"
IMAGE="alpine:3.20"
PORT=9000
RUN_ID="mv-$(date +%s)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; kubectl -n "$HELPER_NS" delete pod "${RUN_ID}-src" "${RUN_ID}-dst" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

say() { echo "==> $*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

# ── 0. Preconditions ─────────────────────────────────────────────────────────
kubectl -n "$NS" get pvc "$PVC" -o json > "$TMP/pvc.json" || die "PVC $NS/$PVC nicht gefunden"
OLD_PV=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['spec']['volumeName'])" "$TMP/pvc.json")
kubectl get pv "$OLD_PV" -o json > "$TMP/pv.json"
read -r SRC_NODE SRC_PATH SIZE <<<"$(python3 - "$TMP/pv.json" <<'PY'
import json,sys
pv=json.load(open(sys.argv[1]))
node=pv['spec']['nodeAffinity']['required']['nodeSelectorTerms'][0]['matchExpressions'][0]['values'][0]
path=(pv['spec'].get('hostPath') or pv['spec'].get('local'))['path']
print(node, path, pv['spec']['capacity']['storage'])
PY
)"
[ "$SRC_NODE" != "$TARGET_NODE" ] || die "PVC liegt bereits auf $TARGET_NODE"

USERS=$(kubectl -n "$NS" get pods -o json | python3 -c "
import json,sys
pvc=sys.argv[1]
for p in json.load(sys.stdin)['items']:
    for v in p['spec'].get('volumes',[]):
        if v.get('persistentVolumeClaim',{}).get('claimName')==pvc: print(p['metadata']['name'])" "$PVC")
[ -z "$USERS" ] || die "PVC wird noch von Pods genutzt: $USERS (Workload zuerst stoppen)"

NEW_DIR="${TARGET_BASE}/${NS}_${PVC}"
NEW_PV="${OLD_PV}-on-${TARGET_NODE}"
say "$NS/$PVC: $SRC_NODE:$SRC_PATH  ->  $TARGET_NODE:$NEW_DIR  (PV $NEW_PV, $SIZE)"

# ── 1. Helper pods ───────────────────────────────────────────────────────────
helper() { # name node hostdir mountpoint readonly
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $HELPER_NS, labels: {app: move-pvc}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  nodeSelector: {kubernetes.io/hostname: $2}
  tolerations: [{operator: Exists}]
  containers:
    - name: c
      image: $IMAGE
      command: [sh, -c, "apk add --no-cache -q tar socat >/dev/null && touch /ready && sleep 7200"]
      volumeMounts: [{name: d, mountPath: $4, readOnly: $5}]
  volumes: [{name: d, hostPath: {path: $3, type: DirectoryOrCreate}}]
EOF
}
helper "${RUN_ID}-src" "$SRC_NODE" "$SRC_PATH" /src true
helper "${RUN_ID}-dst" "$TARGET_NODE" "$NEW_DIR" /dst false
for p in src dst; do
  kubectl -n "$HELPER_NS" wait --for=condition=Ready "pod/${RUN_ID}-$p" --timeout=180s >/dev/null
  for _ in $(seq 1 60); do kubectl -n "$HELPER_NS" exec "${RUN_ID}-$p" -- test -f /ready 2>/dev/null && break; sleep 2; done
done
ex() { kubectl -n "$HELPER_NS" exec "${RUN_ID}-$1" -- sh -c "$2"; }

[ -z "$(ex dst 'ls -A /dst')" ] || die "Zielverzeichnis $TARGET_NODE:$NEW_DIR ist nicht leer"

# ── 2. Copy ──────────────────────────────────────────────────────────────────
DST_IP=$(kubectl -n "$HELPER_NS" get pod "${RUN_ID}-dst" -o jsonpath='{.status.podIP}')
say "Kopiere ..."
kubectl -n "$HELPER_NS" exec "${RUN_ID}-dst" -- sh -c "socat -u TCP-LISTEN:$PORT,reuseaddr - | tar -C /dst --numeric-owner -xpf -" &
RECV=$!
sleep 3
ex src "tar -C /src --numeric-owner -cpf - . | socat -u - TCP:$DST_IP:$PORT"
wait $RECV

# ── 3. Verify ────────────────────────────────────────────────────────────────
say "Prüfe ..."
SUM='cd $0 && echo "files=$(find . -type f | wc -l) dirs=$(find . -type d | wc -l) hash=$(find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -c1-16)"'
# kubectl exec against a node's kubelet occasionally drops with "EOF";
# retry instead of letting set -e end the run silently.
sum_of() { for _ in 1 2 3; do out=$(ex "$1" "sh -c '$SUM' /$1") && { echo "$out"; return 0; }; sleep 5; done; return 1; }
S=$(sum_of src) || die "Prüfsumme der Quelle nicht ermittelbar, PVC bleibt unverändert"
D=$(sum_of dst) || die "Prüfsumme des Ziels nicht ermittelbar, PVC bleibt unverändert"
echo "    Quelle: $S"; echo "    Ziel:   $D"
[ "$S" = "$D" ] || die "Quelle und Ziel unterscheiden sich, PVC bleibt unverändert"

# ── 4. Rebind ────────────────────────────────────────────────────────────────
say "Binde PVC an neues PV ..."
python3 - "$TMP/pvc.json" "$TMP/pv.json" "$NEW_PV" "$NEW_DIR" "$TARGET_NODE" > "$TMP/new.json" <<'PY'
import json,sys
pvc=json.load(open(sys.argv[1])); pv=json.load(open(sys.argv[2]))
new_pv, new_dir, node = sys.argv[3:6]
drop=('pv.kubernetes.io/','volume.kubernetes.io/','volume.beta.kubernetes.io/','kubectl.kubernetes.io/last-applied')
ann={k:v for k,v in (pvc['metadata'].get('annotations') or {}).items() if not k.startswith(drop)}
sc=pvc['spec'].get('storageClassName','local-path')
newpv={'apiVersion':'v1','kind':'PersistentVolume','metadata':{'name':new_pv,'labels':{'moved-from':pv['metadata']['name'][:63]}},
 'spec':{'capacity':pv['spec']['capacity'],'accessModes':pv['spec']['accessModes'],'persistentVolumeReclaimPolicy':'Retain',
  'storageClassName':sc,'volumeMode':pv['spec'].get('volumeMode','Filesystem'),
  'hostPath':{'path':new_dir,'type':'DirectoryOrCreate'},
  'nodeAffinity':{'required':{'nodeSelectorTerms':[{'matchExpressions':[{'key':'kubernetes.io/hostname','operator':'In','values':[node]}]}]}}}}
meta={'name':pvc['metadata']['name'],'namespace':pvc['metadata']['namespace']}
if pvc['metadata'].get('labels'): meta['labels']=pvc['metadata']['labels']
if ann: meta['annotations']=ann
if pvc['metadata'].get('ownerReferences'): meta['ownerReferences']=pvc['metadata']['ownerReferences']
spec={'accessModes':pvc['spec']['accessModes'],'resources':pvc['spec']['resources'],'storageClassName':sc,
 'volumeMode':pvc['spec'].get('volumeMode','Filesystem'),'volumeName':new_pv}
print(json.dumps({'apiVersion':'v1','kind':'List','items':[newpv,{'apiVersion':'v1','kind':'PersistentVolumeClaim','metadata':meta,'spec':spec}]}))
PY
kubectl patch pv "$OLD_PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
# kubectl create, not apply: apply would record volumeName/storageClassName in
# last-applied-configuration, and ArgoCD's three-way merge would then try to
# remove them from the (immutable) bound PVC spec on every sync.
python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['items'][0]))" "$TMP/new.json" | kubectl create -f - >/dev/null
kubectl -n "$NS" delete pvc "$PVC" --wait=false >/dev/null
for _ in $(seq 1 180); do kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1 || break; sleep 1; done
if kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  die "altes PVC hängt im Löschen (nutzt ein Pod es wieder?). Zustand: altes PV $OLD_PV (Retain) hat die Daten, neues PV $NEW_PV ist angelegt, aber nicht gebunden. Workload stoppen, dann PV-claimRef bereinigen und neu starten."
fi
python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))['items'][1]))" "$TMP/new.json" | kubectl create -f - >/dev/null
for _ in $(seq 1 30); do [ "$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase}')" = Bound ] && break; sleep 1; done
say "Fertig: $(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.status.phase} -> {.spec.volumeName}')"
echo "    Altes PV $OLD_PV (Retain) mit Daten auf $SRC_NODE:$SRC_PATH bleibt als Rückfall liegen."
