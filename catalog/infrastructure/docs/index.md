## What it is

The `infrastructure` ArgoCD Application is a grab-bag of shared cluster plumbing that doesn't
warrant its own Helm chart or ArgoCD Application: the CloudNativePG-managed shared PostgreSQL
cluster, the cert-manager `ClusterIssuer`/wildcard `Certificate` for the internal CA, a daily
CronJob that syncs TLS/CA certs to other namespaces, and a CronJob that pushes MinIO's data
offsite via Restic. Unlike the other services in this system, it's not a Helm chart — ArgoCD
syncs the directory `k8s/infrastructure/` directly as a set of raw Kubernetes manifests.

## Why it's here

Several services in this cluster need a relational database (Keycloak, GitLab, Nextcloud,
Paperless-ngx, NocoDB, Backstage), and running one shared PostgreSQL cluster (`homelab-pg`) is
simpler to operate and back up than one instance per app. Likewise, every internal
`*.homelab.local` hostname needs a TLS cert from the same internal CA, and pods across
namespaces need that CA's public cert to trust each other (e.g. Nextcloud's PHP container
talking to Vault or Keycloak) — the cert-sync CronJob keeps the wildcard cert and CA copies
current wherever they're needed. The Restic CronJob is the offsite half of the backup strategy:
CNPG's own Barman backups and MinIO's local PVC both live in-cluster, so this job additionally
pushes MinIO's data (which includes the CNPG Barman backups themselves) to a Hetzner Storage Box
over SFTP, so a full cluster loss doesn't mean data loss.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/infrastructure.yaml` — `source.path: k8s/infrastructure`,
  `targetRevision: main` (syncs the directory as raw manifests, not a Helm chart), namespace
  `infrastructure`.
- Manifests actually applied, all under `k8s/infrastructure/`:
  - `postgres-cluster.yaml` — CloudNativePG `Cluster` `homelab-pg` (1 instance, 10Gi storage,
    initial database/owner `homelab`), plus a `ScheduledBackup` (`homelab-pg-daily`, cron
    `0 3 * * *`, 30-day retention) that backs up to MinIO via Barman
    (`s3://cnpg-backups/`, endpoint `http://minio.infrastructure.svc.cluster.local:9000`, using
    the `minio-secret` `rootUser`/`rootPassword` keys).
  - `cert-manager-issuer.yaml` — `ClusterIssuer` `homelab-ca-issuer`, backed by the
    `homelab-ca-keypair` secret created by `scripts/bootstrap-certmanager.sh` (never committed).
  - `homelab-wildcard-cert.yaml` — `Certificate` `homelab-wildcard` for `*.homelab.local` /
    `homelab.local`, issued via `homelab-ca-issuer`, stored in secret `homelab-wildcard-tls`.
  - `cert-sync-cronjob.yaml` — daily (`0 3 * * *`) CronJob in `kube-system` that syncs
    `homelab-wildcard-tls` from `infrastructure` to `kube-system` (for Traefik) and syncs the
    `homelab-ca` cert to every namespace labeled `homelab.local/inject-ca=true`.
  - `minio-backup-restic.yaml` — daily (`30 3 * * *`) CronJob `minio-backup-restic` that backs up
    MinIO's PVC to a Hetzner Storage Box via `restic` over SFTP, keeping 30 daily / 4 weekly / 3
    monthly snapshots.
  - `nextcloud-ca-hook.yaml`, `nextcloud-php-ca.yaml`, `nextcloud-middleware.yaml` — CA-trust and
    Traefik `Middleware` support manifests specifically for Nextcloud (WebDAV rewrites, security
    headers).
- No Helm values file — there's no chart, so no `k8s/values/infrastructure.yaml`.
- Relevant ExternalSecrets (all Vault path `homelab/infrastructure/...`, `ClusterSecretStore: vault`):
  - `k8s/security/external-secrets/infrastructure/minio-secret.yaml` → `homelab/infrastructure/minio`
    (used by the CNPG Barman backup and the Restic CronJob).
  - `k8s/security/external-secrets/infrastructure/restic-ssh-key.yaml` → `homelab/infrastructure/restic-ssh`
    (SSH key + Storage Box connection details for the Restic CronJob).
  - `k8s/security/external-secrets/infrastructure/redis-secret.yaml` → `homelab/infrastructure/redis-secret`
    (not consumed here directly, but lives in this namespace — see the `redis` service doc).
- Namespace: `infrastructure`. No ingress of its own (Postgres and the CronJobs are internal-only).

## How to change it

- To change Postgres resources, storage size, retention, or backup schedule, edit
  `k8s/infrastructure/postgres-cluster.yaml` directly — CNPG reconciles the `Cluster`/`ScheduledBackup`
  objects on ArgoCD sync (`selfHeal: true`, `prune: true`, so removed objects get deleted).
- To add a database/role for a new service, see `scripts/setup-databases.sh` (Postgres DBs/roles
  + Vault secrets bootstrap for Keycloak, GitLab, Nextcloud, Paperless).
- To change the wildcard cert's SANs or validity period, edit `k8s/infrastructure/homelab-wildcard-cert.yaml`
  (`dnsNames`, `duration`, `renewBefore`).
- To make a new namespace trust the internal CA, label it: `kubectl label namespace <ns> homelab.local/inject-ca=true`
  — the `cert-sync-cronjob.yaml` CronJob picks it up on its next run (daily at 03:00), or trigger
  it manually with `kubectl create job --from=cronjob/cert-sync -n kube-system <job-name>`.
- To restore MinIO/CNPG-backup data from the offsite Restic repository, use the Storage Box
  connection details from Vault (`homelab/infrastructure/restic-ssh`); see `docs/backup-strategy.md`
  for the full runbook. There's also `scripts/test-cnpg-recovery.sh` for testing CNPG recovery
  specifically.
- The whole directory (`k8s/infrastructure/`) is a bag of otherwise-unrelated manifests — when
  adding something new here, consider whether it deserves its own ArgoCD Application instead
  before dropping it in.
