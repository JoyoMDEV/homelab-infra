# Coder workspace MCP wiring

## Problem

The Coder workspace has `kubectl`/`helm`/`vault`/`terraform` CLI access
baked in, but no MCP servers — so Claude Code sessions running there can't
directly read/write GitHub issues, GitLab issues/repos (including the new
context-hub repo), or query Grafana/Loki/Prometheus without hand-rolling
API calls or shelling out to CLIs not otherwise needed. This is the second
half of "get all MCPs set up in the workspace" — the first half (what the
context-hub repo itself looks like) is covered by its own separate spec.

## Goals

- GitHub MCP server, scoped to homelab-infra (and any other needed GitHub
  repos), for issues/PRs/content.
- GitLab MCP server, scoped to the self-hosted instance, for context-hub's
  issues/boards plus repo content across `backstage`/`coder-workspace`/
  `supabase-functions`/`context-hub`.
- Grafana MCP server for querying Loki logs, Prometheus metrics, and
  Grafana dashboards directly — the one cluster service genuinely worth
  adding beyond what the CLI tools already give.
- All three configured once at the user/global Claude Code config level
  (not per-project), so they're available regardless of which repo a
  session starts in.
- Shipped as a new version of the existing `homelab-workspace` Coder
  template, applied to the existing `homelab` workspace — not a new
  template or a second workspace.
- Credentials via Vault + `ExternalSecret`, following this repo's standing
  convention, with Johannes writing the actual `vault kv put` himself.

## Non-goals

- A Kubernetes-specific MCP server. Redundant with the `kubectl`/`helm`
  CLI already installed.
- Any new in-cluster service/Deployment for the MCP servers themselves.
  They run as local processes inside the existing workspace container, no
  separate ArgoCD Application.
- Broader Grafana access changes (dashboards, alerting rules, admin
  access). Only a scoped, query-only service-account token.

## Design

### Binaries

Installed in the workspace image's `Dockerfile`, same
curl-a-pinned-release pattern already used for `kubectl`/`vault`/
`terraform`:

- `github-mcp-server` — pinned release binary from `github/github-mcp-server`.
- `mcp-grafana` — pinned release binary from `grafana/mcp-grafana`.
- GitLab MCP server — GitLab's own official MCP server if it supports
  pointing at a self-hosted CE instance; otherwise a community npm package
  installed via `npm install -g` alongside the existing Node tooling.
  Exact package to confirm at implementation time — the original plan
  file's own preference was the official server, used here as the
  starting point, not a fixed requirement.

### Config: global, not per-project

A `mcpServers` block in Claude Code's user-scope config (`~/.claude.json`,
the `claude mcp add --scope user` target), written idempotently by the
`coder_agent`'s startup script — the same script that already auto-clones
homelab-infra and installs Claude Code, and for the same reason:
`/home/coder` is a persistent PVC that predates any template change, so
anything that needs to exist there has to be ensured at startup, not baked
into the image. The written config only references environment variable
names, not secret values, e.g.:

```json
{"mcpServers": {"github": {"command": "github-mcp-server", "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_MCP_TOKEN}"}}}}
```

so the file itself contains no secret material and is safe to
overwrite/re-merge on every startup.

### Credentials

Three new keys added to the existing `coder-secret.yaml` `ExternalSecret`
(same Vault path `homelab/coder/coder-secret`, new `property` values):
`github-mcp-token`, `gitlab-mcp-token`, `grafana-mcp-token`. Injected into
the workspace pod as env vars via `secretKeyRef`
(`GITHUB_MCP_TOKEN`/`GITLAB_MCP_TOKEN`/`GRAFANA_MCP_TOKEN`) in `main.tf`,
next to the existing `CODER_AGENT_TOKEN`/`SSL_CERT_FILE` env blocks. As
with every other secret in this repo, Johannes runs the actual
`vault kv put` himself from `scripts/setup-coder.sh`'s printed
instructions — not automated here.

Token scoping:

- **GitHub**: a fine-grained PAT scoped to homelab-infra (and any other
  GitHub repos as needed), repo+issues read/write.
- **GitLab**: a personal access token with `api` scope — single-operator
  instance, matching how Coder's own access model is already single-user.
- **Grafana**: a service-account token, viewer/query-only role, created
  once in the Grafana UI — a new one-time setup step, documented the same
  way the Keycloak-client sections in `docs/keycloak-setup.md` document
  other services' one-time admin config.

### Rollout mechanism

New template version of `homelab-workspace`, pushed via the existing
`scripts/deploy-coder-template.sh`, applied with `coder update homelab` —
the existing workspace and its PVC/state are preserved; only the pod is
recreated against the new template version/image.

## Testing

- `coder-secret` `ExternalSecret` picks up the three new keys after Vault
  is seeded; `kubectl -n coder describe secret coder-secret` shows all
  three.
- After `coder update homelab`, `env | grep MCP_TOKEN` inside the
  workspace shows all three tokens set.
- `claude mcp list` inside the workspace shows all three servers
  connected.
- From a Claude Code session: read/comment on a GitHub issue in
  homelab-infra; read/create an Issue in context-hub with a `project:*`
  label; query Loki for a log line from a known pod — via the respective
  MCP tools.

## Rollout order

1. Extend `coder-secret.yaml` with the three new keys; Johannes seeds
   Vault (`homelab/coder/coder-secret`:
   `github-mcp-token`/`gitlab-mcp-token`/`grafana-mcp-token`).
2. Create the Grafana service account + token (one-time, Grafana UI).
3. `Dockerfile`: add the three MCP server binaries/packages, pinned
   versions.
4. `main.tf`: add the three `secretKeyRef` env vars; extend the startup
   script to idempotently write/merge the global `mcpServers` config.
5. `deploy-coder-template.sh` pushes the new template version;
   `coder update homelab`.
6. Run through the Testing section above.
