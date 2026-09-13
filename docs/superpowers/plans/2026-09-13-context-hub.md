# Context Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a new self-hosted GitLab project (`homelab/projects/context-hub`) holding cross-project `CLAUDE.md` context, ADRs, notes, runbooks, journal entries, references, and ideas — organized per-project — rendered as a searchable wiki via GitLab Pages + Starlight, with GitLab Issues (multiple boards) as the active task tracker.

**Architecture:** GitLab Pages is enabled on the existing self-hosted GitLab Omnibus deployment (`k8s/charts/gitlab-omnibus`) — a new wildcard SAN on the existing internal-CA certificate, a new container port, and a new Service port + wildcard Ingress host rule. A new, separate GitLab project (outside `homelab-infra`, mirroring `coder-workspace`/`supabase-functions`) holds the 6-subfolder-per-project markdown skeleton nested under `src/content/docs/` (Starlight's required content location) plus a `.gitlab-ci.yml` `pages` job. homelab-infra's own `CLAUDE.md` gets a single `@import` line pointing at the new repo's `CLAUDE.md`.

**Tech Stack:** cert-manager, Traefik, GitLab CE Omnibus (Helm chart `k8s/charts/gitlab-omnibus`), GitLab CI + Kaniko-free static build, Astro + Starlight, GitLab Issues/Boards.

**Spec:** `docs/superpowers/specs/2026-09-13-context-hub-design.md`

## Global Constraints

- Never put a real secret value in a `Secret`/`ConfigMap`/Helm `values:` block (repo convention, CLAUDE.md) — not triggered by this plan; no new secrets are introduced.
- **Every GitLab-side action beyond `git push` — creating the `context-hub` project, creating Issue labels/boards — is done by Johannes personally via the GitLab web UI.** The implementing agent has no GitLab API credentials configured yet (that's the separate, not-yet-implemented Coder-MCP-wiring plan) and must not attempt token-based automation against the live GitLab instance. Flag these as manual runbook steps, matching this repo's standing preference for hands-on setup actions (same treatment as Vault writes elsewhere in this repo).
- Ingress: `ingressClassName: traefik`, TLS via `homelab-wildcard-tls` (repo convention, CLAUDE.md) — Pages reuses this cert by adding a SAN, not a new cert/secret.
- Pinned versions (verified live via the npm registry, 2026-09-13): `astro` `7.3.2`, `@astrojs/starlight` `0.42.0` (peer-compatible: Starlight 0.42.0 requires `astro ^7.2.10`).
- **Correction versus the design spec — content location.** The spec's folder tree (`context-hub/<project>/<decisions|notes|...>/`) is shown at repo root. Starlight only renders markdown placed under `src/content/docs/` (a hard framework requirement, not configurable away without a custom Content Layer loader, which would be unjustified extra complexity here). This plan nests the exact same per-project/6-subfolder tree under `src/content/docs/` instead — the folder vocabulary, names, and depth are unchanged; only the path prefix differs from the spec's diagram.
- **Correction versus the design spec — sidebar config.** The spec states Starlight's sidebar "auto-groups by folder... no extra sidebar config needed." That's only true once a top-level group is registered: Starlight requires one explicit `{label, autogenerate: {directory}}` entry per top-level project folder in `astro.config.mjs`. Within a registered project folder, the 6 subfolders and their files *do* nest automatically with zero further config. Net effect: adding a new project later means adding one line to `astro.config.mjs`, not zero — documented as such in `context-hub/CLAUDE.md`'s own "adding a new project" instructions (Task 2).
- Every deployed *service* gets a Backstage catalog entry (CLAUDE.md) — **not applicable here**. `context-hub` is a GitLab project + static Pages site, not an ArgoCD-managed k8s service with a namespace/`kubernetes-id` to annotate; there is no natural `argocd/app-name` for it. No catalog entry is created in this plan (see Self-Review Notes).

---

### Task 1: Enable GitLab Pages on the self-hosted instance

**Files:**
- Modify: `k8s/infrastructure/homelab-wildcard-cert.yaml`
- Modify: `k8s/charts/gitlab-omnibus/values.yaml`
- Modify: `k8s/charts/gitlab-omnibus/templates/deployment.yaml`
- Modify: `k8s/charts/gitlab-omnibus/templates/service.yaml`

**Interfaces:**
- Produces: `*.pages.homelab.local` resolves through Traefik to GitLab's Pages daemon, TLS-covered by the existing `homelab-wildcard-tls` secret. Consumed by Task 3's `.gitlab-ci.yml` `pages` job (the actual site it publishes to) and by anyone browsing the rendered wiki.

- [ ] **Step 1: Add the Pages wildcard SAN to the existing cert**

In `k8s/infrastructure/homelab-wildcard-cert.yaml`, add one entry to `dnsNames`:

```yaml
  dnsNames:
    - "*.homelab.local"
    - "homelab.local"
    - "*.pages.homelab.local"
```

- [ ] **Step 2: Lint**

Run: `yamllint -c .yamllint.yml k8s/infrastructure/homelab-wildcard-cert.yaml`
Expected: no output.

- [ ] **Step 3: Apply live and confirm cert-manager reissues with the new SAN**

```bash
kubectl apply -f k8s/infrastructure/homelab-wildcard-cert.yaml
kubectl wait --for=condition=Ready certificate/homelab-wildcard -n infrastructure --timeout=120s
kubectl get secret homelab-wildcard-tls -n infrastructure -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"
```

Expected: the `Ready` condition is met, and the SAN list printed includes `DNS:*.pages.homelab.local` alongside the two existing entries.

- [ ] **Step 4: Add the Pages hostname default**

In `k8s/charts/gitlab-omnibus/values.yaml`, add:

```yaml
pagesHostname: pages.homelab.local
```

- [ ] **Step 5: Wire Pages into the Omnibus config + expose its port**

In `k8s/charts/gitlab-omnibus/templates/deployment.yaml`, add these three lines to the `GITLAB_OMNIBUS_CONFIG` block, directly after `registry_nginx['listen_https'] = false`:

```
                registry_nginx['listen_https'] = false
                gitlab_pages['enable'] = true
                gitlab_pages['external_http'] = ['0.0.0.0:8090']
                pages_external_url 'https://{{ .Values.pagesHostname }}/'
```

(`external_http` binds the Pages daemon to a plain-HTTP TCP port inside the container — the same "TLS terminates at Traefik, GitLab listens HTTP internally" pattern already used for the main app's `nginx['listen_https'] = false`/`registry_nginx['listen_https'] = false`.)

Add a matching container port, next to the existing `ssh`/`registry` entries:

```yaml
            - name: pages
              containerPort: 8090
```

- [ ] **Step 6: Expose it via the Service and add the wildcard Ingress host**

In `k8s/charts/gitlab-omnibus/templates/service.yaml`, add a Service port next to `registry`:

```yaml
    - name: pages
      port: 8090
      targetPort: pages
```

And add a third host entry to the existing Ingress's `rules` list, next to `registry.homelab.local`:

```yaml
    - host: "*.{{ .Values.pagesHostname }}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: 8090
```

- [ ] **Step 7: Lint the modified chart files**

Run: `yamllint -c .yamllint.yml k8s/charts/gitlab-omnibus/values.yaml k8s/charts/gitlab-omnibus/templates/deployment.yaml k8s/charts/gitlab-omnibus/templates/service.yaml`
Expected: no output (pre-existing Go-template syntax in these files already lints clean today — confirm your edits didn't introduce new issues, not that templating itself is an issue).

- [ ] **Step 8: Render exactly what ArgoCD renders, and apply it live**

```bash
yq '.spec.source.helm.values' k8s/argocd/applications/gitlab.yaml > /tmp/gitlab-app-values.yaml
helm template gitlab k8s/charts/gitlab-omnibus --namespace gitlab -f /tmp/gitlab-app-values.yaml > /tmp/gitlab-rendered.yaml
grep -A2 "name: pages" /tmp/gitlab-rendered.yaml
```

Expected: the rendered output shows the new `pages` container port and Service port. (If `yq` isn't installed, extract the `helm.values:` block from `k8s/argocd/applications/gitlab.yaml` by hand into `/tmp/gitlab-app-values.yaml` instead.)

- [ ] **Step 9: Apply live — this restarts the running GitLab pod (heads-up, not a bug)**

The Deployment's `strategy.type: Recreate` means editing the pod template stops the old pod fully before starting the new one — GitLab (and the container registry) will be briefly unreachable during this step, expected and one-time.

```bash
kubectl apply -f /tmp/gitlab-rendered.yaml
kubectl rollout status deployment/gitlab -n gitlab --timeout=600s
```

Expected: `deployment "gitlab" successfully rolled out` (Omnibus's internal `reconfigure` + service startup can take a few minutes on a fresh pod — the generous timeout is deliberate).

- [ ] **Step 10: Verify Pages is actually listening and routed correctly**

```bash
kubectl logs -n gitlab -l app=gitlab --tail=200 | grep -i "gitlab-pages"
kubectl get svc gitlab -n gitlab -o jsonpath='{.spec.ports[?(@.name=="pages")]}'
curl -sk -o /dev/null -w '%{http_code}\n' https://nonexistent-namespace.pages.homelab.local/
```

Expected: the logs show the Pages daemon starting with no fatal errors, the Service port JSON shows `"port":8090`, and the `curl` against a namespace that doesn't exist yet returns a GitLab Pages `404` (not a connection error, not a TLS handshake failure) — confirming routing and the cert both work end-to-end before any real site exists to serve.

- [ ] **Step 11: Commit and push**

```bash
git add k8s/infrastructure/homelab-wildcard-cert.yaml k8s/charts/gitlab-omnibus/
git commit -m "feat(gitlab): enable GitLab Pages (wildcard cert SAN, pages port/ingress)"
git push
```

This task is fully self-contained and already live-verified, so it pushes immediately rather than waiting on later tasks.

---

### Task 2: context-hub repo — folder skeleton + top-level CLAUDE.md

**Files** (in a new, separate local clone — not part of the `homelab-infra` repository, mirroring where `coder-workspace`/`supabase-functions` live locally):
- Create: `~/Code/gitlab/context-hub/CLAUDE.md`
- Create: `~/Code/gitlab/context-hub/src/content/docs/global/{decisions,notes,runbooks,journal,references,ideas}/.gitkeep`

**Interfaces:**
- Produces: the conventions every future note/ADR/journal entry follows (label vocabulary, frontmatter, commit style) — consumed by every later human/agent write to this repo, and by Task 4's `@import`.

- [ ] **Step 1: Create the folder skeleton**

```bash
mkdir -p ~/Code/gitlab/context-hub
cd ~/Code/gitlab/context-hub
for t in decisions notes runbooks journal references ideas; do
  mkdir -p "src/content/docs/global/$t"
  touch "src/content/docs/global/$t/.gitkeep"
done
```

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
# context-hub

Cross-project context for Johannes's homelab work: standing background,
architecture decisions, working notes, runbooks, journal entries,
references, and unrefined ideas — spanning homelab-infra, the Coder
workspace, the everything-app, and anything else that needs a shared home.

This file is imported by every project repo's own `CLAUDE.md` via
`@~/Code/gitlab/context-hub/CLAUDE.md`, so anything written here is visible
to every Claude Code session in the Coder workspace, regardless of which
project repo it started in.

## Layout

Each project gets its own top-level folder under `src/content/docs/`, with
exactly these 6 subfolders:

| Folder | Purpose | Naming | Frontmatter |
|---|---|---|---|
| `decisions/` | ADRs | `NNNN-title.md`, numbered per project | `title`, `date`, `status` (proposed/accepted/superseded), `project` |
| `notes/` | Point-in-time findings/writeups worth keeping | `YYYY-MM-DD-title.md` | `title`, `date`, `project` |
| `runbooks/` | Step-by-step operational how-tos, kept updated in place | `title.md` | `title`, `project`, `updated` |
| `journal/` | Freeform dated worklog / session handoff notes, one file per day per project | `YYYY-MM-DD.md` | `date`, `project` |
| `references/` | Durable external pointers (chart versions, API quirks, vendor gotchas) | `title.md` | `title`, `project`, `updated` |
| `ideas/` | Unrefined backlog, pre-spec concepts | `title.md` | `title`, `project`, `status` (raw/refining/promoted) |

`global/` (already scaffolded) holds anything spanning more than one
project. `status: promoted` on an idea means it graduated to a real spec
elsewhere — the idea file stays as a historical record, linking to where
it landed.

## Adding a new project

1. `mkdir -p src/content/docs/<project>/{decisions,notes,runbooks,journal,references,ideas}`
2. Add one entry to `astro.config.mjs`'s `starlight.sidebar` array:
   `{ label: '<Project>', autogenerate: { directory: '<project>' } }`
   (Starlight does not auto-discover new top-level folders — this one line
   is required for the new project to show up in the rendered wiki nav.)
3. Add the matching `project:<project>` GitLab label (see below).

## Labels and boards

Issue labels mirror the folder vocabulary exactly: `project:homelab-infra`,
`project:coder-workspace`, `project:everything-app`, `project:global`
(extended per step above), plus `type:task`/`type:idea`/`type:question`.
Multiple boards exist against this one label set — one grouped by
`project:*`, another by `type:*` — both additive, not exclusive.

## Commit conventions

Conventional Commits, scoped by project folder:
`docs(homelab-infra): add ADR-0004 coder MCP wiring`,
`docs(everything-app): journal 2026-09-20`.
```

- [ ] **Step 3: Verify the skeleton is complete**

Run: `find ~/Code/gitlab/context-hub/src/content/docs/global -type f`
Expected: 6 `.gitkeep` files, one per subfolder.

- [ ] **Step 4: Initialize the local repo (project creation + push happen in Task 5)**

```bash
cd ~/Code/gitlab/context-hub
git init
git add CLAUDE.md src/
git commit -m "feat: add context-hub folder skeleton + conventions"
```

Do not push — the GitLab project `homelab/projects/context-hub` doesn't exist yet; Task 5's runbook creates it and pushes.

---

### Task 3: Starlight/Astro site + `.gitlab-ci.yml` Pages job

**Files** (same local clone as Task 2):
- Create: `~/Code/gitlab/context-hub/package.json`
- Create: `~/Code/gitlab/context-hub/astro.config.mjs`
- Create: `~/Code/gitlab/context-hub/.gitlab-ci.yml`

**Interfaces:**
- Consumes: the `src/content/docs/` tree (Task 2).
- Produces: a `dist/` build output that the CI `pages` job renames to `public/` — the artifact GitLab Pages serves at `https://homelab.pages.homelab.local/projects/context-hub` once pushed (exact path per GitLab's own `<namespace>.<pages-domain>/<project-path-after-namespace>` scheme — confirm the live URL GitLab prints after the first successful `pages` job run, rather than assume the exact slug).

- [ ] **Step 1: Write `package.json`**

```json
{
  "name": "context-hub",
  "type": "module",
  "scripts": {
    "build": "astro build"
  },
  "dependencies": {
    "astro": "7.3.2",
    "@astrojs/starlight": "0.42.0"
  }
}
```

- [ ] **Step 2: Write `astro.config.mjs`**

```javascript
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  integrations: [
    starlight({
      title: "context-hub",
      sidebar: [
        { label: "global", autogenerate: { directory: "global" } },
      ],
    }),
  ],
});
```

(Per this plan's "sidebar config" correction: each project folder needs its own entry here, added per the `CLAUDE.md` instructions in Task 2. Only `global` exists yet.)

- [ ] **Step 3: Install dependencies and build locally to confirm it's valid**

```bash
cd ~/Code/gitlab/context-hub
npm install
npm run build
ls dist/
```

Expected: `npm install` and `npm run build` both succeed (exit code 0), and `dist/` contains an `index.html`.

- [ ] **Step 4: Write `.gitlab-ci.yml`**

```yaml
pages:
  image: node:24-slim
  script:
    - npm install
    - npm run build
    - mv dist public
  artifacts:
    paths:
      - public
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
```

- [ ] **Step 5: Lint the CI file**

Run: `yamllint ~/Code/gitlab/context-hub/.gitlab-ci.yml` (default rules — this file lives outside `homelab-infra`)
Expected: no output, or only cosmetic warnings.

- [ ] **Step 6: Commit**

```bash
cd ~/Code/gitlab/context-hub
git add package.json astro.config.mjs .gitlab-ci.yml package-lock.json
git commit -m "feat: add Starlight site + GitLab Pages CI job"
```

Do not push yet — same reason as Task 2.

---

### Task 4: `@import` line in homelab-infra's own `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (repo root)

**Interfaces:**
- Consumes: the fixed clone path `~/Code/gitlab/context-hub` (this plan's convention; the actual clone-into-the-Coder-workspace mechanism belongs to the separate Coder-MCP-wiring plan).

- [ ] **Step 1: Add the import line**

At the top of `CLAUDE.md` (repo root), immediately after the `# homelab-infra` heading, add:

```markdown
@~/Code/gitlab/context-hub/CLAUDE.md
```

- [ ] **Step 2: Verify the file is still well-formed**

Run: `head -5 CLAUDE.md`
Expected: the `# homelab-infra` heading, then the new `@` import line, then a blank line before the existing prose resumes.

- [ ] **Step 3: Local sanity check, if context-hub is already cloned locally**

If `~/Code/gitlab/context-hub` exists on this machine (from Tasks 2/3's local work), start a Claude Code session in `homelab-infra` and ask it to state a rule found only in `context-hub/CLAUDE.md` (e.g. "what commit convention does context-hub use?"). If the path doesn't exist locally yet (e.g. on a machine other than the one used for this plan), the import silently resolves to nothing — expected, not an error; full verification from inside the Coder workspace is this task's real acceptance test and depends on the separate MCP-wiring plan's clone step.

- [ ] **Step 4: Commit and push**

```bash
git add CLAUDE.md
git commit -m "docs: import context-hub's standing CLAUDE.md context"
git push
```

---

### Task 5: End-to-end rollout runbook

**Files:**
- Create: `docs/context-hub-setup.md`

**Interfaces:** none — this is the document Johannes follows to execute every remaining manual step (GitLab project creation, push, label/board setup) and verify the result, mirroring `docs/coder-setup.md`'s structure.

- [ ] **Step 1: Write the runbook**

```markdown
# Context Hub Setup Runbook

One-time setup for the context-hub GitLab project. Prerequisite: Tasks 1-4
of the implementation plan are committed (and Task 1 pushed/live).

**Prerequisites:**
- `kubectl` configured, cluster reachable
- Access to the self-hosted GitLab instance (`gitlab.homelab.local`)
- The local clone at `~/Code/gitlab/context-hub` (Tasks 2-3)

---

## 1. Create the GitLab project

1. `https://gitlab.homelab.local` → **New project** → `homelab/projects/context-hub`
2. **Settings → CI/CD → Variables** → set `HOMELAB_CA_CRT` as a File variable
   (same value as the `backstage`/`coder-workspace`/`supabase-functions` projects)
3. Push:

```bash
cd ~/Code/gitlab/context-hub
git remote add origin git@gitlab.homelab.local:homelab/projects/context-hub.git
git push -u origin main
```

4. Watch the pipeline: `https://gitlab.homelab.local/homelab/projects/context-hub/-/pipelines`
5. Once the `pages` job succeeds, note the Pages URL GitLab prints under
   **Settings → Pages** — confirm it resolves and renders the `global`
   section.

---

## 2. Create labels

**Project → Issues → Labels → New label**, one per row:

| Label | Color (suggested) |
|---|---|
| `project:homelab-infra` | `#1f75cb` |
| `project:coder-workspace` | `#1f75cb` |
| `project:everything-app` | `#1f75cb` |
| `project:global` | `#1f75cb` |
| `type:task` | `#428bca` |
| `type:idea` | `#428bca` |
| `type:question` | `#428bca` |

---

## 3. Create boards

**Project → Issues → Boards → Create new board**:
1. Board 1, "By project": add one list per `project:*` label above.
2. Board 2, "By type": add one list per `type:*` label above.

---

## 4. Verification

- [ ] Pages URL from Step 1.5 renders and is searchable (Starlight's built-in
      Pagefind search box returns results for a word from the `global`
      section).
- [ ] Both boards from Step 3 show up under **Issues → Boards**, switchable
      via the board-picker dropdown.
- [ ] Create one test Issue with both a `project:*` and a `type:*` label;
      confirm it appears on both boards simultaneously.
- [ ] Full `@import` verification from inside the Coder workspace is
      covered by the separate Coder-MCP-wiring plan, once that plan's
      startup-script clone step is live.
```

- [ ] **Step 2: Verify the doc's section count**

Run: `grep -c "^## " docs/context-hub-setup.md`
Expected: `4`.

- [ ] **Step 3: Commit**

```bash
git add docs/context-hub-setup.md
git commit -m "docs(context-hub): add rollout runbook"
git push
```

---

## Self-Review Notes

- **Spec coverage:** Pages enablement (Task 1, an open prerequisite the spec itself flagged); repo + 6-folder-per-project skeleton, labels/boards mirroring folders, Conventional Commits (Task 2 + runbook Step 2); Starlight/Pages rendering (Task 3 + runbook); `@import` consumption mechanism (Task 4); all four Testing bullets from the spec are covered across Task 1 Step 10, Task 4 Step 3, and the runbook's Verification section. Backstage catalog entry deliberately omitted — see Global Constraints — since `context-hub` isn't an ArgoCD-managed k8s service.
- **Placeholder scan:** none — every file has literal, complete content. The spec's one deferred detail (exact clone mechanism into the Coder workspace) is explicitly left to the sibling MCP-wiring plan, not silently dropped.
- **Type/name consistency checked:** the 6 folder names (`decisions`/`notes`/`runbooks`/`journal`/`references`/`ideas`) match across the spec, Task 2's `CLAUDE.md`, and Task 2's `mkdir` loop; the `project:*`/`type:*` label vocabulary matches across Task 2's `CLAUDE.md` and the Task 5 runbook's label table; the fixed clone path `~/Code/gitlab/context-hub` matches across Tasks 2, 3, 4.
