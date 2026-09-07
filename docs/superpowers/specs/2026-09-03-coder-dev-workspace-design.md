# Coder remote dev workspace

## Problem

Johannes develops on this homelab-infra setup (and the separate backstage
app repo, plus a few other repositories) from three machines: a personal
PC, a work laptop, and a private laptop. Today that means either keeping
tooling (kubectl, helm, vault CLI, node/python/terraform toolchains, git
auth for both GitHub and the self-hosted GitLab) set up and in sync across
all three separately, or working from whichever machine happens to already
have the right setup.

## Goals

- One persistent, always-on dev workspace, reachable from any of the three
  machines via VS Code Desktop's Remote SSH, with identical tooling and
  state (uncommitted changes, shell history, caches) regardless of which
  machine you connect from.
- Pre-configured against this cluster: `kubectl`/`helm`/the Vault CLI ready
  to use with no per-machine setup, cluster-admin-equivalent permissions
  (the same level of access already available from the Mac today).
- Fits this repo's existing patterns: deployed via ArgoCD like everything
  else, secrets through Vault, auth through Keycloak, image built via
  GitLab CI + Kaniko like the backstage app.
- Reachable only over Tailscale, same access model as every other
  `*.homelab.local` service.

## Non-goals

- Multi-user support. This is a single-operator homelab; Coder's
  multi-tenant features aren't needed, OIDC is used for convenient SSO
  login, not access control between people.
- Ephemeral/per-project workspaces. One persistent workspace matches "the
  same environment on 3 machines" — spinning up/tearing down workspaces
  per task is a different (rejected) shape for this problem.
- Building the workspace image via Coder's `envbuilder` (in-cluster
  Dockerfile build at workspace start). Rejected in favor of the GitLab
  CI + Kaniko pattern already proven end-to-end for the backstage app —
  introducing a second, different image-build mechanism for one more
  service isn't worth it.

## Design

### Coder server

Deployed via the official `coder/coder` Helm chart as an ArgoCD
`Application` (`k8s/argocd/applications/coder.yaml`), destination namespace
`coder` (new, dedicated — isolates a service whose workspaces get
cluster-admin-equivalent RBAC from the rest of the cluster).

Coder requires its own Postgres database. Reuses the existing `homelab-pg`
CNPG cluster (`k8s/infrastructure/postgres-cluster.yaml`) rather than
standing up a new Postgres instance — same pattern as Keycloak, GitLab,
Backstage, Nextcloud, and Paperless. A new `coder` database + role, added
to `scripts/setup-databases.sh` (or a new `scripts/setup-coder.sh` if it
grows complex enough to warrant its own script, matching the
`setup-minio.sh`/`setup-renovate.sh` pattern).

OIDC is mandatory at the Coder-server level (not optional/local-password
login) — `CODER_OIDC_ISSUER_URL` etc. pointed at
`https://auth.homelab.local/realms/homelab`, using a new Keycloak client
`coder`. This is a new section to add to `docs/keycloak-setup.md`
(following the existing numbered-section pattern used for the GitLab and
ArgoCD clients).

Secrets (DB password, OIDC client secret) via a new
`k8s/security/external-secrets/coder/coder-secret.yaml` `ExternalSecret`,
Vault path `homelab/coder/coder-secret` — same category-per-service
pattern as `backstage`.

### Access

Ingress `coder.homelab.local` via Traefik (`homelab-wildcard-tls`, same as
every other internal service). Reachable only over Tailscale — all three
machines need Tailscale connected and resolving `*.homelab.local`, same
requirement as reaching `argocd.homelab.local` etc. today.

VS Code Desktop's Coder extension logs into `coder.homelab.local` (via the
browser for the OIDC flow, once), then opens the workspace over SSH — the
SSH connection tunnels over the same HTTPS endpoint via Coder's own agent
protocol, no separate port/ingress needed.

### Workspace RBAC

A dedicated `ServiceAccount` (`coder-workspace-admin`, namespace `coder`)
bound via `ClusterRoleBinding` to the built-in `cluster-admin` ClusterRole
— the direct match for "the same level of access already available from
the Mac today."

Tracked as a static manifest under `k8s/security/` (synced by the existing
`security-manifests` app, same as the other RBAC grants there like
`cert-manager-webhook-hetzner-rbac.yaml`) rather than defined inside the
Coder Terraform template — a cluster-admin grant should be visible and
reviewable in the main GitOps flow, not only editable via `coder templates
push`. The workspace template references this ServiceAccount by name.

**Accepted risk, explicitly**: this grants the workspace pod full
cluster-admin. That's the deliberate goal (matching local Mac access), not
an oversight — noted here so it isn't mistaken for one later.

### Workspace image

A new GitLab project, `homelab/projects/coder-workspace`, mirroring the
backstage app repo's structure: a `Dockerfile` (base image + `kubectl`,
`helm`, the Vault CLI, `git`, `terraform`, `ansible`, Node.js, Python,
plus whatever else the "few other repositories" need — to be filled in
against their actual requirements when this is implemented, not guessed
here) and a `.gitlab-ci.yml` using the same Kaniko build-and-push pattern
already working for backstage (including the `resource_group` fix from
that work, applied from the start this time). Pushed to
`registry.homelab.local/homelab/projects/coder-workspace`.

### Workspace template

A Coder Terraform template (using the `coder` and `kubernetes` Terraform
providers) defining: a `coder_agent`, a `kubernetes_pod` running the image
above under the `coder-workspace-admin` ServiceAccount, and a
`PersistentVolumeClaim` for `/home/coder` so dotfiles, shell history, and
tool caches survive workspace restarts.

Template source lives in this repo at `k8s/coder-templates/homelab-workspace/`
(kept alongside everything else here, not only inside Coder's own
storage) and is pushed to the running Coder instance via `coder templates
push` — a manual/scripted step (`scripts/deploy-coder-template.sh`,
matching this repo's existing `scripts/setup-<service>.sh` convention),
since Coder templates aren't native Kubernetes resources ArgoCD can sync
directly.

### Git access from the workspace

The workspace needs credentials for both GitHub (homelab-infra) and the
self-hosted GitLab (backstage + the few other repos) — an SSH key or
token seeded into the workspace's persistent home directory (or via Vault
+ a startup script in the Coder agent's init) rather than baked into the
image. Exact mechanism (deploy key vs. personal token vs. reusing an
existing key) is an implementation-time decision, not fixed here.

## Testing

- `coder templates push` succeeds and a workspace can be created from it.
- From each of the three machines: VS Code Desktop's Coder extension can
  log in via Keycloak OIDC, connect to the workspace over SSH, and see the
  same files/state as the other two machines.
- Inside the workspace: `kubectl get nodes`, `helm list -A`, and a Vault
  CLI command against `vault.security.svc.cluster.local` all succeed
  without additional per-machine setup.
- Git operations against both GitHub and the self-hosted GitLab succeed
  from inside the workspace.
- Restart the workspace pod (or let it be rescheduled) and confirm
  `/home/coder` state (shell history, an uncommitted test file) survives.

## Rollout order

1. `scripts/setup-coder.sh` (or the `setup-databases.sh` addition): create
   the `coder` Postgres database/role.
2. Keycloak: create the `coder` OIDC client, document it as a new section
   in `docs/keycloak-setup.md`.
3. `k8s/security/external-secrets/coder/coder-secret.yaml` +
   `k8s/security/coder-workspace-admin-rbac.yaml` (or similar), synced via
   `security-manifests`.
4. `k8s/argocd/applications/coder.yaml` — deploy Coder server itself,
   verify OIDC login works.
5. New GitLab project `homelab/projects/coder-workspace` — Dockerfile +
   `.gitlab-ci.yml`, build and push the image.
6. `k8s/coder-templates/homelab-workspace/` — the Terraform template,
   pushed via `scripts/deploy-coder-template.sh`.
7. Create the workspace, verify from all three machines per the Testing
   section above.
