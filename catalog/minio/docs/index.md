## What it is

MinIO (official `minio/minio` Helm chart) running as a single-node, standalone S3-compatible
object store, with both the S3 API and the web console exposed via Traefik ingress.

## Why it's here

It's the cluster's local S3 target for backups: CloudNativePG's Barman backups of the shared
`homelab-pg` Postgres cluster land in the `cnpg-backups` bucket
(`s3://cnpg-backups/`, see `k8s/infrastructure/postgres-cluster.yaml`), and Velero's cluster
backups use the `velero-backups` bucket. Both buckets are auto-created by the chart on install
(`buckets:` in the Application's inline values). MinIO itself isn't the durability layer, though
— per the comments in `k8s/argocd/applications/minio.yaml`, it's backed by a PVC and treated as
a cache; the real off-cluster durability comes from the `minio-backup-restic` CronJob (in the
`infrastructure` Application) that Restic-syncs MinIO's data to a Hetzner Storage Box nightly.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/minio.yaml` — Helm chart `minio` from
  `https://charts.min.io`, `targetRevision: "5.4.0"`, no separate values file (values inlined in
  `spec.source.helm.values`). Destination namespace `infrastructure`,
  `syncOptions: [CreateNamespace=false]` (namespace already exists — created by the
  `infrastructure` Application instead).
- Key inline values: `mode: standalone`, `existingSecret: minio-secret`, `persistence.size: 10Gi`,
  auto-created `buckets` (`cnpg-backups`, `velero-backups`, both `policy: none`), resource
  requests/limits (256Mi/1Gi memory), Prometheus `metrics.serviceMonitor` enabled with label
  `release: monitoring`.
- Ingress: two separate Traefik ingresses defined in the chart values — the S3 API at
  `minio.homelab.local` and the web console at `minio-console.homelab.local`, both TLS-terminated
  via the `homelab-wildcard-tls` secret. `MINIO_BROWSER_REDIRECT_URL` is set to
  `https://minio-console.homelab.local` for console login redirects, but `MINIO_SERVER_URL` is
  deliberately left unset — per an inline comment, setting it breaks console login because the
  pod itself can't resolve `*.homelab.local` (that only resolves via Tailscale split DNS, which
  the pod's CoreDNS doesn't have).
- ExternalSecret: `k8s/security/external-secrets/infrastructure/minio-secret.yaml` — `ClusterSecretStore: vault`,
  Vault path `homelab/infrastructure/minio`, keys `rootUser`, `rootPassword`, and
  `storage-box-password` (the last is used by the Restic backup CronJob, not by MinIO itself),
  target secret `minio-secret` in namespace `infrastructure`.
- Namespace: `infrastructure`.

## How to change it

- To bump the chart version, edit `targetRevision` in `k8s/argocd/applications/minio.yaml`.
- To add/remove buckets, edit the `buckets:` list in that Application's inline `helm.values`.
- To rotate credentials, run `scripts/setup-minio.sh` (requires `VAULT_TOKEN` env var) — it's
  idempotent and only writes to Vault if `rootUser`/`rootPassword`/`storage-box-password` aren't
  all already set at `homelab/infrastructure/minio`; to force-rotate a single key, use the
  `vault kv put` command shown in that script's header comment. The script also annotates the
  `minio-secret` ExternalSecret to force an immediate sync after writing.
- Note the `storage-box-password` value is shared with the offsite Restic backup job
  (`k8s/infrastructure/minio-backup-restic.yaml`), which also uses `rootPassword` as the Restic
  repository encryption password — rotating `rootPassword` changes what encrypts the offsite
  backup repo too, so coordinate with `docs/backup-strategy.md` before rotating it.
