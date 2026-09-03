## What it is

The internal developer portal / software catalog for this homelab — a self-hosted Backstage instance (app source lives in a separate repo, built and pushed to `registry.homelab.local/homelab/projects/backstage`). It's also the very system rendering this page, via its built-in TechDocs feature.

## Why it's here

A single place to see every deployed service, its ArgoCD sync status, and its live Kubernetes state without jumping between the ArgoCD UI, `kubectl`, and this repo. Concretely it wires together:
- The **catalog** itself, sourced straight from `catalog/all.yaml` in this repo.
- The **Kubernetes plugin**, which shows live pod/deployment status per component by querying the cluster directly — no separate credential needed, it runs under the `backstage-kubernetes-viewer` ServiceAccount bound to the built-in `view` ClusterRole, using the pod's own auto-mounted/auto-rotated in-cluster token (`kubernetes.clusterLocatorMethods[0].authProvider: serviceAccount` in `app-config.yaml`).
- The **ArgoCD plugin**, which shows live sync/health status per app using a token-only `backstage` ArgoCD account (no login capability, ArgoCD's default read-only role) — the token is injected as `ARGOCD_AUTH_TOKEN`.
- **TechDocs**, generating docs like this one locally in-process (`techdocs.generator.runIn: local`) rather than via a Docker-in-Docker builder, since the pod has no Docker socket — `mkdocs-techdocs-core` is installed directly into the runtime image instead (see the Dockerfile in the backstage app repo).
- **OIDC login** against Keycloak, so cluster users authenticate with their existing homelab identity instead of Backstage's guest auth. This is a recent addition — until this session, only guest auth actually worked in practice because the deployed image was pinned to a stale `:latest` build that predated the OIDC module being wired into the backend.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/backstage.yaml` — source is this repo (`path: k8s/charts/backstage`, `targetRevision: main`), a **local** Helm chart (no external chart repo), destination namespace `backstage`.
- Local chart: `k8s/charts/backstage/` (`Chart.yaml` app version `1.54.0`), values in `k8s/charts/backstage/values.yaml`:
  - `image.repository: registry.homelab.local/homelab/projects/backstage`, `image.tag: latest`, `imagePullPolicy: Always`
  - `hostname: backstage.homelab.local`
  - resource requests/limits (512Mi/250m requests, 1Gi/500m limits)
- `templates/deployment.yaml`: runs as `serviceAccountName: backstage-kubernetes-viewer`, pulls the image via the `backstage-registry-pull` imagePullSecret, mounts the `homelab-ca` secret at `/etc/ssl/homelab` (`NODE_EXTRA_CA_CERTS`) so the backend trusts the internal CA when calling other `*.homelab.local` services, and connects to Postgres at `homelab-pg-rw.infrastructure.svc.cluster.local:5432` as user `backstage`.
- `templates/rbac.yaml`: creates the `backstage-kubernetes-viewer` ServiceAccount and a ClusterRoleBinding to the built-in `view` ClusterRole (read-only, explicitly excludes Secret contents) — this is what powers the Kubernetes plugin cluster-wide.
- `templates/service.yaml`: a ClusterIP Service plus a plain `networking.k8s.io/v1` Ingress (not a Traefik `IngressRoute`) with `ingressClassName: traefik`, host `backstage.homelab.local`.
- ExternalSecrets, both in `k8s/security/external-secrets/backstage/`, namespace `backstage`:
  - `backstage-secret.yaml` → Vault path `homelab/backstage/backstage-secret`, keys `db-password`, `auth-session-secret`, `oidc-client-secret`, `argocd-token` (injected as `POSTGRES_PASSWORD`, `AUTH_SESSION_SECRET`, `AUTH_OIDC_CLIENT_SECRET`, `ARGOCD_AUTH_TOKEN`)
  - `backstage-registry-pull.yaml` → Vault path `homelab/backstage/registry-pull-secret`, templated into a `kubernetes.io/dockerconfigjson` for pulling from `registry.homelab.local`
- Postgres role: the `backstage` Postgres role needs `CREATEDB` (see `scripts/setup-databases.sh`) — Backstage's backend auto-creates one database per plugin on startup (`backstage_plugin_app`, `backstage_plugin_catalog`, ...), unlike other services here that use a single pre-created database, so the role must have that grant or startup fails.
- App config (in the separate `backstage` app repo, not this one): `app-config.yaml` sets `catalog.locations` to this repo's `catalog/all.yaml`, `kubernetes`/`argocd` config as described above, and `techdocs.generator.runIn: local`; `app-config.production.yaml` overrides `backend.listen` to bind all interfaces and reads the same `POSTGRES_*` env vars. `auth.providers.oidc.production` points at `https://auth.homelab.local/realms/homelab/.well-known/openid-configuration` with `clientId: backstage`, resolving users via `preferredUsernameMatchingUserEntityName`. The backend (`packages/backend/src/index.ts`) registers both `plugin-auth-backend-module-guest-provider` and `plugin-auth-backend-module-oidc-provider`.

## How to change it

- **Deploy a new app image** (after a change in the backstage app repo, e.g. CI build): the chart is pinned to `image.tag: latest` with `imagePullPolicy: Always`, so a new push to `registry.homelab.local/homelab/projects/backstage:latest` plus a `kubectl -n backstage rollout restart deployment/backstage` (or ArgoCD selfHeal on a values bump) picks it up. If OIDC/auth behavior seems stuck on old behavior (e.g. guest-only login), check that the running pod actually pulled a fresh image — this exact symptom happened this session because of a stale cached `:latest`.
- **Add/rotate a secret** (DB password, session secret, OIDC client secret, ArgoCD token): write the new value to Vault at `homelab/backstage/backstage-secret` (`db-password`, `auth-session-secret`, `oidc-client-secret`, or `argocd-token`); the ExternalSecret refreshes hourly, or force it with `kubectl -n backstage annotate externalsecret backstage-secret force-sync=$(date +%s) --overwrite`, then restart the deployment. If rotating `db-password`, also update the Postgres role's password (see `scripts/setup-databases.sh`, Backstage DB section) so they stay in sync.
- **Change the catalog contents**: this is driven entirely by `catalog/all.yaml` and the per-service `catalog/<service>/catalog-info.yaml` files in this repo — no redeploy of Backstage itself needed, it polls the catalog location on its own schedule.
- **Change resource limits or hostname**: edit `k8s/charts/backstage/values.yaml` directly (it's a local chart, no upstream version to track) and let ArgoCD sync.
- **Grant/restrict Kubernetes visibility**: edit the ClusterRoleBinding in `k8s/charts/backstage/templates/rbac.yaml` — currently bound to the built-in `view` ClusterRole cluster-wide; narrow it to a Role+RoleBinding per-namespace if broader visibility ever becomes a concern.
