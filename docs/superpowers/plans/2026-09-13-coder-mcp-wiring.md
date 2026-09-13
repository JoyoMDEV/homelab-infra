# Coder MCP Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GitHub, GitLab, and Grafana MCP servers to the existing persistent Coder workspace (`homelab-workspace` template, `homelab` workspace) — configured globally so they're available in every Claude Code session regardless of which repo it starts in — plus close the context-hub clone gap the sibling context-hub plan deferred here.

**Architecture:** Three MCP server binaries/packages are added to the already-existing `coder-workspace` image (a separate GitLab project, already deployed). Three new secret keys extend the existing `coder-secret` `ExternalSecret`, injected into the workspace pod as env vars via `secretKeyRef`. The `coder_agent`'s startup script (in `k8s/coder-templates/homelab-workspace/main.tf`) grows two new idempotent blocks: registering the three MCP servers at Claude Code's user scope, and cloning `context-hub` alongside the existing `homelab-infra` clone. All of this ships as a new template *version* of the existing template — not a new template or a second workspace.

**Tech Stack:** Kubernetes (`kubernetes_pod_v1` env/secretKeyRef), External Secrets Operator + Vault, GitLab CI + Kaniko, Coder (`coder` + `hashicorp/kubernetes` Terraform providers), Claude Code CLI (`claude mcp add`).

**Spec:** `docs/superpowers/specs/2026-09-13-coder-mcp-wiring-design.md`

## Global Constraints

- Never put a real secret value in a `Secret`/`ConfigMap`/Helm `values:` block — every secret flows through the existing `ExternalSecret` at Vault path `homelab/coder/coder-secret` (repo convention, CLAUDE.md).
- **Vault writes are always run by the user personally.** The implementing agent writes and validates `scripts/setup-coder.sh`'s changes (syntax check, review) but must **never execute it**, and must never run any `vault kv put`/`kubectl exec vault-0 -- vault ...` command itself (standing preference, not spec-derived).
- **Applying the updated Coder template to the live `homelab` workspace is a manual runbook step, not something this plan's tasks execute automatically.** Unlike a first-time service rollout, `homelab` is already Johannes's actual daily-driver workspace — `coder update homelab` restarts its pod (brief interruption; PVC-backed state survives). This plan's code/config tasks (1-4) only write and locally validate files; Task 5's runbook is where the push/update actually happens, at a time Johannes chooses.
- Pinned versions (verified live via GitHub's release API and the npm registry, 2026-09-13): `github/github-mcp-server` `v1.12.1` (asset `github-mcp-server_Linux_x86_64.tar.gz`); `grafana/mcp-grafana` `v1.4.1` (asset `mcp-grafana_Linux_x86_64.tar.gz`); `@zereight/mcp-gitlab` `2.1.61` (community package — see spec for why not an official GitLab-maintained one; bin name `mcp-gitlab`).
- No Kubernetes-specific MCP server, no new in-cluster Deployment for any of the three servers (spec non-goals) — all three run as local processes inside the existing workspace container.
- Grafana MCP server needs a Grafana **service account token**, viewer/query-only role — a one-time manual step in the Grafana UI, documented in Task 5's runbook, not automated here.

## Prerequisites — generate these before Task 1 starts

None of these depend on `scripts/setup-coder.sh` existing yet — go generate all three now and hold onto them. (Unlike context-hub's prerequisites, this plan can't front-load *everything*: the script that actually consumes these tokens doesn't exist until Task 1 writes it, so there's one unavoidable manual checkpoint — running that script — right after Task 1, before Task 2. Everything else needing you personally is front-loaded here.)

1. **GitHub**: `https://github.com/settings/personal-access-tokens/new` — fine-grained PAT, repository access at least `homelab-infra`, permissions "Issues" + "Pull requests" (Read and write), "Contents" (Read-only).
2. **GitLab**: `https://gitlab.homelab.local/-/user_settings/personal_access_tokens` — scope `api`.
3. **Grafana**: `https://grafana.homelab.local/org/serviceaccounts` — new service account, role `Viewer`, then a token under it.

---

### Task 1: `scripts/setup-coder.sh` — seed the three MCP tokens

**Files:**
- Modify: `scripts/setup-coder.sh`

**Interfaces:**
- Produces: three additional properties at the existing Vault path `homelab/coder/coder-secret` — `github-mcp-token`, `gitlab-mcp-token`, `grafana-mcp-token`. Consumed by Task 2's `ExternalSecret` additions.

- [ ] **Step 1: Add a new prompt block, after the existing registry-pull-credentials block**

In `scripts/setup-coder.sh`, insert this immediately before the final `echo "==========..."` summary block (i.e. after the existing `REGISTRY_VAULT_PATH` block closes):

```bash
echo ""
MCP_VAULT_PATH="homelab/coder/coder-secret"
GITHUB_TOKEN_SET=$(vault_kv_get "${MCP_VAULT_PATH}" "github-mcp-token")
if [[ -n "${GITHUB_TOKEN_SET}" ]]; then
  echo "    github-mcp-token existiert bereits in Vault - nichts zu tun."
else
  echo "==> GitHub MCP: Fine-grained Personal Access Token"
  echo "    Scope: nur die Repos, die der Agent braucht (mind. homelab-infra),"
  echo "    Berechtigungen 'Issues' + 'Pull requests' (read/write), 'Contents' (read)."
  read -rsp "    GitHub Token (wird nicht angezeigt): " GITHUB_MCP_TOKEN
  echo ""

  echo "==> GitLab MCP: Personal Access Token (api scope)"
  read -rsp "    GitLab Token (wird nicht angezeigt): " GITLAB_MCP_TOKEN
  echo ""

  echo "==> Grafana MCP: Service-Account-Token (Viewer-Rolle)"
  read -rsp "    Grafana Token (wird nicht angezeigt): " GRAFANA_MCP_TOKEN
  echo ""

  if [[ -z "${GITHUB_MCP_TOKEN}" ]] || [[ -z "${GITLAB_MCP_TOKEN}" ]] || [[ -z "${GRAFANA_MCP_TOKEN}" ]]; then
    echo "    FEHLER: Mindestens ein Token ist leer. Abbruch."
    exit 1
  fi

  vault_kv_put "${MCP_VAULT_PATH}" \
    "github-mcp-token=${GITHUB_MCP_TOKEN}" \
    "gitlab-mcp-token=${GITLAB_MCP_TOKEN}" \
    "grafana-mcp-token=${GRAFANA_MCP_TOKEN}"

  force_sync coder-secret coder
fi
```

Note: `vault_kv_put` with a partial key set does a `vault kv put` (full overwrite of the path's fields as given), not a per-field patch — since this repo's existing `coder-secret` path is only ever written to by this one script, and this block runs after the earlier `db-password`/`oidc-client-secret`/`git-ssh-private-key` block already wrote those, use `vault kv patch` semantics instead to avoid clobbering them:

```bash
  kubectl exec -n "${VAULT_NS}" "${VAULT_POD}" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="${VAULT_TOKEN}" \
    vault kv patch "secret/${MCP_VAULT_PATH}" \
    "github-mcp-token=${GITHUB_MCP_TOKEN}" \
    "gitlab-mcp-token=${GITLAB_MCP_TOKEN}" \
    "grafana-mcp-token=${GRAFANA_MCP_TOKEN}" >/dev/null
```

Use this `vault kv patch` form in place of the `vault_kv_put` call above.

- [ ] **Step 2: Syntax-check the script**

Run: `bash -n scripts/setup-coder.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-coder.sh
git commit -m "feat(coder): seed GitHub/GitLab/Grafana MCP tokens"
```

Do **not** run this script yourself — see the manual checkpoint below.

---

## Manual checkpoint — before Task 2 starts

Johannes runs this now, using the three tokens generated in Prerequisites:

```bash
export VAULT_TOKEN="..."
./scripts/setup-coder.sh
```

Paste each token in at its prompt. Once this completes, `homelab/coder/coder-secret` in Vault has all seven keys and Task 2 can proceed.

---

### Task 2: `ExternalSecret` — add the three MCP token keys

**Files:**
- Modify: `k8s/security/external-secrets/coder/coder-secret.yaml`

**Interfaces:**
- Consumes: Vault path `homelab/coder/coder-secret`, properties `github-mcp-token`/`gitlab-mcp-token`/`grafana-mcp-token` (Task 1).
- Produces: `Secret coder-secret` (namespace `coder`) gains keys `github-mcp-token`, `gitlab-mcp-token`, `grafana-mcp-token` — consumed by Task 4's `secretKeyRef` env vars.

- [ ] **Step 1: Add three `data` entries**

In `k8s/security/external-secrets/coder/coder-secret.yaml`, append to the existing `data` list:

```yaml
    - secretKey: github-mcp-token
      remoteRef:
        key: homelab/coder/coder-secret
        property: github-mcp-token
    - secretKey: gitlab-mcp-token
      remoteRef:
        key: homelab/coder/coder-secret
        property: gitlab-mcp-token
    - secretKey: grafana-mcp-token
      remoteRef:
        key: homelab/coder/coder-secret
        property: grafana-mcp-token
```

- [ ] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/security/external-secrets/coder/coder-secret.yaml`
Expected: no output.

- [ ] **Step 3: Precondition — confirm Task 1 was already run, before applying live**

Run: `kubectl exec -n security vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$VAULT_TOKEN vault kv get secret/homelab/coder/coder-secret`
Expected: prints all seven keys now (`db-password`, `oidc-client-secret`, `git-ssh-private-key`, plus the three new ones). **If the three new keys are missing, stop here and do not apply this file** — `external-secrets` syncs an `ExternalSecret`'s `data` list all-or-nothing; applying this now would put the *already-working* `coder-secret` (which the live Coder server and workspace both depend on) into a sync-error state until Johannes runs `scripts/setup-coder.sh`. Ask Johannes to run it first.

- [ ] **Step 4: Apply live and verify all seven keys sync**

```bash
kubectl apply -f k8s/security/external-secrets/coder/coder-secret.yaml
kubectl get externalsecret coder-secret -n coder
kubectl get secret coder-secret -n coder -o jsonpath='{.data}' | python3 -m json.tool
```

Expected: `STATUS SecretSynced`, and the printed JSON now lists all seven keys (the four pre-existing ones untouched, plus the three new ones).

- [ ] **Step 5: Commit**

```bash
git add k8s/security/external-secrets/coder/coder-secret.yaml
git commit -m "feat(coder): add ExternalSecret keys for GitHub/GitLab/Grafana MCP tokens"
```

Do not push yet — Task 4 pushes homelab-infra changes together once the template is fully validated.

---

### Task 3: `coder-workspace` image — add the three MCP server binaries

**Files** (existing separate local clone, already pushed to `homelab/projects/coder-workspace`):
- Modify: `~/Code/gitlab/coder-workspace/Dockerfile`

**Interfaces:**
- Produces: image `registry.homelab.local/homelab/projects/coder-workspace:latest` now also containing `github-mcp-server`, `mcp-grafana`, and `mcp-gitlab` on `PATH` — consumed by the workspace pod once Task 5's runbook triggers a pod restart against the new image (`imagePullPolicy: Always`, no template change needed for this alone).

- [ ] **Step 1: Add the three server installs**

In `~/Code/gitlab/coder-workspace/Dockerfile`, insert after the existing `# Ansible` block and before the `# Non-root user` block:

```dockerfile
# GitHub MCP server (pinned release binary)
RUN curl -fsSL -o /tmp/github-mcp-server.tar.gz \
      https://github.com/github/github-mcp-server/releases/download/v1.12.1/github-mcp-server_Linux_x86_64.tar.gz \
    && tar -xzf /tmp/github-mcp-server.tar.gz -C /usr/local/bin github-mcp-server \
    && rm /tmp/github-mcp-server.tar.gz \
    && chmod +x /usr/local/bin/github-mcp-server

# Grafana MCP server (pinned release binary)
RUN curl -fsSL -o /tmp/mcp-grafana.tar.gz \
      https://github.com/grafana/mcp-grafana/releases/download/v1.4.1/mcp-grafana_Linux_x86_64.tar.gz \
    && tar -xzf /tmp/mcp-grafana.tar.gz -C /usr/local/bin mcp-grafana \
    && rm /tmp/mcp-grafana.tar.gz \
    && chmod +x /usr/local/bin/mcp-grafana

# GitLab MCP server (community package - see homelab-infra's
# 2026-09-13-coder-mcp-wiring-design.md for why not an official one)
RUN npm install -g @zereight/mcp-gitlab@2.1.61
```

- [ ] **Step 2: Build the image locally to confirm it's valid**

Run: `docker build -t coder-workspace:mcp-test ~/Code/gitlab/coder-workspace/`
Expected: build succeeds (exit code 0). If the `tar -xzf ... -C /usr/local/bin <name>` step fails with "not found in archive," the archive's internal layout differs from the flat-binary assumption made here — run `curl -fsSL <url> | tar -tz` first to see the real path inside the archive and adjust the `-C`/path argument accordingly, then rebuild.

- [ ] **Step 3: Sanity-check the three new binaries**

```bash
docker run --rm coder-workspace:mcp-test sh -c \
  "github-mcp-server --version && mcp-grafana --version && mcp-gitlab --version"
```

Expected: each prints a version string with no errors.

- [ ] **Step 4: Commit and push (this repo already has a remote and CI configured)**

```bash
cd ~/Code/gitlab/coder-workspace
git add Dockerfile
git commit -m "feat: add GitHub/Grafana/GitLab MCP servers"
git push
```

- [ ] **Step 5: Watch the pipeline**

Open `https://gitlab.homelab.local/homelab/projects/coder-workspace/-/pipelines` and confirm the build succeeds, publishing `registry.homelab.local/homelab/projects/coder-workspace:latest`.

---

### Task 4: `main.tf` — env vars + startup script additions

**Files:**
- Modify: `k8s/coder-templates/homelab-workspace/main.tf`

**Interfaces:**
- Consumes: `Secret coder-secret` keys `github-mcp-token`/`gitlab-mcp-token`/`grafana-mcp-token` (Task 2); the context-hub repo existing at `git@gitlab.homelab.local:homelab/projects/context-hub.git` (sibling context-hub plan, Task 5 there).
- Produces: the updated `homelab-workspace` Coder template — consumed by Task 5's `deploy-coder-template.sh` + `coder update homelab`.

- [ ] **Step 1: Add the three secret-backed env vars**

In the `container` block, add these three `env` blocks next to the existing `CODER_AGENT_TOKEN` one:

```hcl
      env {
        name = "GITHUB_MCP_TOKEN"
        value_from {
          secret_key_ref {
            name = "coder-secret"
            key  = "github-mcp-token"
          }
        }
      }

      env {
        name = "GITLAB_MCP_TOKEN"
        value_from {
          secret_key_ref {
            name = "coder-secret"
            key  = "gitlab-mcp-token"
          }
        }
      }

      env {
        name = "GRAFANA_MCP_TOKEN"
        value_from {
          secret_key_ref {
            name = "coder-secret"
            key  = "grafana-mcp-token"
          }
        }
      }
```

- [ ] **Step 2: Clone context-hub alongside homelab-infra**

In `coder_agent.main.startup_script`, immediately after the existing `homelab-infra` clone block (`if [ ! -d "$HOME/homelab-infra/.git" ]; then ... fi`), add:

```bash
    mkdir -p "$HOME/Code/gitlab"
    if [ ! -d "$HOME/Code/gitlab/context-hub/.git" ]; then
      git clone git@gitlab.homelab.local:homelab/projects/context-hub.git "$HOME/Code/gitlab/context-hub" || \
        echo "WARN: context-hub clone failed - continuing"
    fi
```

- [ ] **Step 3: Register the three MCP servers**

At the end of `startup_script`, after the existing Claude Code CLI install block, add:

```bash
    if command -v claude >/dev/null 2>&1; then
      if ! claude mcp list 2>/dev/null | grep -q '^github'; then
        claude mcp add --scope user github github-mcp-server \
          --env GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_MCP_TOKEN" || \
          echo "WARN: 'claude mcp add github' failed - check 'claude mcp add --help' for the current flag syntax"
      fi
      if ! claude mcp list 2>/dev/null | grep -q '^gitlab'; then
        claude mcp add --scope user gitlab mcp-gitlab \
          --env GITLAB_PERSONAL_ACCESS_TOKEN="$GITLAB_MCP_TOKEN" \
          --env GITLAB_API_URL="https://gitlab.homelab.local/api/v4" || \
          echo "WARN: 'claude mcp add gitlab' failed - check 'claude mcp add --help' for the current flag syntax"
      fi
      if ! claude mcp list 2>/dev/null | grep -q '^grafana'; then
        claude mcp add --scope user grafana mcp-grafana \
          --env GRAFANA_URL="https://grafana.homelab.local" \
          --env GRAFANA_SERVICE_ACCOUNT_TOKEN="$GRAFANA_MCP_TOKEN" || \
          echo "WARN: 'claude mcp add grafana' failed - check 'claude mcp add --help' for the current flag syntax"
      fi
    fi
```

(`claude mcp add`'s exact flag names can shift between CLI versions — the `grep -q`-guarded idempotency check and the `||` fallback warning are deliberate so a flag mismatch fails loudly and skippably at workspace start, rather than silently, and can be fixed by adjusting these lines once the real CLI's `--help` output is checked live in Task 5.)

- [ ] **Step 4: Format check**

Run: `terraform fmt -check k8s/coder-templates/homelab-workspace/`
Expected: no output, exit code 0. If it fails, run `terraform fmt k8s/coder-templates/homelab-workspace/` and re-check.

- [ ] **Step 5: Validate**

```bash
cd k8s/coder-templates/homelab-workspace
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit and push**

```bash
cd ../../..
git add k8s/coder-templates/homelab-workspace/ k8s/security/external-secrets/coder/coder-secret.yaml
git commit -m "feat(coder): wire GitHub/GitLab/Grafana MCP servers into the workspace template"
git push
```

(Bundles Task 2's already-committed `ExternalSecret` change into the same push, matching this repo's pattern of pushing related commits together.)

---

### Task 5: Rollout runbook

**Files:**
- Modify: `docs/coder-setup.md`

**Interfaces:** none — by this point the manual checkpoint (tokens + Vault) is already done; this is where Johannes pushes the template and restarts the live workspace.

- [ ] **Step 1: Update the runbook's section numbering**

In `docs/coder-setup.md`, renumber the existing `## 8. Troubleshooting` header to `## 9. Troubleshooting` (only this one header line changes).

- [ ] **Step 2: Insert the new section 8, before the renumbered Troubleshooting section**

```markdown
## 8. MCP-Server hinzufügen (GitHub/GitLab/Grafana)

**Voraussetzung:** Tasks 1-4 aus `docs/superpowers/plans/2026-09-13-coder-mcp-wiring.md`
sind committed und gepusht; die `coder-workspace`-Pipeline (Task 3) ist grün;
die drei Tokens wurden bereits generiert und per `scripts/setup-coder.sh`
in Vault geschrieben (Prerequisites + Manual-Checkpoint des Implementation
Plans).

### 8.1 Template pushen und Workspace aktualisieren

Das aktualisiert den bereits laufenden, persönlichen `homelab`-Workspace -
der Pod startet dabei neu (kurze Unterbrechung, `/home/coder`-Zustand auf
dem PVC bleibt erhalten). Zu einem Zeitpunkt ausführen, an dem eine kurze
Unterbrechung okay ist.

```bash
coder login https://coder.homelab.local
./scripts/deploy-coder-template.sh
coder update homelab
```

### 8.2 Verifikation

- [ ] `kubectl -n coder describe secret coder-secret` zeigt alle sieben Keys.
- [ ] Im Workspace-Terminal: `env | grep MCP_TOKEN` zeigt alle drei Tokens.
- [ ] `claude mcp list` zeigt `github`, `gitlab`, `grafana` als verbunden.
      Falls ein Server fehlt: `claude mcp add --help` prüfen, ob sich die
      Flag-Syntax seit diesem Plan geändert hat, die betroffene Zeile in
      `k8s/coder-templates/homelab-workspace/main.tf`s `startup_script`
      anpassen, Task 4 Schritte 4-6 wiederholen.
- [ ] In einer Claude-Code-Session im Workspace: ein GitHub-Issue in
      `homelab-infra` lesen/kommentieren; ein GitLab-Issue in `context-hub`
      mit einem `project:*`-Label anlegen; eine Loki-Logzeile eines
      bekannten Pods über die Grafana-MCP-Tools abfragen.
- [ ] `ls $HOME/Code/gitlab/context-hub` im Workspace zeigt den geklonten
      Context-Hub-Checkout.
```

- [ ] **Step 3: Verify the doc's internal section count**

Run: `grep -c "^## " docs/coder-setup.md`
Expected: `9` (one per top-level section, up from the original 8).

- [ ] **Step 4: Commit and push**

```bash
git add docs/coder-setup.md
git commit -m "docs(coder): add MCP server rollout runbook"
git push
```

---

## Self-Review Notes

- **Spec coverage:** GitHub/GitLab/Grafana MCP servers (Task 3), global (not per-project) Claude Code config via the startup script (Task 4 Step 3), same-template-new-version rollout (Task 5, explicit "not a new template" framing preserved from the spec), Vault-backed credentials with user-run writes (Task 1/5), context-hub clone gap closed (Task 4 Step 2) exactly as the sibling spec deferred it here.
- **Placeholder scan:** none — every file has literal, complete content. The one acknowledged uncertainty (`claude mcp add`'s exact current flags) is handled with a live-checkable fallback (`grep`-guarded idempotency + a `||` warning pointing at `--help`), not a bare TBD.
- **Type/name consistency checked:** the three env var names (`GITHUB_MCP_TOKEN`/`GITLAB_MCP_TOKEN`/`GRAFANA_MCP_TOKEN`) match across Tasks 2's underlying Secret keys, Task 4's `secretKeyRef` blocks, and Task 4's `claude mcp add` invocations; the `coder-secret` Secret/ExternalSecret name matches across Tasks 1, 2, 4; the context-hub clone path `$HOME/Code/gitlab/context-hub` matches the sibling context-hub plan's `~/Code/gitlab/context-hub` convention.
