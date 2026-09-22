## What it is

The web build of **everything-app** — a personal life-management super-app (Kalender, Kochbuch, Chat, Standort, Notizen, Journal, Partner, ...), app source lives in a separate repo (`homelab/projects/everything-app`), built and pushed to `registry.homelab.local/homelab/projects/everything-app`. Web is the **secondary** target (a static Expo Router export served by nginx) — the primary target is native iOS/Android apps, not deployed here (see the ADR: iOS needs a macOS/Xcode toolchain this cluster can't provide, and there's no app-store distribution yet, so native builds aren't part of this cluster's footprint at all).

## Why it's here

To have a stable, always-on way to reach the app without keeping a `expo start` dev server running in a Coder workspace session. Full architecture rationale (backend hybrid, sharing model, monorepo tooling) lives in `context-hub`'s `everything-app/decisions/` — this page only covers the deployment side.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/everything-app.yaml` — source is this repo (`path: k8s/charts/everything-app`, `targetRevision: main`), a **local** Helm chart, destination namespace `everything-app`.
- Local chart: `k8s/charts/everything-app/` (`Chart.yaml`), values in `k8s/charts/everything-app/values.yaml`:
  - `image.repository: registry.homelab.local/homelab/projects/everything-app`, `image.tag: latest`, `imagePullPolicy: Always`
  - `hostname: everything-app.homelab.local`
  - resource requests/limits (64Mi/25m requests, 128Mi/100m limits — just nginx serving static files, no app server)
- `templates/deployment.yaml`: pulls the image via the `everything-app-registry-pull` imagePullSecret. No database connection, no app secrets at runtime - the Supabase URL/anon-key are baked into the static JS bundle at **build time** (Expo's `EXPO_PUBLIC_*` mechanism), via this project's GitLab CI/CD variables (`EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY`), not injected at deploy time.
- `templates/service.yaml`: a ClusterIP Service plus a plain `networking.k8s.io/v1` Ingress (not a Traefik `IngressRoute`) with `ingressClassName: traefik`, host `everything-app.homelab.local`. Tailscale-only reachability for now, per the ADR — no public Traefik/Authelia route.
- ExternalSecret, `k8s/security/external-secrets/everything-app/everything-app-registry-pull.yaml` → Vault path `homelab/everything-app/registry-pull-secret`, templated into a `kubernetes.io/dockerconfigjson` for pulling from `registry.homelab.local`. Provisioned via `scripts/setup-everything-app.sh` (needs a GitLab Deploy Token with `read_registry` scope for the `everything-app` project, and `VAULT_TOKEN` - run manually, not something an agent session can do unattended, see `global/references/coder-workspace-auto-mode-guardrails.md` in context-hub).
- App repo CI (`Dockerfile.web`, `.gitlab-ci.yml` in `homelab/projects/everything-app`): Kaniko build, same mechanics as `supabase-functions`' pipeline, plus this project's own `HOMELAB_CA_CRT` file variable (copied from `supabase-functions`' - Kaniko needs it to trust the internal CA when pushing to the in-cluster registry, and it isn't inherited from anywhere group-level, so every new app project needs its own copy).

## How to change it

- App code/UI: the separate `everything-app` repo (`apps/mobile`).
- Deployment config (image tag pin, resources, hostname): this chart's `values.yaml`.
- Build-time public config (Supabase URL/anon-key): this project's GitLab CI/CD variables, not this repo.
