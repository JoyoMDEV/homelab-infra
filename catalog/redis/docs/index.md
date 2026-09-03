## What it is

Redis (Bitnami chart, standalone mode — no replicas) deployed as a shared, single-instance cache
in the `infrastructure` namespace. It's a plain key/value cache, not used as a durable data store.

## Why it's here

It's the shared session/cache backend for several apps in the cluster: Nextcloud
(`redis-password` in its ExternalSecret), Paperless-ngx (`redis-password` + `redis-url`), and
GitLab (`redis-password`). Rather than each app running its own Redis pod, they all point at this
one instance, which keeps resource usage down for a homelab-scale cluster. Each consuming service
gets its own copy of the Redis password baked into its own Vault-backed secret (e.g.
`homelab/productivity/nextcloud-secret`'s `redis-password` key) rather than mounting
`redis-secret` directly — so the same password value is duplicated across several Vault paths.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/redis.yaml` — Helm chart `redis` from
  `https://charts.bitnami.com/bitnami`, `targetRevision: "25.3.2"`, no separate values file (the
  values are inlined in the Application's `spec.source.helm.values`).
- Key inline values: `architecture: standalone`, `auth.existingSecret: redis-secret` (key
  `redis-password`), `master.persistence` enabled at `2Gi`, `replica.replicaCount: 0` (no
  read replicas), modest resource requests/limits (128Mi/256Mi memory, 100m CPU request).
- ExternalSecret: `k8s/security/external-secrets/infrastructure/redis-secret.yaml` — `ClusterSecretStore: vault`,
  Vault path `homelab/infrastructure/redis-secret`, property `redis-password`, target secret
  `redis-secret` in namespace `infrastructure`.
- Namespace: `infrastructure`. No ingress — Redis is only reachable in-cluster
  (`redis-master.infrastructure.svc.cluster.local`), consumed by other services' pods directly.
- Bootstrap note: per `README.md` and `scripts/bootstrap-argocd.sh`, the initial `redis-secret`
  is one of the few secrets created directly by a bootstrap script (`openssl rand -base64 24`)
  before Vault/ESO exist — it's a chicken-and-egg exception, since Redis has to come up before
  Vault can be initialized and used to manage its own secret. `scripts/migrate-secrets-to-vault.sh`
  later migrates that bootstrap-created password into Vault at `homelab/infrastructure/redis-secret`
  so the ExternalSecret can take over managing it going forward.

## How to change it

- To bump the chart version, edit `targetRevision` in `k8s/argocd/applications/redis.yaml`.
- To change persistence size or resource limits, edit the inline `helm.values` block in that same
  file (there's no separate `k8s/values/redis.yaml`).
- To rotate the Redis password: write a new value to Vault at `homelab/infrastructure/redis-secret`
  (there's no dedicated `scripts/setup-redis.sh` — this secret predates the per-service setup
  script convention), then force a resync of the ExternalSecret, e.g.
  `kubectl annotate externalsecret redis-secret -n infrastructure force-sync="$(date +%s)" --overwrite`.
  Remember every downstream consumer (Nextcloud, Paperless, GitLab) has its own copy of the
  password in its own Vault path/secret and needs updating too, or those apps will fail to
  authenticate to Redis after rotation.
- To add horizontal read capacity, set `replica.replicaCount` above `0` in the Application's
  inline values (currently `0` since a single homelab-scale cache doesn't need replicas).
