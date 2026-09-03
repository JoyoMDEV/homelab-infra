## What it is

The `monitoring` Application deploys the `kube-prometheus-stack` Helm
chart, which bundles Prometheus (metrics collection/storage), Grafana
(dashboards/visualization), Alertmanager (alert routing), the Prometheus
Operator (manages `ServiceMonitor`/`PodMonitor`/`PrometheusRule` CRDs),
kube-state-metrics, and node-exporter. This is verified directly from
`k8s/argocd/applications/monitoring.yaml`'s `chart:
kube-prometheus-stack` / `repoURL:
https://prometheus-community.github.io/helm-charts`.

## Why it's here

This is the cluster's single metrics-and-alerting stack, covering both
infrastructure and workloads across the 4 nodes:

- **Prometheus** scrapes any `ServiceMonitor`/`PodMonitor` in the cluster
  (`serviceMonitorSelectorNilUsesHelmValues: false` and
  `podMonitorSelectorNilUsesHelmValues: false` — i.e. not restricted to
  ones created by this Helm release, so other Applications like Loki can
  register their own and get picked up automatically). Retains 30 days /
  15GB on a 20Gi PVC.
- **Grafana** is the single dashboard UI for the whole cluster, and is also
  wired to Loki as a second datasource (`additionalDataSources` pointing at
  `http://loki.monitoring.svc.cluster.local:3100`), so logs and metrics are
  browsable from the same tool. Login is via Keycloak OIDC
  (`auth.generic_oauth`, client `grafana`, realm `homelab`) rather than a
  static admin password — `adminPassword` is deliberately left empty. The
  `role_attribute_path` maps members of the Keycloak `grafana-admins` group
  to the Grafana `Admin` role and everyone else to `Viewer`. TLS
  verification against the internal CA is skipped for the OIDC endpoints
  (`tls_skip_verify_insecure: true`) because mounting the self-signed CA
  into the Grafana OAuth client reportedly doesn't work reliably via
  `extraSecretMounts` — a documented, deliberate tradeoff, not an oversight.
- **Alertmanager** routes alerts to a Discord webhook by default
  (`receiver: "discord"`), with critical-severity alerts repeating hourly
  instead of the default 12h, and the built-in `Watchdog` alert routed to a
  no-op `"null"` receiver (it exists purely to prove the alerting pipeline
  is alive). The webhook URL is read from a file mounted from a Secret,
  not a template variable.
- `defaultRules` selectively enables Prometheus alerting/recording rules
  for components that actually exist in this k3s cluster, and explicitly
  disables rule sets for components k3s doesn't run standalone
  (`etcd: false` since k3s uses embedded etcd, `kubeControllerManager:
  false`, `kubeProxy: false`, `kubeSchedulerAlerting/Recording: false`) —
  avoids permanently-firing alerts for services that were never deployed.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/monitoring.yaml`
- **Chart**: `kube-prometheus-stack` (repo
  `https://prometheus-community.github.io/helm-charts`),
  `targetRevision: 82.10.5` — values are inlined directly under
  `spec.source.helm.values` (no separate `k8s/values/` file, no local
  chart).
- **Namespace**: `monitoring`.
- **Ingress**: Grafana only, `traefik` ingress class, host
  `grafana.homelab.local`, TLS via the `homelab-wildcard-tls` secret
  (internal CA). Prometheus and Alertmanager have no ingress defined in
  this values file — in-cluster access only.
- **Secrets**: one `ExternalSecret`,
  `k8s/security/external-secrets/monitoring/grafana-keycloak-secret.yaml`,
  in the `monitoring` namespace, sourced from Vault path
  `homelab/monitoring/grafana-keycloak-secret`. It carries two keys used by
  two different components of this same stack:
  - `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` — Grafana's Keycloak OIDC client
    secret, injected via `grafana.envFromSecrets`.
  - `ALERTMANAGER_DISCORD_WEBHOOK_URL` — Alertmanager's Discord webhook,
    mounted into the pod via `alertmanager.extraSecrets` and referenced by
    file path (`url_file: /etc/alertmanager/secrets/grafana-keycloak-secret/ALERTMANAGER_DISCORD_WEBHOOK_URL`).
  A single shared Secret is used deliberately (per the comment in
  `scripts/setup-monitoring.sh`) because both values need to be mounted as
  files into different pods, and one Secret is simpler to manage than two.
- **Storage**: Grafana 5Gi PVC, Prometheus 20Gi PVC (30d/15GB retention),
  Alertmanager 2Gi PVC.
- **CRD upgrades**: `crds.upgradeJob.enabled: true` — CRDs are upgraded via
  an automatic Job as of chart 68.x+, not via manual `kubectl apply`.

## How to change it

- **Seed/rotate the secrets**: run `scripts/setup-monitoring.sh` (requires
  `VAULT_TOKEN` env var and a running cluster). It prompts for the Grafana
  Keycloak client secret and an optional Discord webhook URL, writes both
  to Vault at `homelab/monitoring/grafana-keycloak-secret`, and force-syncs
  the `ExternalSecret`. If no Discord URL is given it writes a
  `REPLACE_ME` placeholder so the Alertmanager secret mount doesn't fail,
  and prints the `vault kv patch` command to fix it up later. It also
  bootstraps the `homelab-ca` secret in the `monitoring` namespace if
  missing, and creates/labels the namespace itself.
- **Change alert routing**: edit `alertmanager.config` (route tree,
  receivers, inhibit rules) in `k8s/argocd/applications/monitoring.yaml`.
- **Change Grafana OIDC behavior**: edit `grafana."grafana.ini"` (e.g.
  `role_attribute_path` for admin/viewer mapping, `auth_url`/`token_url` if
  Keycloak realm changes) in the same file. The Keycloak `grafana` client
  itself is set up per `docs/keycloak-setup.md` (section 6, referenced in
  `scripts/setup-monitoring.sh`), not by this repo directly.
- **Add/remove default alert rule groups**: toggle entries under
  `defaultRules.rules` — set to `true`/`false` per component, matching what
  the k3s cluster actually runs.
- **Bump the chart version**: update `spec.source.targetRevision` against
  `helm search repo prometheus-community/kube-prometheus-stack --versions`;
  check the CRDs upgrade cleanly (the `crds.upgradeJob` should handle this
  automatically for jumps within the automated-upgrade-supporting range).
- Full runbook: `docs/monitoring-setup.md`.
