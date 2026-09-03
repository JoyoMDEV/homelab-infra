## What it is

NocoDB is an open-source no-code database tool — an Airtable-like
spreadsheet UI on top of a real SQL database. It's deployed as a single
container backed by PostgreSQL, with no bundled/embedded database of its
own.

## Why it's here

It gives a quick spreadsheet-style front end for structured data (lists,
trackers, small internal tools) without needing a bespoke app for every
use case, while still storing everything in the cluster's shared
PostgreSQL instance rather than a throwaway SQLite file. It's part of the
`productivity` namespace alongside Nextcloud and Paperless.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/nocodb.yaml`, chart
  `nocodb` from `https://zekker6.github.io/helm-charts/`, pinned to
  `targetRevision: "1.10.0"`, image `nocodb/nocodb:0.301.5`. Deployed into
  the `productivity` namespace with `automated: {prune: true, selfHeal:
  true}` and `CreateNamespace=true`.
- **Values**: inlined in the Application under `spec.source.helm.values`
  (no separate `k8s/values/nocodb.yaml` file). Key settings:
  - `persistence.data.enabled: false` — no SQLite PVC; PostgreSQL is used
    instead.
  - `env.NC_DB` is sourced entirely from the `db-url` key in
    `nocodb-secret` (a full `pg://` connection string including the
    password), specifically to avoid a mismatch between a separately
    templated URL and the stored password.
  - `env.NC_AUTH_JWT_SECRET` comes from the `jwt-secret` key in the same
    secret.
  - `NC_PUBLIC_URL: "https://nocodb.homelab.local"`, telemetry disabled
    (`NC_DISABLE_TELE`), `NODE_OPTIONS: "--max-old-space-size=768"` to
    avoid an OOM at startup.
- **ExternalSecret**:
  `k8s/security/external-secrets/productivity/nocodb-secret.yaml`,
  namespace `productivity`, pulling from Vault path
  `homelab/productivity/nocodb-secret` via the `vault`
  `ClusterSecretStore`. Keys: `db-password`, `db-url`, `jwt-secret`.
- **Ingress**: `traefik` ingress class, host `nocodb.homelab.local`, TLS
  via the `homelab-wildcard-tls` secret.

## How to change it

- **Chart version / values**: edit the inlined `helm.values` block in
  `k8s/argocd/applications/nocodb.yaml` directly (there is no separate
  values file) and let ArgoCD sync.
- **Credentials / database**: managed by `scripts/setup-nocodb.sh`, which
  is idempotent — it creates the `nocodb` PostgreSQL database/role (or
  resyncs the role's password if it already exists), reuses the existing
  `db-password` from Vault if present, builds the full `db-url` connection
  string from it, and writes both plus a `jwt-secret` to
  `homelab/productivity/nocodb-secret`. It then force-syncs the
  `nocodb-secret` ExternalSecret. Because `NC_DB` is the full connection
  string, always regenerate it via this script rather than hand-editing
  `db-password` alone in Vault, to keep the password and URL in sync (this
  is called out explicitly in both the script and the Application's
  values comments).
- After changing credentials, the script suggests restarting the
  deployment (`kubectl rollout restart deployment/nocodb -n productivity`)
  if the pod was already running, since NocoDB reads `NC_DB` at startup.
