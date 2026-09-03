# Backstage narrative docs (TechDocs, local generation)

## Problem

Most of this cluster was set up with AI assistance across many sessions. The
operator (Johannes) doesn't have a single place where "what is this service,
why does it exist, how is it configured, and how would I change it" is
written down for each of the 23 catalog services. Backstage is the natural
home for this — it already has a `Search` plugin wired to a TechDocs
collator, and `TechDocs` is registered in the backend but unused.

This is the third of three Backstage improvements this session, after wiring
live Kubernetes status (#1) and ArgoCD sync status (#2). Those make "is it
healthy" answerable inside Backstage; this makes "what is it and why" answerable
the same way.

## Goals

- Every service in `catalog/` gets a docs page, rendered inside Backstage,
  searchable via the existing Search plugin.
- A fixed template across all services: predictable, scannable, easy to keep
  in sync as services change.
- No new infrastructure beyond what's already deployed (no CI pipeline, no
  new object storage bucket, no new credentials).
- The convention survives across Claude Code sessions (`CLAUDE.md`).

## Non-goals

- Build-time doc pre-rendering / publishing to external storage (MinIO). That
  is Backstage's own "recommended for production" pattern, but it solves a
  scaling problem (avoiding runtime generation cost under load) this
  single-user homelab doesn't have. Rejected as over-engineering for now —
  revisit if Backstage ever sees real concurrent traffic.
- Plain markdown + links instead of TechDocs. Rejected because it doesn't
  give a unified, searchable, in-Backstage "space" — the actual goal.

## Design

### Doc template (fixed, one file per service)

`catalog/<service>/docs/index.md`, four sections, in this order:

1. **What it is** — one paragraph, what the service does.
2. **Why it's here** — the problem it solves in *this* cluster specifically,
   not generic marketing copy.
3. **How it's configured** — grounded in the real files: which ArgoCD
   `Application` (`k8s/argocd/applications/<service>.yaml`), which Helm
   chart + `targetRevision`, which `values:`/`k8s/values/<service>.yaml`,
   which `ExternalSecret`(s) and Vault path(s), namespace, ingress host if
   any.
4. **How to change it** — concrete, actionable next steps specific to that
   service (e.g. "to add a DB here, edit `scripts/setup-databases.sh`"; "to
   rotate this token, run `scripts/setup-X.sh`"; "to bump the version, edit
   `targetRevision` in `k8s/argocd/applications/X.yaml` and let ArgoCD sync").

### File layout

```
catalog/<service>/
  catalog-info.yaml       # already exists
  docs/
    index.md              # new
  mkdocs.yml               # new, minimal, one per documented entity (TechDocs requirement)
```

`catalog-info.yaml` gets one new annotation:

```yaml
annotations:
  backstage.io/techdocs-ref: dir:.
```

### Rendering pipeline (Approach B: local generation, no new infra)

TechDocs is already registered (`packages/backend/src/index.ts`) and
`app-config.yaml` already has:

```yaml
techdocs:
  builder: 'local'
  generator:
    runIn: 'docker'   # <- the problem: no Docker socket in the pod
  publisher:
    type: 'local'
```

Change: `generator.runIn: 'docker'` → `'local'`. This runs `mkdocs` as a
subprocess inside the existing Backstage container instead of spinning up a
separate Docker container. Requires adding the `mkdocs-techdocs-core` pip
package (the official Backstage-maintained metapackage — bundles `mkdocs` +
`mkdocs-material` pinned to versions known to work with TechDocs) plus
Python/pip themselves to the runtime stage of the backstage repo's
`Dockerfile`.

Docs render on first request per pod lifetime and are cached to local disk
(`publisher.type: 'local'`) after that — regenerated after each pod restart,
which is a non-issue at this traffic level (single user, infrequent
restarts).

### CLAUDE.md convention (new rule)

Every service under `catalog/<service>/` must have a `docs/index.md`
following the four-section template above, plus a minimal `mkdocs.yml`, plus
the `backstage.io/techdocs-ref: dir:.` annotation on its `catalog-info.yaml`.
Kept in sync whenever a service's ArgoCD Application, values, or secrets
change — same spirit as the existing "Backstage catalog should stay in sync"
rule for `catalog-info.yaml` itself.

### Authoring the initial 23

Grounded in real source per service (its `k8s/argocd/applications/<x>.yaml`,
Helm values, `ExternalSecret`(s), local chart if any — not generic
descriptions). Drafted via a few parallel forked subagents (to avoid
blowing out this session's context on 23 services' worth of file reads),
then spot-checked by the primary session before calling it done.

Services (from `catalog/all.yaml`, 23 total): alloy, backstage,
cert-manager-webhook-hetzner, external-secrets, gitlab, gitlab-runner,
infrastructure, keycloak, loki, minio, monitoring, nextcloud, nocodb,
overleaf, paperless, public, redis, renovate, security-manifests,
traefik-public, vault, vaultwarden, velero.

## Testing

- `mkdocs build` succeeds locally (or in-container) for a sample service
  without errors, before rolling out to all 23.
- After deploying the Dockerfile/config change: open a service's entity page
  in Backstage, confirm the Docs tab renders the four sections correctly.
- Confirm Search returns results from at least one docs page (validates the
  existing techdocs search collator is actually indexing the new content).

## Rollout order

1. Write this spec (done) and get it reviewed.
2. Update `CLAUDE.md` with the new convention.
3. Backstage repo: `Dockerfile` (mkdocs deps) + `app-config.yaml`
   (`generator.runIn: local`).
4. homelab-infra repo: `docs/index.md` + `mkdocs.yml` + annotation for all
   23 services.
5. Verify end-to-end on a redeploy (still pending push per this session's
   "don't push yet" constraint from #1/#2).
