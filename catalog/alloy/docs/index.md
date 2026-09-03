## What it is

Grafana Alloy is a telemetry collector agent — the successor to Grafana's
older Promtail log shipper. In this cluster it runs as a Kubernetes
`DaemonSet`, so a copy runs on every node. Each instance discovers the pods
running on its own node via the Kubernetes API, tails their logs, and also
reads a host-local file of Cilium Hubble network-flow logs, then forwards
both streams to Loki.

## Why it's here

The cluster needs a way to get container logs and network-flow data off
every node (2 Hetzner Cloud servers + 2 home nodes) and into one searchable
place (Loki/Grafana) without each node needing bespoke config. Alloy fills
that role:

- **Pod logs**: discovers pods via `discovery.kubernetes` (role `pod`),
  filters to only the pods scheduled on its own node (via a `NODE_NAME`
  downward-API env var matched against `__meta_kubernetes_pod_node_name`),
  and relabels them with `namespace`, `pod`, `container`, `app`, and `node`
  labels before shipping to Loki.
- **Hubble flow logs**: Cilium's `hubble.export.static` feature (configured
  in `ansible/files/cilium-values.yaml`) writes network-flow events to
  `/var/run/cilium/hubble/events.log` on each host. Alloy mounts that host
  path and ships the file's contents to Loki under a `job="hubble-flows"`
  label, keyed by node. Per the in-repo comment, this is the data source for
  a planned 14-day CiliumNetworkPolicy usage analysis (working out which
  policies are actually being hit before tightening them).

Both streams land in the same Loki instance, so both application logs and
network flows can be correlated and filtered from the same Grafana Explore
view using LogQL, e.g. `{job="hubble-flows", node="k3s-server"}`.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/alloy.yaml`
- **Chart**: `grafana/alloy` (repo `https://grafana.github.io/helm-charts`),
  `targetRevision: "1.11.1"` — pinned directly in the Application manifest
  (no separate `k8s/values/` file, no local chart; all values are inlined
  under `spec.source.helm.values`).
- **Namespace**: `monitoring` (deployed alongside Loki and the
  kube-prometheus-stack, even though Alloy itself is a standalone Helm
  release with no chart dependency on either).
- **Secrets**: none — Alloy has no `ExternalSecret` and needs no
  credentials to talk to Loki (in-cluster, unauthenticated
  `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`).
- **Ingress**: none — Alloy is not exposed outside the cluster.
- **Key values-file details worth knowing before editing** (called out in
  code comments in the Application manifest itself, because the chart's
  layout is non-obvious):
  - `controller.type: daemonset`
  - extra host volumes go under `controller.volumes.extra` (not a top-level
    `volumes:` key)
  - extra container mounts go under `alloy.mounts.extra` (not a top-level
    `mounts:` key)
  - there is no `extraConfig` append mechanism — the entire Alloy River
    config is set as one blob via `alloy.configMap.content`
  - resource requests/limits: 64Mi/50m requested, 256Mi/150m limit per pod

## How to change it

- **Edit collection/relabeling logic**: change the River config under
  `alloy.configMap.content` in `k8s/argocd/applications/alloy.yaml`. This is
  the full config, not a patch — read the existing blocks
  (`discovery.kubernetes`, `discovery.relabel`, `loki.source.kubernetes`,
  `local.file_match`, `loki.source.file`, `loki.write`) before changing
  anything, since there's no merge with chart defaults.
- **Bump the chart version**: update `spec.source.targetRevision`. The
  in-repo comment on this Application notes the pinned version should be
  checked against `helm search repo grafana/alloy --versions` before
  changing it, since the chart's internal layout (`controller.volumes.extra`
  vs a top-level `volumes:` key, etc.) has changed between versions before.
- **Point Alloy at a different Loki endpoint**: change the URL in the
  `loki.write "default"` block's `endpoint.url`.
- **Add more scraped sources**: extend the River config with additional
  `discovery.*` / `loki.source.*` components and add them to the
  `forward_to` list of `loki.write.default.receiver`.
- There is no `scripts/setup-alloy.sh` — this service needs no Vault-backed
  secrets to bootstrap.
