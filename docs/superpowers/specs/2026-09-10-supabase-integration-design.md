# Supabase integration

## Problem

Johannes wants a self-hosted Supabase stack (Postgres + Auth + REST +
Realtime + Storage + Studio + Edge Functions) running in the homelab
cluster, to use as a backend-as-a-service for apps he builds (primarily via
the Coder workspace), with room to add Edge Functions.

## Goals

- Full self-hosted Supabase: Postgres, Auth (GoTrue), REST (PostgREST),
  Realtime, Storage, Studio, and Edge Functions, reachable at
  `supabase.homelab.local` (API) and `supabase-studio.homelab.local`
  (Studio UI).
- A genuinely open-source S3-compatible storage backend for Supabase
  Storage — not MinIO, whose OSS console was gutted in 2025. Deployed as a
  **shared** infra service (like MinIO today), not a Supabase-only
  instance, so future services can use it too.
- Edge Functions deployable through the existing GitLab CI pattern (custom
  image build), not the chart's default empty-PVC approach.
- Fits every existing repo convention: one ArgoCD `Application`, secrets
  via Vault/`ExternalSecret`, a new `external-secrets` category, Backstage
  catalog entry, Traefik ingress on the wildcard TLS cert, reachable only
  over Tailscale.

## Non-goals

- Keycloak/OIDC login for Supabase Auth. Deferred — built-in email/password
  auth only for now; GoTrue supports adding an OIDC provider later without
  re-architecting anything here.
- High availability for either the new Postgres cluster or Garage. Single
  instance/single node, matching `homelab-pg`'s existing shape — this is a
  homelab, not a multi-AZ deployment.
- Supabase's analytics/log stack (Logflare-based Studio "Logs" tab). It
  needs its own BigQuery-or-Postgres backend and adds meaningful operational
  weight for a feature that isn't part of the ask. Studio works fully
  without it; only the Logs tab is unavailable.
- Migrating MinIO's existing buckets (`cnpg-backups`, `velero-backups`) to
  Garage. MinIO stays exactly as-is for backup plumbing — the licensing
  objection is about *product* file storage (what Supabase Storage serves
  to users), not internal backup infrastructure.

## Design

### Deployment shape: one ArgoCD Application

`k8s/argocd/applications/supabase.yaml`, using the community
`supabase-community/supabase-kubernetes` umbrella chart
(`repoURL: https://supabase-community.github.io/supabase-kubernetes`,
`chart: supabase`, `targetRevision: 0.8.0` — current release as of this
writing), destination namespace `supabase` (new — add to
`k8s/namespaces.yaml` with `managed-by: argocd` and
`homelab.local/inject-ca: "true"`, same labels every other internal-tier
namespace carries).

Rejected: one ArgoCD Application per Supabase subcomponent (kong, auth,
rest, realtime, storage, meta, studio, functions). That's 8 Applications
and 8 catalog entries for what's experienced as one product, breaking the
"one Application per service" convention for no homelab benefit — the
umbrella chart already exposes everything needed via values.

Rejected: vendoring/forking the chart into `k8s/charts/supabase/` (like
`gitlab-omnibus`/`backstage`). Unnecessary — the upstream chart already
supports external Postgres, external S3, and a custom Functions image
through values, so there's nothing a fork would buy us.

### Postgres: dedicated CNPG cluster

Supabase needs `CREATE EXTENSION` rights, its own `auth`/`storage`/
`realtime` schemas, and a `realtime` publication — rights and structure
that don't belong in the shared `homelab-pg` cluster alongside Keycloak,
NocoDB, etc. New `k8s/infrastructure/supabase-postgres-cluster.yaml`: a
second CNPG `Cluster`, `supabase-pg`, namespace `supabase`, mirroring
`homelab-pg`'s shape (1 instance, 512Mi/1Gi resources, 10Gi storage,
Barman backup to the existing MinIO `cnpg-backups` bucket, daily
`ScheduledBackup`).

The chart is pointed at it externally: `deployment.db.enabled: false`,
`secret.db.{host,port,password,database}` set to
`supabase-pg-rw.supabase.svc.cluster.local`/`5432`/(Vault-sourced)/
`postgres`.

**Bootstrap caveat, called out explicitly**: an external Postgres must
already have Supabase's own schemas/roles/extensions/publication set up —
the bundled `db` image normally does this via init SQL on first boot, and
skipping it (because we disabled the bundled db) means someone must run
that init SQL once against `supabase-pg` before the app comes up. Exact
source (the migration set the `supabase/postgres` image ships) is an
implementation-time detail for `scripts/setup-supabase.sh`, not fixed here
— confirm against the chart's actual release notes/docs when implementing
against `0.8.0` specifically.

### Storage backend: Garage, shared, alongside MinIO

New ArgoCD Application `k8s/argocd/applications/garage.yaml`: Garage
(AGPLv3, Deuxfleurs), sourced directly from its own repo
(`repoURL: https://git.deuxfleurs.fr/Deuxfleurs/garage.git`,
`path: script/helm/garage`, `targetRevision: v2.4.1` — current stable),
destination namespace `infrastructure` (next to MinIO — this is
shared infra, not Supabase-only). Single-node mode (`replication_factor:
1`, officially supported since v2.3) — matches this cluster's scale and
keeps ops simple.

Unlike MinIO's single root credential reused across buckets, Garage's
security model is a scoped access-key-per-bucket, so Supabase Storage gets
its own key restricted to a `supabase-storage` bucket rather than an
admin/root key — a small hardening over the existing MinIO pattern, not a
new burden, since Garage encourages it by default. Future services get
their own bucket + scoped key the same way, which is the whole point of
"shared."

Supabase's `storage` component points at it via `secret.s3.{keyId,
accessKey}` plus the storage component's own S3 endpoint/region/bucket
values (`GLOBAL_S3_BUCKET: supabase-storage`, endpoint pointed at Garage's
in-cluster S3 API service). Garage stays ClusterIP-only, no ingress —
nothing outside the cluster talks to it directly.

Bucket + scoped access key creation happens via `kubectl exec` into the
Garage pod running its CLI (same remote-exec pattern already used for
`vault kv` commands against `vault-0`), scripted in
`scripts/setup-supabase-storage.sh`.

### Auth, Kong, and ingress: two hosts

Supabase Auth uses only its own built-in email/password login (per
Non-goals). Kong is the chart's only externally-routable component by
design (bundles Auth/REST/Realtime/Storage/Functions behind anon/
service-role API-key checks); its Service stays ClusterIP and gets a
Traefik `Ingress`, `supabase.homelab.local`, TLS via
`homelab-wildcard-tls` — same shape as every other internal service.

The chart's own Ingress templates only cover `kong` (and, unused here,
`db`) — Studio isn't separately exposed by the chart; upstream's default
self-host model reaches Studio *through* Kong at `/`, behind Kong's basic
auth. That contradicts the "two separate hosts" choice, so Studio gets a
second, hand-written `Ingress` in this repo (not chart-templated) pointed
directly at the chart's Studio `Service` (exact generated Service name to
confirm via `kubectl get svc -n supabase` once the chart is rendered —
release-name-prefixed, not fixed here), host
`supabase-studio.homelab.local`, same TLS secret.

Reaching Studio directly bypasses the basic-auth gate Kong would have put
in front of it. To not lose that protection, add a Traefik `BasicAuth`
Middleware on this Ingress specifically (`k8s/infrastructure/` — same
place `nextcloud-middleware.yaml` lives), credentials generated and stored
alongside the rest of Supabase's secrets by `scripts/setup-supabase.sh`.
Kong's own API routes (`/auth/v1`, `/rest/v1`, etc.) keep their normal
anon/service-role key check — no Middleware needed there.

### Edge Functions: custom image via GitLab CI

New GitLab project `homelab/projects/supabase-functions` (same pattern as
`coder-workspace`): a `Dockerfile` `FROM supabase/edge-runtime:v1.74.0`
that `COPY`s the function directories in, and a `.gitlab-ci.yml` using the
existing Kaniko build-and-push pattern, pushed to
`registry.homelab.local/homelab/projects/supabase-functions`. The chart's
`functions` component gets `image.repository`/`image.tag` pointed at that
image instead of the upstream default, and the chart's default
`persistence.deno`/`persistence.functions` PVCs (meant for hand-copying
code onto an empty volume) are disabled since the code now ships baked
into the image.

### Secrets

New `external-secrets` category `k8s/security/external-secrets/supabase/`
(same one-category-per-service-family pattern as the recent `coder`
category):

- `supabase-secret.yaml` — JWT signing secret, the anon/service-role JWTs
  derived from it, and the Postgres password for `supabase-pg`. Vault path
  `homelab/supabase/supabase-secret`.
- `supabase-storage-secret.yaml` — the Garage access key/secret scoped to
  the `supabase-storage` bucket. Vault path
  `homelab/supabase/supabase-storage-secret`.
- `supabase-studio-secret.yaml` — the Traefik BasicAuth credentials for
  the Studio Ingress. Vault path `homelab/supabase/supabase-studio-secret`.

`scripts/setup-supabase.sh` handles Postgres bootstrap (role/database +
the one-time Supabase init SQL) and JWT/key generation;
`scripts/setup-supabase-storage.sh` handles the Garage bucket/key. Both
write to Vault the way every other `setup-<service>.sh` script does — the
actual `vault kv put` runs are executed by Johannes, not automated here
(matching this repo's standing preference for hands-on Vault writes).

### Backstage catalog

`catalog/supabase/catalog-info.yaml` (annotations: `argocd/app-name:
supabase`, `backstage.io/kubernetes-id` matching the `supabase` namespace)
plus `catalog/supabase/docs/index.md` with the four standard sections,
registered in `catalog/all.yaml`. Garage, as new shared infra, likely
deserves its own lightweight catalog entry too
(`catalog/garage/catalog-info.yaml`) rather than being folded into an
existing one — confirm at implementation time whether it should instead
be added as a resource under the existing infrastructure entry, if one
already models MinIO that way.

## Testing

- `supabase-pg` and `garage` Applications sync healthy in ArgoCD.
- Postgres init SQL applied; `supabase` Application then syncs healthy
  with `db.enabled: false`.
- `https://supabase.homelab.local/rest/v1/` and `/auth/v1/health` return
  the expected Kong-fronted responses with a valid anon key, and reject
  requests without one.
- `https://supabase-studio.homelab.local` prompts for the Traefik
  BasicAuth credentials, then loads Studio, which can browse the
  `supabase-pg` schema.
- Upload a file through Storage's REST API; confirm it lands in the
  `supabase-storage` Garage bucket (via the Garage CLI) and is
  retrievable back through the Storage API.
- A Realtime channel subscription in a small test client receives a
  change event after an `INSERT` into a table with Realtime enabled.
- Push a trivial function to the `supabase-functions` GitLab project, let
  CI build+push, bump the Functions image tag, confirm
  `POST /functions/v1/<name>` invokes it.

## Rollout order

1. `k8s/namespaces.yaml` — add the `supabase` namespace.
2. `k8s/infrastructure/supabase-postgres-cluster.yaml` — new CNPG cluster;
   `scripts/setup-supabase.sh` creates the role/database and runs the
   Supabase init SQL once, then generates the JWT secret + anon/
   service-role keys.
3. `k8s/argocd/applications/garage.yaml` — deploy Garage;
   `scripts/setup-supabase-storage.sh` creates the `supabase-storage`
   bucket + scoped access key.
4. `k8s/security/external-secrets/supabase/*.yaml` — the three
   ExternalSecrets, Vault paths seeded from steps 2–3.
5. `k8s/argocd/applications/supabase.yaml` — deploy the umbrella chart
   with `db.enabled: false` and the external S3 values; verify Kong/Auth/
   REST/Realtime/Storage come up healthy.
6. Hand-written Studio `Ingress` + Traefik `BasicAuth` Middleware; verify
   `supabase-studio.homelab.local`.
7. New GitLab project `homelab/projects/supabase-functions`; verify a
   sample function end-to-end.
8. `catalog/supabase/` (+ `catalog/garage/`) entries, registered in
   `catalog/all.yaml`.
9. Full Testing section above, end to end.
