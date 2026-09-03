## What it is

Velero (upstream Helm chart), deployed as a cluster backup/restore controller that snapshots Kubernetes resources (and, where configured, PVC data via its Kopia integration) to an S3-compatible object store — here, the in-cluster MinIO instance.

## Why it's here

If a namespace, deployment, or the whole cluster gets destroyed, Terraform/Ansible/ArgoCD can rebuild the infrastructure and redeploy the apps from git, but they can't recreate in-cluster *state*: Secrets synced from Vault, PVC contents, CRD objects, etc. at the moment of failure. Velero is the safety net for that Kubernetes-resource state, backing up daily to MinIO. Note this is a k3s cluster using the `local-path` storage class, which Velero's Kopia uploader doesn't support — so PVC file-level backup (`defaultVolumesToFsBackup`) is deliberately disabled here (see comments in `k8s/argocd/applications/velero.yaml`); Velero currently protects the Kubernetes API objects (Deployments, Secrets, ConfigMaps, etc.), not raw volume contents. The one exception is Postgres: the shared CNPG cluster (`k8s/infrastructure/postgres-cluster.yaml`) has its own independent Barman-based backup straight to MinIO (bucket `cnpg-backups`, daily at 03:00, 30-day retention) — that's what actually protects Postgres data, separate from and complementary to Velero's cluster-state backups (bucket `velero-backups`, daily at 02:00).

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/velero.yaml`, `spec.destination.namespace: backup`.
- Chart: upstream `velero` from `https://vmware-tanzu.github.io/helm-charts`, `targetRevision: "12.0.0"`.
- Key values (inline in the Application's `helm.values`):
  - `credentials.existingSecret: velero-secret`.
  - `configuration.backupStorageLocation`: provider `aws` (S3-compatible), bucket `velero-backups`, pointed at `http://minio.infrastructure.svc.cluster.local:9000` with `s3ForcePathStyle: true` (MinIO path-style addressing).
  - `configuration.uploaderType: kopia`, `snapshotsEnabled: false` (no CSI snapshot support on k3s), `deployNodeAgent: false` and `defaultVolumesToFsBackup: false` (both disabled because k3s's `local-path` storage class isn't supported by Kopia — see the comment block in the Application manifest for the plan to revisit this if the cluster moves to a different storage class like OpenEBS ZFS).
  - `schedules.daily-cluster-backup`: cron `0 2 * * *`, `ttl: 336h` (14 days retention), `excludedNamespaces: [kube-system]`, `includedResources: ["*"]`.
  - `initContainers`: `velero/velero-plugin-for-aws:v1.12.2`, required for the S3-compatible (MinIO) backend.
  - `metrics.enabled: true` with a `ServiceMonitor` labeled `release: monitoring` for Prometheus scraping.
- ExternalSecret: `k8s/security/external-secrets/backup/velero-secret.yaml`, namespace `backup` → Vault `homelab/backup/velero-secret`, single key `cloud` (an AWS-credentials-file-formatted blob, mounted at `/credentials/cloud` in the Velero pod).

## How to change it

- Version bump: change `targetRevision` in `k8s/argocd/applications/velero.yaml`.
- Backup schedule/retention/excluded namespaces: edit `configuration.schedules.daily-cluster-backup` in the same file.
- Re-enabling PVC (volume) backups: requires moving off the `local-path` storage class first (e.g. to OpenEBS ZFS), then flip `deployNodeAgent: true` and `defaultVolumesToFsBackup: true`.
- MinIO credentials: run `scripts/setup-velero.sh`. It checks MinIO is running, reads the MinIO root credentials from Vault (`homelab/infrastructure/minio`, keys `rootUser`/`rootPassword`), builds an AWS-format credentials file (`[default]` block), writes it to Vault at `homelab/backup/velero-secret` under the key `cloud`, force-syncs the ExternalSecret, waits for the Velero deployment, verifies the `BackupStorageLocation` is `Available`, and offers to trigger an initial test backup via the `velero` CLI if installed.
- Testing recovery: `scripts/test-velero-recovery.sh`.
- **If `homelab/backup/velero-secret` is ever found empty/missing in Vault**: this has already happened once — a prior cleanup script deleted it (and `homelab/automation/renovate-secret`) from Vault while the live Kubernetes Secret and the running Velero deployment kept working fine on the stale-but-valid credentials. Before re-running `setup-velero.sh` against fresh MinIO credentials, check whether the Kubernetes Secret still holds a valid value:
  ```
  kubectl get secret velero-secret -n backup -o jsonpath='{.data.cloud}' | base64 -d
  ```
  and if it does, write it straight back into Vault instead of regenerating:
  ```
  kubectl get secret velero-secret -n backup -o jsonpath='{.data.cloud}' | base64 -d | \
    vault kv patch secret/homelab/backup/velero-secret cloud=-
  ```
  (run against the `vault-0` pod with `VAULT_ADDR`/`VAULT_TOKEN` set, same as the setup scripts do). Only fall back to regenerating/rotating MinIO credentials if the Kubernetes Secret is also gone or invalid.
