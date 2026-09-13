## What it is

A persistent, always-on remote development workspace — a self-hosted [Coder](https://coder.com) instance plus one long-running workspace `Pod`, reachable from any machine via VS Code Desktop's Remote SSH (through the Coder extension), with identical tooling and state (uncommitted changes, shell history, caches) regardless of which machine connects.

## Why it's here

Johannes develops this repo (and a few others) from three machines — a personal PC, a work laptop, and a private laptop. Rather than keeping `kubectl`/`helm`/the Vault CLI/`terraform`/`ansible`/Node.js/Python in sync across all three, one workspace runs in-cluster with cluster-admin-equivalent access (the same level already available from the Mac) and all three machines just SSH into it.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/coder.yaml` — Coder's official Helm chart (`coder/coder`, `https://helm.coder.com/v2`, pinned `2.37.0`), destination namespace `coder`.
- Database: the `coder` Postgres role/database on the shared `homelab-pg` CNPG cluster (`k8s/infrastructure/postgres-cluster.yaml`), created by `scripts/setup-coder.sh`.
- OIDC: mandatory login via Keycloak (`CODER_DISABLE_PASSWORD_AUTH=true`), client `coder` documented in `docs/keycloak-setup.md` section 6.
- Secrets: `k8s/security/external-secrets/coder/coder-secret.yaml` (Vault path `homelab/coder/coder-secret` — DB password, OIDC client secret, git SSH private key, GitHub/GitLab/Grafana MCP tokens) and `k8s/security/external-secrets/coder/coder-workspace-registry-pull.yaml` (Vault path `homelab/coder/registry-pull-secret`).
- Workspace RBAC: `k8s/security/coder-workspace-admin-rbac.yaml` — `ServiceAccount coder-workspace-admin` bound to the built-in `cluster-admin` `ClusterRole`, synced via the `security-manifests` app. Explicit accepted risk — see `docs/superpowers/specs/2026-09-03-coder-dev-workspace-design.md`.
- Workspace image: built from a separate GitLab project, `homelab/projects/coder-workspace` (Dockerfile with `kubectl`/`helm`/the Vault CLI/`git`/`terraform`/`ansible`/Node.js/Python, plus the `github-mcp-server`/`mcp-gitlab`/`mcp-grafana` MCP servers registered with Claude Code on startup), via GitLab CI + Kaniko, pushed to `registry.homelab.local/homelab/projects/coder-workspace`.
- Workspace template: `k8s/coder-templates/homelab-workspace/main.tf` (Terraform, `coder`+`hashicorp/kubernetes` providers), pushed to the running Coder instance via `scripts/deploy-coder-template.sh` — not synced by ArgoCD, since Coder templates aren't native Kubernetes resources.
- Ingress: `coder.homelab.local` via Traefik, `homelab-wildcard-tls`, reachable only over Tailscale.

## How to change it

- **Rotate the OIDC client secret or DB password**: write the new value to Vault at the relevant `homelab/coder/coder-secret` key, then force-sync: `kubectl -n coder annotate externalsecret coder-secret force-sync=$(date +%s) --overwrite`.
- **Add a tool to the workspace image**: edit the `Dockerfile` in the `coder-workspace` GitLab project, push to `main` — CI builds and pushes `registry.homelab.local/homelab/projects/coder-workspace:latest` automatically. Restart the workspace pod (`imagePullPolicy: Always`) to pick it up.
- **Change workspace resources/disk size**: edit `k8s/coder-templates/homelab-workspace/main.tf`, then re-run `./scripts/deploy-coder-template.sh` and let Coder re-provision the workspace.
- **Rotate the git SSH deploy key**: re-run the SSH-keygen section of `scripts/setup-coder.sh` (delete the Vault path first to force regeneration), register the new public key with GitHub/GitLab, restart the workspace pod.
- **Rotate a GitHub/GitLab/Grafana MCP token**: write the new value to Vault at the relevant `homelab/coder/coder-secret` key (see `docs/coder-setup.md` section 8.0 for where each token comes from) — no automatic rotation path exists yet beyond that; the Claude Code MCP config only ever references the env var by name (`${VAR}`, never the literal value), so it self-heals on the next workspace restart (`coder restart homelab`) without any manual re-registration step.
