# Backstage Narrative Docs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every one of the 23 catalog services a narrative doc (what/why/config/how-to-change), rendered searchably inside Backstage via TechDocs running local (in-pod) generation — no new infrastructure.

**Architecture:** TechDocs local generator (`generator.runIn: local`) replaces the currently-broken `docker` generator. Each service gets `catalog/<service>/docs/index.md` + a minimal `mkdocs.yml`, referenced by a new `backstage.io/techdocs-ref: dir:.` annotation on its existing `catalog-info.yaml`. The backstage repo's Dockerfile gains `mkdocs-techdocs-core` (pip) so `mkdocs` is available in-container.

**Tech Stack:** TechDocs (`@backstage/plugin-techdocs-backend`, already installed), `mkdocs` + `mkdocs-techdocs-core` (pip, new), YAML (`mkdocs.yml`), Markdown.

**Spec:** `docs/superpowers/specs/2026-09-03-backstage-narrative-docs-design.md`

## Global Constraints

- Every `docs/index.md` follows the exact four-section template from the spec, in this order: **What it is / Why it's here / How it's configured / How to change it**.
- "How it's configured" must cite real file paths from this repo (the service's `k8s/argocd/applications/<x>.yaml`, its Helm values, its `ExternalSecret`(s) and Vault path(s)) — never generic/invented details.
- "How to change it" must give concrete, actionable steps specific to that service, not generic advice.
- No pushing to any remote (GitHub or GitLab) as part of this plan — this session is holding all changes locally per prior agreement. Committing locally is fine once the user asks for a commit.
- Each `mkdocs.yml` is minimal: just `site_name` and the default nav (TechDocs infers structure from `docs/index.md`).

---

### Task 1: CLAUDE.md convention

**Files:**
- Modify: `CLAUDE.md` (the "Backstage catalog" bullet, in the ## Conventions section)

**Interfaces:**
- Consumes: the template definition from the spec's "Doc template" section.
- Produces: a documented, discoverable convention future sessions will read and follow (no code interface — this is documentation-only).

- [ ] **Step 1: Add the new convention**

Replace the existing "Backstage catalog" bullet in `CLAUDE.md`'s `## Conventions` section with:

```markdown
**Backstage catalog** (`catalog/`) should stay in sync with `k8s/argocd/applications/` — every deployed service should have a matching `catalog/<service>/catalog-info.yaml` registered in `catalog/all.yaml`, with `argocd/app-name` and `backstage.io/kubernetes-id` annotations matching the ArgoCD app name and k8s namespace/labels. Every service also gets `catalog/<service>/docs/index.md` (referenced via a `backstage.io/techdocs-ref: dir:.` annotation) with four fixed sections, in order: **What it is**, **Why it's here**, **How it's configured** (citing the real ArgoCD Application/Helm values/ExternalSecret/Vault path for that service), and **How to change it** (concrete steps, e.g. "to rotate this token, run `scripts/setup-X.sh`"). Keep it in sync whenever the service's config changes. Rendered via TechDocs' local generator (`mkdocs`, no external pipeline) — see `docs/superpowers/specs/2026-09-03-backstage-narrative-docs-design.md`.
```

- [ ] **Step 2: Verify the file is still valid markdown / didn't break surrounding structure**

Run: `grep -n "Backstage catalog" CLAUDE.md`
Expected: one match, inside the `## Conventions` section, with the paragraph intact.

- [ ] **Step 3: Commit**

Only if the user has asked for a commit at this point in the session (this repo's convention: never commit without being asked). If not yet asked, leave staged/unstaged and move to Task 2.

---

### Task 2: Enable local TechDocs generation (backstage repo)

**Files:**
- Modify: `/Users/johannes/Code/gitlab/backstage/Dockerfile` (runtime stage)
- Modify: `/Users/johannes/Code/gitlab/backstage/app-config.yaml` (`techdocs.generator.runIn`)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: a container image capable of running `mkdocs build` in-process; all later doc-authoring tasks assume this works.

- [ ] **Step 1: Add mkdocs to the Dockerfile's runtime stage**

In `/Users/johannes/Code/gitlab/backstage/Dockerfile`, the runtime stage (`FROM node:24-trixie-slim` at the bottom) already installs `python3 g++ build-essential libsqlite3-dev` via apt for native module builds. Add `python3-pip` to that same `apt-get install` line, then add a `pip install` step for `mkdocs-techdocs-core` right after it (before `USER node`, since apt/pip need root):

```dockerfile
# Stage 3 - Runtime-Image
FROM node:24-trixie-slim
ENV PYTHON=/usr/bin/python3
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip g++ build-essential libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*
RUN pip install --break-system-packages --no-cache-dir mkdocs-techdocs-core
USER node
```

(`--break-system-packages` is required on Debian trixie's Python, which blocks unmanaged global pip installs by default; safe here since this is a single-purpose container image, not a shared system.)

- [ ] **Step 2: Flip the generator to local**

In `/Users/johannes/Code/gitlab/backstage/app-config.yaml`, find the `techdocs:` block:

```yaml
techdocs:
  builder: 'local'
  generator:
    runIn: 'docker'
  publisher:
    type: 'local'
```

Change `runIn: 'docker'` to `runIn: 'local'`.

- [ ] **Step 3: Verify YAML validity**

Run: `cd /Users/johannes/Code/gitlab/backstage && python3 -c "import yaml; yaml.safe_load(open('app-config.yaml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify Dockerfile syntax sanity**

Run: `cd /Users/johannes/Code/gitlab/backstage && docker run --rm -i hadolint/hadolint < Dockerfile 2>&1 || true`
Expected: no new errors introduced by the added lines beyond whatever hadolint already flagged before this change (informational only — this repo has no CI hadolint gate, so don't block on pre-existing warnings).

- [ ] **Step 5: Commit**

Only if the user has asked for a commit at this point.

---

### Task 3: Docs batch 1 — infrastructure, redis, minio, vault

**Files:**
- Create: `catalog/infrastructure/docs/index.md`, `catalog/infrastructure/mkdocs.yml`
- Create: `catalog/redis/docs/index.md`, `catalog/redis/mkdocs.yml`
- Create: `catalog/minio/docs/index.md`, `catalog/minio/mkdocs.yml`
- Create: `catalog/vault/docs/index.md`, `catalog/vault/mkdocs.yml`
- Modify: `catalog/infrastructure/catalog-info.yaml`, `catalog/redis/catalog-info.yaml`, `catalog/minio/catalog-info.yaml`, `catalog/vault/catalog-info.yaml` (add `backstage.io/techdocs-ref: dir:.` annotation)

**Interfaces:**
- Consumes: the four-section template (Global Constraints), each service's `catalog-info.yaml` (existing), its ArgoCD `Application` under `k8s/argocd/applications/`, Helm values, and `ExternalSecret`(s) under `k8s/security/external-secrets/`.
- Produces: rendered TechDocs pages for these 4 services; no other task depends on this task's output.

- [ ] **Step 1: For each of the 4 services, read its real config before writing anything**

For each service: read `k8s/argocd/applications/<service>.yaml`, its `k8s/values/<service>.yaml` if present, its chart under `k8s/charts/<service>/` if local, and every `k8s/security/external-secrets/**/<service>*.yaml`. Note: `infrastructure` in this repo's catalog groups multiple raw manifests under `k8s/infrastructure/` (Postgres cluster, etc. — see `k8s/infrastructure/postgres-cluster.yaml`), not a single ArgoCD Application; document it as the shared data-layer namespace it actually is.

- [ ] **Step 2: Write `docs/index.md` for each service following the exact template**

Four sections, in order, per the Global Constraints. Example shape (fill with real facts from Step 1, don't copy this verbatim):

```markdown
# Redis

## What it is
...

## Why it's here
...

## How it's configured
- ArgoCD Application: `k8s/argocd/applications/redis.yaml`
- ...

## How to change it
- To rotate the password: ...
```

- [ ] **Step 3: Write minimal `mkdocs.yml` for each service**

```yaml
site_name: <Service Name>
```

- [ ] **Step 4: Add the techdocs-ref annotation to each catalog-info.yaml**

Add `backstage.io/techdocs-ref: dir:.` under `metadata.annotations` alongside the existing `argocd/app-name` / `backstage.io/kubernetes-id` annotations.

- [ ] **Step 5: Validate**

Run: `for f in catalog/{infrastructure,redis,minio,vault}/catalog-info.yaml catalog/{infrastructure,redis,minio,vault}/mkdocs.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`
Expected: `OK: <path>` for all 8 files.

- [ ] **Step 6: Commit**

Only if the user has asked for a commit at this point.

---

### Task 4: Docs batch 2 — keycloak, vaultwarden, external-secrets, security-manifests

**Files:**
- Create: `catalog/keycloak/docs/index.md`, `catalog/keycloak/mkdocs.yml`
- Create: `catalog/vaultwarden/docs/index.md`, `catalog/vaultwarden/mkdocs.yml`
- Create: `catalog/external-secrets/docs/index.md`, `catalog/external-secrets/mkdocs.yml`
- Create: `catalog/security-manifests/docs/index.md`, `catalog/security-manifests/mkdocs.yml`
- Modify: the corresponding 4 `catalog-info.yaml` files (add annotation)

**Interfaces:**
- Consumes: same as Task 3 (template + Global Constraints), applied to this batch's services.
- Produces: rendered TechDocs pages for these 4 services; independent of Task 3's output.

- [ ] **Step 1: Read each service's real config** (same method as Task 3 Step 1) — `k8s/argocd/applications/{keycloak,vaultwarden,external-secrets}.yaml`; `security-manifests` groups the `k8s/security/` non-ExternalSecret manifests (ClusterSecretStore, cert-manager glue, etc.) — check `k8s/argocd/applications/security-manifests.yaml` for its actual `source.path`.

- [ ] **Step 2: Write `docs/index.md` for each**, same template/format as Task 3 Step 2.

- [ ] **Step 3: Write minimal `mkdocs.yml` for each**, same as Task 3 Step 3.

- [ ] **Step 4: Add `backstage.io/techdocs-ref: dir:.` to each catalog-info.yaml**, same as Task 3 Step 4.

- [ ] **Step 5: Validate**

Run: `for f in catalog/{keycloak,vaultwarden,external-secrets,security-manifests}/catalog-info.yaml catalog/{keycloak,vaultwarden,external-secrets,security-manifests}/mkdocs.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`

- [ ] **Step 6: Commit** — only if asked.

---

### Task 5: Docs batch 3 — traefik-public, public, cert-manager-webhook-hetzner, backstage

**Files:**
- Create: `catalog/traefik-public/docs/index.md`, `catalog/traefik-public/mkdocs.yml`
- Create: `catalog/public/docs/index.md`, `catalog/public/mkdocs.yml`
- Create: `catalog/cert-manager-webhook-hetzner/docs/index.md`, `catalog/cert-manager-webhook-hetzner/mkdocs.yml`
- Create: `catalog/backstage/docs/index.md`, `catalog/backstage/mkdocs.yml`
- Modify: the corresponding 4 `catalog-info.yaml` files (add annotation)

**Interfaces:**
- Consumes: same as Task 3.
- Produces: rendered TechDocs pages for these 4 services. The `backstage` entry here is Backstage documenting itself — ground it in everything discovered/changed this session (OIDC fix, Kubernetes plugin, ArgoCD plugin, this docs system), not just its original setup.

- [ ] **Step 1: Read each service's real config** — `k8s/argocd/applications/{traefik-public,public,cert-manager-webhook-hetzner,backstage}.yaml`, plus for backstage: `k8s/charts/backstage/`, the backstage repo's `app-config.yaml`/`app-config.production.yaml`, and this session's history of fixes (CREATEDB grant, OIDC wiring, Kubernetes/ArgoCD plugins).

- [ ] **Step 2: Write `docs/index.md` for each**, same template.

- [ ] **Step 3: Write minimal `mkdocs.yml` for each.**

- [ ] **Step 4: Add annotation to each catalog-info.yaml.**

- [ ] **Step 5: Validate**

Run: `for f in catalog/{traefik-public,public,cert-manager-webhook-hetzner,backstage}/catalog-info.yaml catalog/{traefik-public,public,cert-manager-webhook-hetzner,backstage}/mkdocs.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`

- [ ] **Step 6: Commit** — only if asked.

---

### Task 6: Docs batch 4 — gitlab, gitlab-runner, renovate, velero

**Files:**
- Create: `catalog/gitlab/docs/index.md`, `catalog/gitlab/mkdocs.yml`
- Create: `catalog/gitlab-runner/docs/index.md`, `catalog/gitlab-runner/mkdocs.yml`
- Create: `catalog/renovate/docs/index.md`, `catalog/renovate/mkdocs.yml`
- Create: `catalog/velero/docs/index.md`, `catalog/velero/mkdocs.yml`
- Modify: the corresponding 4 `catalog-info.yaml` files (add annotation)

**Interfaces:**
- Consumes: same as Task 3. For `renovate` and `velero`, explicitly note in "How it's configured" that their ExternalSecrets were degraded and re-seeded earlier this session (`homelab/automation/renovate-secret`, `homelab/backup/velero-secret`) — this is exactly the kind of operational history worth having written down.

- [ ] **Step 1: Read each service's real config** — `k8s/argocd/applications/{gitlab,gitlab-runner,renovate,velero}.yaml`, `scripts/setup-renovate.sh`, `scripts/setup-velero.sh`, `k8s/infrastructure/postgres-cluster.yaml` (velero's Barman backup target), `k8s/security/external-secrets/**/{renovate,velero}-secret.yaml`.

- [ ] **Step 2: Write `docs/index.md` for each**, same template.

- [ ] **Step 3: Write minimal `mkdocs.yml` for each.**

- [ ] **Step 4: Add annotation to each catalog-info.yaml.**

- [ ] **Step 5: Validate**

Run: `for f in catalog/{gitlab,gitlab-runner,renovate,velero}/catalog-info.yaml catalog/{gitlab,gitlab-runner,renovate,velero}/mkdocs.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`

- [ ] **Step 6: Commit** — only if asked.

---

### Task 7: Docs batch 5 — nextcloud, nocodb, paperless, overleaf

**Files:**
- Create: `catalog/nextcloud/docs/index.md`, `catalog/nextcloud/mkdocs.yml`
- Create: `catalog/nocodb/docs/index.md`, `catalog/nocodb/mkdocs.yml`
- Create: `catalog/paperless/docs/index.md`, `catalog/paperless/mkdocs.yml`
- Create: `catalog/overleaf/docs/index.md`, `catalog/overleaf/mkdocs.yml`
- Modify: the corresponding 4 `catalog-info.yaml` files (add annotation)

**Interfaces:**
- Consumes: same as Task 3.

- [ ] **Step 1: Read each service's real config** — `k8s/argocd/applications/{nextcloud,nocodb,paperless,overleaf}.yaml`, `k8s/values/{nextcloud,paperless}.yaml` (per `scripts/setup-databases.sh` these have Phase 1/Phase 2 Vault seeding via `scripts/setup-paperless.sh` too — mention this two-phase secret setup in paperless's "how to change it"), `k8s/security/external-secrets/productivity/*.yaml`.

- [ ] **Step 2: Write `docs/index.md` for each**, same template.

- [ ] **Step 3: Write minimal `mkdocs.yml` for each.**

- [ ] **Step 4: Add annotation to each catalog-info.yaml.**

- [ ] **Step 5: Validate**

Run: `for f in catalog/{nextcloud,nocodb,paperless,overleaf}/catalog-info.yaml catalog/{nextcloud,nocodb,paperless,overleaf}/mkdocs.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`

- [ ] **Step 6: Commit** — only if asked.

---

### Task 8: Docs batch 6 — alloy, loki, monitoring

**Files:**
- Create: `catalog/alloy/docs/index.md`, `catalog/alloy/mkdocs.yml`
- Create: `catalog/loki/docs/index.md`, `catalog/loki/mkdocs.yml`
- Create: `catalog/monitoring/docs/index.md`, `catalog/monitoring/mkdocs.yml`
- Modify: the corresponding 3 `catalog-info.yaml` files (add annotation)

**Interfaces:**
- Consumes: same as Task 3.

- [ ] **Step 1: Read each service's real config** — `k8s/argocd/applications/{alloy,loki,monitoring}.yaml`, `k8s/values/{alloy,loki,monitoring}.yaml` if present. Note how these three relate to each other (Alloy ships logs to Loki; `monitoring` is likely the Prometheus/Grafana/Alertmanager stack per earlier `git log` evidence in this session — verify against the actual Application manifest rather than assuming).

- [ ] **Step 2: Write `docs/index.md` for each**, same template.

- [ ] **Step 3: Write minimal `mkdocs.yml` for each.**

- [ ] **Step 4: Add annotation to each catalog-info.yaml.**

- [ ] **Step 5: Validate**

Run: `for f in catalog/{alloy,loki,monitoring}/catalog-info.yaml catalog/{alloy,loki,monitoring}/mkdocs.yml; do python3 -c "import yaml,sys; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`

- [ ] **Step 6: Commit** — only if asked.

---

### Task 9: End-to-end verification

**Files:** none created/modified — verification only.

**Interfaces:**
- Consumes: everything from Tasks 1-8.
- Produces: confirmation the whole system works before considering this done.

- [ ] **Step 1: Confirm all 23 services have docs**

Run: `for d in $(yq -r '.spec.targets[]' catalog/all.yaml | grep -v org/homelab.yaml | sed 's#/catalog-info.yaml##'); do [ -f "catalog/$d/docs/index.md" ] || echo "MISSING: $d"; done`
Expected: no output (nothing missing). If `yq` isn't installed, list `catalog/*/docs/index.md` and diff the count against the 23 services named in the spec.

- [ ] **Step 2: Confirm every catalog-info.yaml has the techdocs-ref annotation**

Run: `grep -L "backstage.io/techdocs-ref" catalog/*/catalog-info.yaml`
Expected: no output.

- [ ] **Step 3: Manual verification after next deploy (deferred — this session isn't pushing yet)**

Once Tasks 1-8 are eventually pushed and the backstage image rebuilt with Task 2's Dockerfile change: open `https://backstage.homelab.local`, navigate to any service's entity page, confirm a "Docs" tab appears and renders the four sections. Then use Backstage's search bar for a phrase known to appear in exactly one service's doc (e.g. a Vault path mentioned only in that service's "How it's configured" section) and confirm it's found — this validates the TechDocs search collator is actually indexing the new content, not just that pages render.

- [ ] **Step 4: Commit** — only if asked, and only once the user has reviewed a sample of the generated docs (per this session's "spot-check a sample" agreement in the spec).
