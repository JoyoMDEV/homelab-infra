# CloudCLI in the Coder workspace

## Problem

Johannes wants to talk to Claude Code — the exact session running in his
persistent Coder workspace, with all its configured MCP servers and repo
clones — from a basic terminal or web UI, including from his phone.
Anthropic's official "Remote Control" feature would cover this but
requires a Max plan he doesn't have.

## Goals

- A web UI reachable from a phone (or any browser) that drives the real,
  already-configured Claude Code session in the `homelab` workspace — not
  a second, separately-configured instance.
- Reuses the existing persistent workspace entirely: same `~/.claude`
  state, same MCP servers (GitHub/GitLab/Grafana), same cloned repos —
  zero duplicated setup.
- Access requires the same Keycloak login already used to reach this
  workspace via Coder's own dashboard — not a weaker, second door into a
  workspace that already has cluster-admin-equivalent RBAC.
- Ships as another addition to the same `homelab-workspace` template and
  `coder-workspace` image already extended for MCP wiring — not a new
  template, workspace, or repo.

## Non-goals

- Anthropic's official Remote Control (`/rc`) — requires a Max plan,
  revisit if the user's plan changes later.
- A separate Ingress/Service/Traefik Middleware/Keycloak OIDC client for
  this specifically. `coder_app` with `share = "owner"` gives the same
  Keycloak-gated access for free, proxied entirely through the Coder
  server — building a parallel auth stack would be strictly worse
  (more moving parts, no better security).
- A wildcard subdomain for Coder workspace apps (Coder's own
  recommendation for multi-tenant same-origin isolation). This is a
  single-operator, single-workspace homelab — the risk that
  recommendation addresses doesn't apply, and setting up a wildcard
  domain is its own chunk of infra for no real benefit here. Path-based
  app access (the default) is used instead.
- Process supervision/restart-on-crash for CloudCLI. A plain backgrounded
  process matches how this startup script already treats similar
  tooling; a crash is recovered by `coder restart homelab`, same as
  anything else in this workspace.

## Design

### What CloudCLI actually is

[`@cloudcli-ai/cloudcli`](https://github.com/siteboon/claudecodeui)
(published as `@cloudcli-ai/cloudcli`, pinned `1.37.3`, AGPL-3.0-or-later)
is a Node.js web server that reads/writes the same `~/.claude` config
Claude Code itself uses, auto-discovering existing sessions rather than
spawning new ones. It drives the real `claude` CLI via `node-pty`
(pseudoterminal), which is why it needs to run in the same environment as
the CLI and its config — not a remote/API-only integration. `node-pty` is
a native Node addon (depends on `node-addon-api`) with no prebuilt binary
published, so installing it compiles from source at `npm install` time,
requiring a C++ toolchain in the image.

The tool has no built-in authentication of its own — access control is
entirely external, which is exactly what `coder_app`'s proxying provides
here.

### Where it runs: the existing `coder-workspace` container

CloudCLI installs into the same Docker image already extended for the
GitHub/GitLab/Grafana MCP servers (`~/Code/gitlab/coder-workspace/Dockerfile`,
already pushed and building via that repo's own GitLab CI). Requires
adding a C++ toolchain (`build-essential` or the minimal
`python3`/`make`/`g++` set — `python3` is already present, `make`/`g++`
are not) so `npm install -g @cloudcli-ai/cloudcli@1.37.3`'s `node-pty`
step actually compiles.

### How it's started: the workspace template's startup script

`k8s/coder-templates/homelab-workspace/main.tf`'s `coder_agent.main.startup_script`
grows one more idempotent block, after the existing MCP-server
registration block: start CloudCLI in the background if it isn't already
running (a PID-file or port-check guard, matching the "skip if already
present" idiom already used for the repo clones and Claude Code install
in this same script), logging to a file under `$HOME` for troubleshooting
rather than discarding output.

Exact invocation (binary name, port flag/env var, whether it needs an
explicit `--headless`/non-interactive flag) is confirmed live via
`cloudcli --help` at implementation time rather than guessed here — same
approach this repo already took for `claude mcp add`'s flag syntax.
Default port is `3001` per CloudCLI's own docs; pin explicitly rather
than relying on the default in case it changes upstream.

### How it's reached: a new `coder_app` resource, not a new Ingress

A `coder_app` resource added to the same `kubernetes_pod_v1`/`coder_agent`
template:

```hcl
resource "coder_app" "cloudcli" {
  agent_id     = coder_agent.main.id
  slug         = "cloudcli"
  display_name = "CloudCLI"
  url          = "http://localhost:3001"
  icon         = "/icon/code.svg"
  share        = "owner"
}
```

This appears as an "Open" button on the `homelab` workspace's page in
Coder's own dashboard (`coder.homelab.local`), for both desktop and phone
browsers. Clicking it is proxied entirely through the already-running,
already-Keycloak-authenticated Coder session — reaching it requires the
exact same login Coder's dashboard itself already requires, with no
separate credential, Ingress, Service, or Traefik config anywhere in this
repo. `share = "owner"` (the default, set explicitly here for clarity)
restricts it to Johannes specifically, matching the single-operator model
already used for this whole workspace.

### Data flow

Phone or desktop browser → `https://coder.homelab.local` (Keycloak login
if no active session) → workspace page → "CloudCLI" app button → Coder
server proxies the request to `localhost:3001` inside the workspace pod →
CloudCLI's own UI → drives the same `claude` process/session already
configured with the GitHub/GitLab/Grafana MCP servers and the
homelab-infra/context-hub repo clones.

## Testing

- `docker build`/sanity-check the updated `coder-workspace` image locally
  (matching the pattern from the MCP-server task): confirm
  `npm install -g @cloudcli-ai/cloudcli@1.37.3` succeeds (i.e. the C++
  toolchain addition actually lets `node-pty` compile) and `cloudcli
  --version` (or equivalent) runs.
- After the template version is pushed and `coder update homelab` is run
  (a manual step, same as the MCP-wiring plan's own rollout): confirm the
  CloudCLI process is listening (`curl localhost:3001` from inside the
  workspace), the "CloudCLI" app button appears on the workspace's Coder
  dashboard page, and opening it loads the UI.
- From a phone browser over Tailscale: confirm reaching the app requires
  the Keycloak login (or an active Coder session), and that CloudCLI
  shows the existing Claude Code session (visible via its already-active
  MCP server connections and repo state), not an empty/fresh one.

## Rollout order

1. `coder-workspace` Dockerfile: add the C++ toolchain + CloudCLI install,
   sanity-check the built image locally, commit and push (own repo, own
   CI, same as the MCP-server task).
2. `main.tf`: add the startup-script block + the `coder_app` resource,
   `terraform fmt`/`validate` only — no live apply, matching this
   session's established rule for changes to the already-running daily
   driver workspace.
3. Manual runbook step (`docs/coder-setup.md`, a new section): push the
   template version, run `coder update homelab`, verify per the Testing
   section above.
