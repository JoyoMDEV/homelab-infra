## What it is

A self-hosted [PowerSync](https://www.powersync.com) (Open Edition) service — streams changes from `supabase-pg` to `everything-app`'s Expo client via Postgres logical replication, giving the app offline-first local SQLite with per-user sync rules.

## Why it's here

`everything-app`'s ADR-0001 made offline-first a v0 requirement, not deferred - Supabase alone has no client-side conflict handling or offline read/write story. PowerSync is purpose-built for exactly this combination (Postgres + Supabase + React Native/Expo), source-available and self-hostable, so it runs alongside Supabase rather than as a SaaS dependency.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/powersync.yaml` — local chart `k8s/charts/powersync`, namespace `powersync`.
- Source database: `supabase-pg` (namespace `supabase`), via a dedicated `powersync_role` (`REPLICATION BYPASSRLS`, created by `everything-app`'s `supabase/migrations/0006_powersync_replication.sql`) and a Postgres `PUBLICATION` named exactly `powersync` (fixed name PowerSync looks up, not auto-created).
- Storage backend (PowerSync's own sync-bucket metadata, separate from the source database): a dedicated CNPG cluster `powersync-pg` (`k8s/infrastructure/powersync-postgres-cluster.yaml`), Postgres storage (not MongoDB) — avoids introducing a new datastore type for one service.
- Sync rules: `k8s/charts/powersync/values.yaml`'s `syncRules` field, mirrored from `everything-app`'s `supabase/powersync/sync-rules.yaml` (source of truth lives in the app repo — copy it here whenever it changes, the service needs a restart to pick up edits either way).
- Auth: reuses Supabase's existing HS256 JWT secret (`client_auth.supabase: true` + `supabase_jwt_secret`) rather than a separate JWKS/asymmetric-key setup.
- Secrets: `k8s/security/external-secrets/powersync/powersync-secret.yaml` (Vault path `homelab/powersync/powersync-secret` — `powersync_role`'s password, the `powersync-pg` storage connection string — plus a second entry reusing `homelab/supabase/supabase-secret`'s `jwt-secret`, seeded/rotated via `scripts/setup-powersync.sh`).
- Ingress: `powersync.homelab.local`, Traefik + `homelab-wildcard-tls`, Tailscale-only like every other internal service here.

## How to change it

- **Add a new module's synced table**: in `everything-app`, add a `Table` schema + a stream in `supabase/powersync/sync-rules.yaml`, then copy that file's content into this chart's `values.yaml`'s `syncRules` and restart the `powersync` Deployment (`kubectl rollout restart deployment/powersync -n powersync`) to pick it up.
- **Rotate the replication role's password or the storage connection**: run `scripts/setup-powersync.sh` again (idempotent), then force-sync: `kubectl -n powersync annotate externalsecret powersync-secret force-sync=$(date +%s) --overwrite`.
- **Resize the storage Postgres**: edit `k8s/infrastructure/powersync-postgres-cluster.yaml`'s `storage.size` and let ArgoCD/CNPG reconcile.
