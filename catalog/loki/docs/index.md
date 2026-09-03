## What it is

Loki is Grafana's log-aggregation backend. It stores and indexes the log
streams Alloy ships to it and exposes them for querying through Grafana
(via LogQL), the same way Prometheus exposes metrics via PromQL.

## Why it's here

The cluster's pods and Cilium Hubble network flows produce logs on 4 nodes
(2 Hetzner Cloud servers + 2 home nodes) that would otherwise only be
reachable with `kubectl logs` per-pod, per-node. Loki gives a single place
to search all of that:

- Runs in `SingleBinary` deployment mode — all Loki components (distributor,
  ingester, querier, etc.) in one pod, which is the right tradeoff for a
  homelab's scale versus running Loki's fully distributed microservices
  topology. The values file explicitly zeroes out replicas for `backend`,
  `read`, `write`, `ingester`, `querier`, `queryFrontend`, `queryScheduler`,
  `distributor`, `compactor`, and `indexGateway` to prevent the chart from
  standing up any of those separately.
- Stores data on a 20Gi PVC using the filesystem object store and TSDB index
  (schema `v13`, the non-deprecated successor to `boltdb-shipper`) — no
  MinIO or other external object storage is used (`minio.enabled: false`).
- Retains logs for 720h (30 days), rejects samples older than 168h
  (7 days), and runs its own compactor for retention enforcement
  (`compactor.retention_enabled: true`).
- Auth is disabled (`auth_enabled: false`) since this is a single-tenant,
  in-cluster-only deployment — nothing routes to Loki from outside the
  cluster.
- Loki's own Grafana instance is explicitly disabled (`grafana.enabled:
  false`) — Grafana is provided by the `monitoring` Application
  (kube-prometheus-stack) instead, and is wired to this Loki as an
  additional datasource there.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/loki.yaml`
- **Chart**: `grafana/loki` (repo `https://grafana.github.io/helm-charts`),
  `targetRevision: 6.55.0` — values are inlined directly in the Application
  manifest under `spec.source.helm.values` (no separate `k8s/values/` file,
  no local chart).
- **Namespace**: `monitoring`.
- **Storage**: filesystem-backed, 20Gi PVC (`singleBinary.persistence`),
  requests 256Mi/100m, limit 512Mi.
- **Secrets**: none — Loki has no `ExternalSecret`; it needs no credentials.
- **Ingress**: none — Loki is only reachable in-cluster, at
  `http://loki.monitoring.svc.cluster.local:3100`. Alloy pushes to
  `/loki/api/v1/push` on that address; Grafana's Loki datasource
  (configured in the `monitoring` Application) reads from the same address.
- **Prometheus integration**: `monitoring.serviceMonitor.enabled: true`
  (labeled `release: kube-prometheus-stack` so the cluster's Prometheus
  operator picks it up) and `monitoring.rules.enabled: true` for Loki's own
  recording/alerting rules.
- Note: the values file comments explicitly warn that the `grafana/loki`
  chart has no Alloy sub-chart dependency, so an `alloy:` key in this
  Application's values would be silently ignored — Alloy is deliberately a
  separate ArgoCD Application (`k8s/argocd/applications/alloy.yaml`).

## How to change it

- **Change retention**: edit `loki.limits_config.retention_period` (and
  `reject_old_samples_max_age` if extending how far back late data is
  accepted) in `k8s/argocd/applications/loki.yaml`.
- **Resize storage**: edit `singleBinary.persistence.size` — note this
  requires a PVC resize (StorageClass must support volume expansion) rather
  than a simple redeploy if increasing beyond the current 20Gi.
- **Bump the chart version**: update `spec.source.targetRevision` against
  `helm search repo grafana/loki --versions`, then re-check the values keys
  against the new chart's `values.yaml` (deployment-mode replica keys and
  schema config are the parts most likely to shift between versions).
- **Move off SingleBinary mode**: would mean setting `deploymentMode` to one
  of the distributed modes and giving `backend`/`read`/`write` etc. real
  replica counts — a bigger change, only worth it if the cluster's log
  volume outgrows a single pod.
- There is no `scripts/setup-loki.sh` — this service needs no Vault-backed
  secrets to bootstrap.
