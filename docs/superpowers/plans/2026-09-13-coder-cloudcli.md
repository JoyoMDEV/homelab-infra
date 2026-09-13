# Coder CloudCLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CloudCLI (`@cloudcli-ai/cloudcli`) to the existing persistent Coder workspace so Johannes can drive the real, already-configured Claude Code session from a phone or desktop browser, gated by the same Keycloak login Coder's dashboard already requires — via a `coder_app` resource, not a new Ingress.

**Architecture:** CloudCLI installs into the already-extended `coder-workspace` image (same repo/CI as the MCP servers), started as a backgrounded process by the workspace template's startup script, and exposed via a new `coder_app` Terraform resource (`share = "owner"`) proxied entirely through Coder's own authenticated session — no new Kubernetes Service, Ingress, Middleware, or Keycloak client.

**Tech Stack:** Node.js (`@cloudcli-ai/cloudcli`, `node-pty` native addon), Docker/Kaniko (image build), Coder (`coder` Terraform provider — `coder_agent`, `coder_app`).

**Spec:** `docs/superpowers/specs/2026-09-13-coder-cloudcli-design.md`

## Global Constraints

- Pinned version: `@cloudcli-ai/cloudcli@1.37.3` (verified live via the npm registry, 2026-09-13).
- No new Ingress/Service/Traefik Middleware/Keycloak OIDC client — access goes entirely through the `coder_app` proxy, `share = "owner"` (spec Non-goals).
- **`main.tf` changes in this plan are `terraform fmt`/`validate` only — no live apply, no `coder templates push`, no `coder update`.** Same rule as the MCP-wiring plan: `homelab` is Johannes's actual daily-driver workspace, and pushing/updating it is a deliberate manual step he runs himself (this plan's final task documents it in the runbook).
- No process supervision/restart-on-crash for CloudCLI (spec Non-goals) — a plain backgrounded process, recovered by `coder restart homelab` if it ever dies.
- `node-pty` (CloudCLI's terminal-driving dependency) has no prebuilt binary published and compiles from source at `npm install` time — the image needs a C++ toolchain it doesn't currently have.

---

### Task 1: `coder-workspace` image — add CloudCLI

**Files** (existing separate local clone, already pushed to `homelab/projects/coder-workspace`):
- Modify: `~/Code/gitlab/coder-workspace/Dockerfile`

**Interfaces:**
- Produces: image `registry.homelab.local/homelab/projects/coder-workspace:latest` with the `cloudcli` binary on `PATH`, plus a **confirmed, live-tested invocation** (exact env var/flag for the listen port) — consumed by Task 2's startup-script block and `coder_app` resource.

- [ ] **Step 1: Add a C++ toolchain and the CloudCLI install**

In `~/Code/gitlab/coder-workspace/Dockerfile`, insert after the existing `# GitLab MCP server` block and before the `# Non-root user` block:

```dockerfile
# C++ toolchain - CloudCLI's node-pty dependency has no prebuilt binary
# and compiles a native addon from source at npm install time.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

# CloudCLI - self-hosted web UI for Claude Code (github.com/siteboon/claudecodeui),
# reads/writes the same ~/.claude config, so it drives the actual configured
# session rather than a separate one.
RUN npm install -g @cloudcli-ai/cloudcli@1.37.3
```

- [ ] **Step 2: Build the image locally**

Run: `docker build -t coder-workspace:cloudcli-test ~/Code/gitlab/coder-workspace/`
Expected: build succeeds (exit code 0) — this is the real test that `node-pty` actually compiles with the newly-added toolchain. If it fails during the `npm install -g @cloudcli-ai/cloudcli` step with a `node-gyp`/compiler error, the `build-essential` package didn't pull in something needed (check the error for the specific missing tool, e.g. `python3` — already present — or a missing header package) and adjust the `apt-get install` list accordingly.

- [ ] **Step 3: Discover the real port/invocation syntax**

```bash
docker run --rm coder-workspace:cloudcli-test cloudcli --help
```

Expected: usage output showing how the listen port is configured (an env var like `PORT`, or a flag like `--port`). CloudCLI's own docs only confirm the *default* is `3001` with no documented override mechanism — this step finds the real one. Note the exact mechanism found; it's needed verbatim for Task 2.

- [ ] **Step 4: Live-test that it actually starts and listens**

```bash
docker run --rm -d --name cloudcli-test -p 3001:3001 coder-workspace:cloudcli-test cloudcli
sleep 3
curl -sf -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:3001/
docker logs cloudcli-test
docker stop cloudcli-test
```

Expected: the `curl` prints an HTTP status (200 or a redirect — anything but a connection failure confirms the server is up), and `docker logs` shows CloudCLI's own startup output with no fatal errors. If port `3001` isn't right per Step 3's findings, substitute the correct port/flag from that step here instead.

- [ ] **Step 5: Commit and push**

```bash
cd ~/Code/gitlab/coder-workspace
git add Dockerfile
git commit -m "feat: add CloudCLI web UI"
git push
```

- [ ] **Step 6: Watch the pipeline**

Open `https://gitlab.homelab.local/homelab/projects/coder-workspace/-/pipelines` (or, if credentials aren't available in this environment, use the same `kubectl logs -n gitlab gitlab-runner-<pod> --tail=60 | grep coder-workspace` approach already used for the MCP-server task) and confirm the build succeeds, publishing the updated image.

---

### Task 2: `main.tf` — startup script + `coder_app` resource

**Files:**
- Modify: `k8s/coder-templates/homelab-workspace/main.tf`

**Interfaces:**
- Consumes: the confirmed port/invocation from Task 1 (this task's steps below assume `PORT=3001` and a plain `cloudcli` invocation as the default case — adjust every occurrence below to match whatever Task 1 actually found if it differs).
- Produces: the updated `homelab-workspace` template (validated, not live-applied) — consumed by Task 3's runbook (`deploy-coder-template.sh` + `coder update homelab`).

- [ ] **Step 1: Add the CloudCLI startup block**

In `coder_agent.main.startup_script`, at the very end (after the existing MCP-server-registration block's closing `fi`), add:

```bash
    # CloudCLI - backgrounded, PID-file-guarded so it isn't started twice on
    # a workspace restart. No process supervision if it crashes - `coder
    # restart homelab` re-runs this script and starts it again.
    if [ ! -f "$HOME/.cloudcli.pid" ] || ! kill -0 "$(cat "$HOME/.cloudcli.pid")" 2>/dev/null; then
      PORT=3001 nohup cloudcli > "$HOME/.cloudcli.log" 2>&1 &
      echo $! > "$HOME/.cloudcli.pid"
    fi
```

- [ ] **Step 2: Add the `coder_app` resource**

After the `coder_agent "main"` resource block (before `resource "kubernetes_persistent_volume_claim_v1" "home"`), add:

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

- [ ] **Step 3: Format check**

Run: `terraform fmt -check k8s/coder-templates/homelab-workspace/`
Expected: no output, exit code 0. If it fails, run `terraform fmt k8s/coder-templates/homelab-workspace/` and re-check.

- [ ] **Step 4: Validate**

```bash
cd k8s/coder-templates/homelab-workspace
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit and push**

```bash
cd ../../..
git add k8s/coder-templates/homelab-workspace/main.tf
git commit -m "feat(coder): add CloudCLI web UI via coder_app"
git push
```

Do **not** run `terraform apply`, `coder templates push`, or `coder update` — that's a manual step in Task 3's runbook, at a time Johannes chooses (it restarts the live daily-driver workspace pod).

---

### Task 3: Rollout runbook

**Files:**
- Modify: `docs/coder-setup.md`

**Interfaces:** none — this is where Johannes pushes the template and restarts the live workspace.

- [ ] **Step 1: Renumber the existing Troubleshooting section**

In `docs/coder-setup.md`, renumber `## 9. Troubleshooting` to `## 10. Troubleshooting` (only this one header line changes).

- [ ] **Step 2: Insert the new section 9, before the renumbered Troubleshooting section**

```markdown
## 9. CloudCLI (Web-/Mobile-Zugriff auf Claude Code)

**Voraussetzung:** Tasks 1-2 aus `docs/superpowers/plans/2026-09-13-coder-cloudcli.md`
sind committed und gepusht; die `coder-workspace`-Pipeline (Task 1) ist grün.

### 9.1 Template pushen und Workspace aktualisieren

Das aktualisiert den bereits laufenden, persönlichen `homelab`-Workspace -
der Pod startet dabei neu (kurze Unterbrechung, `/home/coder`-Zustand auf
dem PVC bleibt erhalten).

```bash
coder login https://coder.homelab.local
./scripts/deploy-coder-template.sh
coder update homelab
```

### 9.2 Verifikation

- [ ] Im Workspace-Terminal: `curl -sf -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:3001/`
      zeigt einen erfolgreichen Status (kein Connection-Error).
- [ ] Auf `https://coder.homelab.local` → Workspace `homelab` → ein
      "CloudCLI"-Button erscheint auf der Workspace-Seite.
- [ ] Der Button öffnet CloudCLI und zeigt die bereits konfigurierte
      Claude-Code-Session (sichtbar an den bereits aktiven MCP-Server-
      Verbindungen: GitHub/GitLab/Grafana), nicht eine leere/neue Session.
- [ ] Vom Handy-Browser aus (im Tailnet): der Zugriff verlangt den
      Keycloak-Login (bzw. eine bereits aktive Coder-Session) - kein
      direkter, unauthentifizierter Zugriff möglich.
```

- [ ] **Step 3: Verify the doc's internal section count**

Run: `grep -c "^## " docs/coder-setup.md`
Expected: `10` (one per top-level section, up from the previous 9).

- [ ] **Step 4: Commit and push**

```bash
git add docs/coder-setup.md
git commit -m "docs(coder): add CloudCLI rollout runbook"
git push
```

---

## Self-Review Notes

- **Spec coverage:** the CloudCLI install + C++ toolchain (Task 1), the `coder_app` resource + startup-script block (Task 2), the manual rollout + verification runbook (Task 3) all match the spec's Design/Testing/Rollout order sections. The spec's explicit non-goals (no new Ingress/Service/Middleware/Keycloak client, no process supervision, no wildcard subdomain) are honored by omission — no task creates any of them.
- **Placeholder scan:** none — every file has literal, complete content. The one genuinely open detail (CloudCLI's exact port-configuration flag/env var) is resolved by Task 1's own live discovery step (Step 3), not left as a guess in the final template — Task 2 assumes the most likely default (`PORT` env var, port `3001`) explicitly flagged as adjustable per Task 1's actual findings, matching this repo's established pattern for this class of uncertainty (e.g. the MCP-wiring plan's `claude mcp add` flag-syntax handling).
- **Type/name consistency checked:** the port `3001` matches across Task 1 Step 4's live test, Task 2 Step 1's startup block, Task 2 Step 2's `coder_app.url`, and Task 3's verification `curl`; the `coder-workspace` image reference is unchanged (already `registry.homelab.local/homelab/projects/coder-workspace:latest` from prior work) so no task needed to touch it.
