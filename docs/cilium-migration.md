# Migration: Flannel → Cilium

## Ausgangslage

- k3s läuft mit `--flannel-iface tailscale0` — das VXLAN-Overlay von Flannel
  tunnelt bereits durch das Tailscale-Mesh, nicht über die öffentlichen/privaten
  Node-IPs direkt.
- Nodes: `k3s-server` (Hetzner CX53, Cloud), Mini-PC (Home, 16GB/4C), optional
  Raspberry Pi 4B (Home, throttled im Sommer — als Worker eher ungeeignet für
  Dauerlast, ggf. nur für leichte/stateless Workloads vorsehen).
- kube-proxy ist aktiv (nicht deaktiviert) — Migration erfolgt schrittweise,
  kube-proxy-Replacement ist ein separater, späterer Schritt, kein Teil dieser
  Migration.

## Warum nicht "einfach Cilium drüber installieren"

k3s erlaubt nur ein aktives CNI. Ein Node kann zu einem Zeitpunkt entweder
Flannel- oder Cilium-verwaltete Pods haben — nie beide gleichzeitig auf
demselben Node. Die Migration läuft daher **Node für Node**, mit einem
kurzen Fenster, in dem Pods auf dem gerade migrierten Node ihre Nachbarn auf
noch-nicht-migrierten Nodes nicht erreichen (deshalb: Wartungsfenster planen,
nicht mitten am Tag).

## Phase 0 — Vorbereitung (kein Risiko, jederzeit machbar)

1. **Testen, nicht am Live-Cluster.** Du hast mit Minikube schon Cilium
   getestet — nutze das weiter, um genau die Werte zu validieren, die unten
   im Helm-Values-Block stehen, bevor sie an den echten Cluster gehen.
2. Cilium CLI lokal vorhalten (hattest du schon eingerichtet).
3. Backup-Check: Velero-Snapshot vor der Migration auslösen
   (`velero backup create pre-cilium-migration`), CNPG-Cluster hat eigenes
   Barman-Backup — beides vorhanden, nichts Neues nötig.
4. Node-Reihenfolge festlegen: **zuerst den unwichtigsten Node**, also den
   Mini-PC oder Pi, NICHT den Hetzner-Server (Control Plane + Samba AD DC).
   Falls etwas schiefgeht, ist der Control-Plane-Node der letzte, den du
   anfasst.

## Phase 1 — Cilium installieren, Flannel-Ersatz vorbereiten

Cilium wird mit `helm install` installiert, aber im Modus, der zur
bestehenden Tailscale-Topologie passt:

```yaml
# cilium-values.yaml
tunnelProtocol: vxlan # wie Flannel: Overlay, kein native routing nötig
devices: tailscale0 # Cilium bindet sich an dieselbe Schnittstelle wie Flannel vorher
ipam:
  mode: kubernetes
k8sServiceHost: <tailscale-ip-des-servers>
k8sServicePort: 6443
kubeProxyReplacement: false # bewusst NICHT in diesem Schritt anfassen
cni:
  exclusive: false # wichtig während der Migration: erlaubt Koexistenz auf CNI-Config-Ebene
operator:
  replicas: 1 # Homelab, kein HA-Operator nötig
```

`devices: tailscale0` ist der entscheidende Wert — ohne ihn versucht Cilium,
sich an die "normale" Netzwerkkarte zu binden, und die Overlay-Pakete würden
nie durchs Tailscale-Mesh laufen, genau das Problem, das euch sonst beim
Hetzner↔Home-Traffic komplett bricht.

```bash
helm install cilium cilium/cilium --version 1.16.x \
  --namespace kube-system \
  -f cilium-values.yaml
```

Cilium läuft jetzt parallel zu Flannel, verwaltet aber noch keine Nodes.

## Phase 2 — Node für Node umziehen

Pro Node (beginnend mit Mini-PC/Pi):

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

Auf dem Node selbst:

```bash
# k3s-agent neu starten mit --flannel-backend=none für diesen Node ist NICHT
# node-individuell möglich (Flannel-Backend ist ein Cluster-weiter k3s-Server-Wert).
# Deshalb: der Cluster-weite Flannel-Backend-Wechsel passiert erst, wenn ALLE
# Worker migriert sind — bis dahin bleibt Flannel als Fallback-CNI-Config
# aktiv, Cilium übernimmt Nodes über die CNI-Konfig-Datei-Priorität
# (/etc/cni/net.d/ — Cilium schreibt seine Config mit höherer Priorität,
# sobald der Cilium-Agent-Pod auf dem Node läuft).
systemctl restart k3s-agent   # oder k3s (Server) beim letzten Node
```

```bash
kubectl uncordon <node>
```

Cilium-Agent-DaemonSet startet auf dem Node, übernimmt ab dann alle neuen
Pods dort. Wiederholen für jeden weiteren Node.

**Der Hetzner-Server (Control Plane) ist immer der letzte Node.** Erst wenn
alle Worker auf Cilium laufen, den Server-Node migrieren — und danach den
k3s-Server-Start-Parameter dauerhaft auf `--flannel-backend=none` umstellen
(verhindert, dass ein zukünftiger Node-Join wieder Flannel-CNI-Configs
schreibt).

## Phase 3 — Cleanup

- Flannel-DaemonSet aus `kube-system` entfernen
- `cni.exclusive: true` in den Cilium-Values setzen (jetzt sicher, da kein
  Flannel mehr existiert)
- `cilium status` und `cilium connectivity test` clusterweit laufen lassen
- Ansible-Rolle `k3s_server`/`k3s_agent` aktualisieren: `--flannel-backend=none`
  fest in die Install-Kommandos schreiben, damit ein Rebuild des Clusters
  (z. B. bei Server-Neuaufsetzung) direkt mit Cilium startet statt mit
  Flannel + manueller Nachmigration

## Risiken speziell für dein Setup

- **Pi im Sommer:** Falls der Pi während der Migration thermisch throttlet,
  kann `kubectl drain` hängen bleiben (Kubelet antwortet langsam). Migration
  an einem kühleren Tag/Uhrzeit einplanen, oder Pi vorerst ganz aus der
  Migration raushalten und nur als optionalen Node später hinzufügen.
- **Samba AD DC läuft auf dem Server-Node** (nicht als Pod, sondern nativ auf
  dem Host laut README) — die Migration des Server-Nodes betrifft nur die
  k3s-CNI-Ebene, nicht Samba selbst, sollte also unabhängig sein. Trotzdem:
  Migration außerhalb der Zeiten planen, in denen Samba-Auth-Last hoch ist.
