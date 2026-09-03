## What it is

Paperless-ngx is a self-hosted document management system: it OCRs scanned
documents/PDFs, extracts text and metadata, and makes everything
searchable. This deployment runs the main `paperless-ngx` app plus two
sidecar containers — Apache Tika (for parsing/text-extraction of Office
documents) and Gotenberg (for PDF conversion) — in the same pod, backed by
PostgreSQL for its database and an external Redis for its task queue.

## Why it's here

It's the document archive for the homelab: scanned paperwork, PDFs, and
other documents get consumed, OCR'd, tagged, and made searchable in one
place instead of sitting in a folder. Like Nextcloud, it authenticates
through Keycloak (OIDC) rather than a standalone account, and it sends
email (e.g. for consumption-by-mail or notifications) through the same
SMTP relay used elsewhere in the cluster.

## How it's configured

- **ArgoCD Application**: `k8s/argocd/applications/paperless.yaml`, chart
  `paperless-ngx` from `https://charts.gabe565.com`, pinned to
  `targetRevision: 0.24.1`, image
  `ghcr.io/paperless-ngx/paperless-ngx:latest`. Deployed into the
  `productivity` namespace with `automated: {prune: true, selfHeal: true}`
  and `CreateNamespace=true`.
- **Values**: inlined in the Application under `spec.source.helm.values`
  (no separate `k8s/values/paperless.yaml` file). Key settings:
  - `redis.enabled: false` — the chart's bundled Redis subchart is
    disabled in favor of the shared cluster Redis; `PAPERLESS_REDIS` comes
    from the `redis-url` key in `paperless-secret`.
  - Database: `PAPERLESS_DBENGINE: postgresql` against
    `homelab-pg-rw.infrastructure.svc.cluster.local:5432`, database
    `paperless`, credentials from `paperless-secret`.
  - OIDC: `PAPERLESS_APPS` adds
    `allauth.socialaccount.providers.openid_connect`, configured against
    Keycloak client id `paperless` at
    `https://auth.homelab.local/realms/homelab/.well-known/openid-configuration`,
    with the client secret substituted from `OIDC_CLIENT_SECRET`
    (sourced from `paperless-secret`'s `oidc-client-secret` key).
  - SMTP: host `mail.your-server.de:587` with TLS, credentials from
    `paperless-secret`'s `smtp-username`/`smtp-password` keys.
  - OCR: `PAPERLESS_OCR_LANGUAGE: deu+eng`, Tika/Gotenberg sidecars wired
    via `PAPERLESS_TIKA_ENDPOINT`/`PAPERLESS_TIKA_GOTENBERG_ENDPOINT`
    pointing at `localhost` (same pod).
  - Persistence: four separate PVCs — `data` (20Gi), `media` (50Gi),
    `export` (5Gi), `consume` (5Gi) — plus the `homelab-ca` secret mounted
    for trusting the internal CA on outbound OIDC requests
    (`REQUESTS_CA_BUNDLE`).
- **ExternalSecret**:
  `k8s/security/external-secrets/productivity/paperless-secret.yaml`,
  namespace `productivity`, pulling from Vault path
  `homelab/productivity/paperless-secret` via the `vault`
  `ClusterSecretStore`. Keys: `db-username`, `db-password`,
  `redis-password`, `redis-url`, `secret-key`, `oidc-client-secret`,
  `smtp-username`, `smtp-password`.
- **Ingress**: `traefik` ingress class, host `paperless.homelab.local`,
  TLS via the `homelab-wildcard-tls` secret.

## How to change it

`paperless-secret` is seeded in **two phases**, per the comments in
`scripts/setup-databases.sh`:

1. **Phase 1 — `scripts/setup-databases.sh`**: on the very first run, this
   script creates the `paperless` PostgreSQL database/role and writes the
   *initial* Vault secret at `homelab/productivity/paperless-secret` with
   just `db-username`, `db-password`, `redis-password`, `secret-key`, and
   a placeholder `oidc-client-secret` (`REPLACE_AFTER_KEYCLOAK_SETUP`). If
   the Vault path already exists (partially or fully populated), this
   script skips writing to it entirely — it never overwrites.
2. **Phase 2 — `scripts/setup-paperless.sh`**: run afterwards (and safe to
   re-run), this script re-creates/verifies the PostgreSQL database and
   role (reusing the existing `db-password` from Vault), builds the
   URL-encoded `redis-url` from the shared Redis password, prompts
   interactively for the real Keycloak OIDC client secret (falls back to
   the `REPLACE_AFTER_KEYCLOAK_SETUP` placeholder if left blank), reads
   SMTP credentials from `homelab/security/vaultwarden-smtp`, and then
   **merges** (`vault kv patch`, not `put`) `oidc-client-secret`,
   `redis-password`, `redis-url`, `smtp-username`, `smtp-password` into
   the existing secret — preserving the `db-username`/`db-password`/
   `secret-key` fields Phase 1 wrote. It finishes by force-syncing the
   `paperless-secret` ExternalSecret.

To rotate a single value (e.g. the OIDC client secret after regenerating
it in Keycloak), either re-run `scripts/setup-paperless.sh` or patch Vault
directly with `vault kv patch
secret/homelab/productivity/paperless-secret oidc-client-secret=<value>`,
then force-sync the ExternalSecret as above. Chart values/version live
only in the inlined `helm.values` block in
`k8s/argocd/applications/paperless.yaml`.
