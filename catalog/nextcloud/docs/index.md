## What it is

Nextcloud is a self-hosted file sync and sharing platform — the cluster's
alternative to Google Drive/Dropbox. It's deployed with the `fpm-alpine`
image behind an nginx sidecar, backed by PostgreSQL for its database and
Redis for caching/locking, and it ships with several bundled apps (Mail,
Calendar, Contacts, Notes, Deck, and OIDC login) enabled automatically on
first boot.

## Why it's here

It's the primary personal cloud storage for the homelab: file sync across
devices, shared folders, and (via the Hetzner Storage Box mounted as
external WebDAV storage) an offsite-backed expansion of storage beyond the
cluster's local PVCs. Login goes through Keycloak (the cluster's SSO)
rather than a separate Nextcloud-only account, so it fits into the same
auth model as the rest of the productivity apps.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/nextcloud.yaml`, chart
  `nextcloud` from `https://nextcloud.github.io/helm`, pinned to
  `targetRevision: "8.9.1"` (the values comment notes 6.x had a bug with
  duplicate `extraVolumeMounts` that 8.x fixes). Deployed into the
  `productivity` namespace with `automated: {prune: true, selfHeal: true}`
  and `CreateNamespace=true`.
- **Values**: inlined in the Application under `spec.source.helm.values`
  (no separate `k8s/values/nextcloud.yaml` file). Key settings:
  - `internalDatabase.enabled: false` / `externalDatabase` points at
    PostgreSQL (CloudNativePG) at
    `homelab-pg-rw.infrastructure.svc.cluster.local:5432`, database
    `nextcloud`.
  - `redis.enabled: false` — instead the app is pointed at the shared
    `redis-master.infrastructure.svc.cluster.local:6379` via a custom
    `redis.config.php` snippet.
  - `oidc.config.php` wires up the `oidc_login` app against
    `https://auth.homelab.local/realms/homelab` with client id
    `nextcloud`.
  - A `postStart` lifecycle hook runs `occ maintenance:install` on first
    boot and activates `oidc_login`, `files_external`, `mail`, `calendar`,
    `contacts`, `notes`, `deck`.
  - A homelab CA bundle is mounted (`homelab-ca` Secret, `nextcloud-php-ca`
    and `nextcloud-combined-ca` ConfigMaps) so PHP/OIDC requests trust the
    internal CA.
- **ExternalSecret**:
  `k8s/security/external-secrets/productivity/nextcloud-secret.yaml`,
  namespace `productivity`, pulling from Vault path
  `homelab/productivity/nextcloud-secret` via the `vault`
  `ClusterSecretStore`. Keys: `nextcloud-username`, `nextcloud-password`,
  `db-username`, `db-password`, `redis-password`, `storage-box-password`,
  `oidc-client-secret`.
- **Ingress**: `traefik` ingress class, host `nextcloud.homelab.local`,
  TLS via the `homelab-wildcard-tls` secret, with the
  `productivity-nextcloud-headers@kubernetescrd` middleware applied.

## How to change it

- **Chart version / values**: edit the inlined `helm.values` block in
  `k8s/argocd/applications/nextcloud.yaml` directly (there is no separate
  values file for this service) and let ArgoCD sync.
- **Credentials / secrets**: this service's Vault secret is seeded (once,
  on first bootstrap) by `scripts/setup-databases.sh`, which creates the
  `nextcloud` PostgreSQL database/role and writes the initial
  `homelab/productivity/nextcloud-secret` values (admin username/password,
  DB credentials, Redis password, Storage Box password, and a placeholder
  `oidc-client-secret`). The script explicitly does **not** re-run this
  step if the Vault path already exists — it's a one-time initial write,
  not a merge/update pattern. To change a value afterwards, patch Vault
  directly (e.g. `vault kv patch secret/homelab/productivity/nextcloud-secret
  oidc-client-secret=<real-secret>` once the Keycloak client exists) and
  then force a re-sync with
  `kubectl annotate externalsecret nextcloud-secret -n productivity
  force-sync="$(date +%s)" --overwrite`.
- **Hetzner Storage Box external storage**: managed separately via
  `scripts/setup-nextcloud-storage.sh`, which mounts the Storage Box as a
  WebDAV `files_external` mount inside the running pod using the
  `storage-box-password` key from `nextcloud-secret`. Supports `--dry-run`
  and `--reset` flags.
- **App activation**: additional Nextcloud apps can be added to the
  `activate_app` calls in the `postStart` lifecycle hook in the Application
  manifest.
