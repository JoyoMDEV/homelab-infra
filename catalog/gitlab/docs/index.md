## What it is

GitLab CE (Omnibus, single-container) — self-hosted source control, CI/CD, and container registry, running at `https://gitlab.homelab.local` with the built-in container registry at `https://registry.homelab.local`.

## Why it's here

This cluster needs a private place to host the `homelab-infra` repo and run CI/CD for it and other projects, without depending on GitHub for anything but mirroring. GitLab also doubles as the Docker registry for locally-built images and is the identity the `gitlab-runner` and `renovate` services build against — `renovate`'s job is actually to open MRs/PRs against the GitHub mirror of this same repo, and `gitlab-runner` executes GitLab CI pipelines inside this same cluster.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/gitlab.yaml`, `spec.destination.namespace: gitlab`.
- Chart: a **local** chart at `k8s/charts/gitlab-omnibus` (not an upstream GitLab chart) — a single `gitlab/gitlab-ce:latest` container Deployment (`k8s/charts/gitlab-omnibus/templates/deployment.yaml`) with `strategy: Recreate` and three PVCs (`k8s/charts/gitlab-omnibus/templates/pvc.yaml`): config (2Gi), data (30Gi), logs (2Gi). Chart defaults live in `k8s/charts/gitlab-omnibus/values.yaml` (resources: 4Gi/2 CPU requests, 6Gi memory limit).
- The ArgoCD Application overrides `hostname: gitlab.homelab.local` and enables OIDC (`oidc.enabled: true`, issuer `https://auth.homelab.local/realms/homelab`, `clientId: gitlab`) via inline `helm.values` in `k8s/argocd/applications/gitlab.yaml`.
- Ingress (`k8s/charts/gitlab-omnibus/templates/service.yaml`): Traefik `ingressClassName: traefik`, host `gitlab.homelab.local` (HTTP) plus a second host `registry.homelab.local` routed to the container registry port (5050). SSH (port 22, for git-over-ssh) is exposed separately through a Traefik `IngressRouteTCP` on the `ssh` entrypoint (see the comment in `service.yaml` — this replaced a `hostPort` that stopped working after the move to Cilium).
- GitLab does **not** run its own bundled Postgres/Redis: `postgresql['enable'] = false` / `redis['enable'] = false` in the Omnibus config. It uses the shared CNPG cluster `homelab-pg-rw.infrastructure.svc.cluster.local` (database `gitlab`, role `gitlab`) and `redis-master.infrastructure.svc.cluster.local`.
- ExternalSecrets (both in namespace `gitlab`):
  - `k8s/security/external-secrets/gitlab/gitlab-secret.yaml` → Vault `homelab/gitlab/gitlab-secret`, keys `db-password`, `redis-password`, `oidc-client-secret`.
  - `k8s/security/external-secrets/gitlab/gitlab-rails-secrets.yaml` → Vault `homelab/gitlab/rails-secrets`, keys `secret_key_base`, `db_key_base`, `otp_key_base`, `ci_job_token_signing_key` (a generated RSA key used for CI job token signing). `refreshInterval: 24h` — deliberately slow, since these are encryption keys for data at rest and must never rotate out from under a running instance.
- A `homelab-ca` Secret is mounted into an init container that installs the cluster's internal CA into `/etc/gitlab/trusted-certs`, so GitLab trusts the cluster's own TLS chain.

## How to change it

- Application/version bump: this is a local chart, so there's no `targetRevision` to bump for the app itself — update `image.tag` in `k8s/charts/gitlab-omnibus/values.yaml` (currently `latest`) or `appVersion` in `k8s/charts/gitlab-omnibus/Chart.yaml`, commit, and let ArgoCD sync (auto-sync with prune/selfHeal is enabled).
- Omnibus config changes (nginx, registry, OIDC, Rails settings): edit the `GITLAB_OMNIBUS_CONFIG` block in `k8s/charts/gitlab-omnibus/templates/deployment.yaml`.
- Database/Redis credentials and OIDC client secret: run `scripts/setup-databases.sh` (idempotent — it creates the `gitlab` Postgres database/role on the shared `homelab-pg` cluster and seeds `homelab/gitlab/gitlab-secret` in Vault only if that path doesn't already exist; re-running with an existing password there reuses it via `ALTER ROLE` rather than generating a new one). The OIDC client secret starts as `REPLACE_AFTER_KEYCLOAK_SETUP` and must be patched in manually once the Keycloak client is created.
- Rails encryption keys (`homelab/gitlab/rails-secrets`): only ever created once by `scripts/setup-databases.sh` if the Vault path doesn't exist. **Never delete or overwrite this path** — it encrypts data already stored in the database; losing it means losing access to encrypted GitLab data.
- If any of these Vault secrets are ever found empty/missing even though GitLab is running fine: don't assume the credentials were lost. Check whether the live Kubernetes Secret still has a valid value first (`kubectl get secret gitlab-secret -n gitlab -o jsonpath='{.data.<key>}' | base64 -d`) and copy that back into Vault (`vault kv patch secret/homelab/gitlab/gitlab-secret <key>=-`, piping the decoded value in) rather than regenerating — this exact situation happened with `renovate-secret` and `velero-secret` after a cleanup script deleted their Vault entries while the cluster kept running on the still-valid Kubernetes Secrets.
- Runner tokens are a separate service — see `gitlab-runner`'s docs.
