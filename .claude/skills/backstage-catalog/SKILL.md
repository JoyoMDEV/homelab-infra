---
name: backstage-catalog
description: Audit and sync the Backstage software catalog (catalog/) against the actually-deployed ArgoCD applications (k8s/argocd/applications/). Use when asked to check, fix, or update the Backstage catalog, or when the catalog seems out of date.
---

# backstage-catalog

Keeps `catalog/` in sync with what's actually deployed. Backstage catalog entries are hand-written and easy to forget when adding or removing a service — this skill finds and fixes the drift.

## Audit

1. List deployed services: every file in `k8s/argocd/applications/*.yaml` (the ArgoCD app name = `metadata.name`, the k8s namespace = `spec.destination.namespace`).
2. List catalog entries: every `catalog/*/catalog-info.yaml`, plus what's actually registered (targeted) in `catalog/all.yaml`'s `spec.targets`.
3. Cross-check and report:
   - **Missing catalog entry**: an ArgoCD app with no `catalog/<name>/catalog-info.yaml`.
   - **Orphaned catalog entry**: a `catalog/<name>/catalog-info.yaml` whose `argocd/app-name` annotation doesn't match any current ArgoCD app (service was removed but catalog entry wasn't cleaned up).
   - **Unregistered entry**: a `catalog-info.yaml` exists on disk but isn't listed in `catalog/all.yaml`'s `spec.targets` (Backstage will never see it).
   - **Stale annotations**: `argocd/app-name` or `backstage.io/kubernetes-id` that don't match the app name / namespace.
   - **Malformed YAML**: parse every catalog file (`yq`/`python -c "import yaml,sys; yaml.safe_load_all(open(sys.argv[1]))"` or similar) — this catalog has had broken entries before (e.g. an empty `apiVersion:` field), and Backstage silently drops entries it can't parse rather than erroring loudly.

## Fix

For each finding, unless the user said report-only:

- **Missing catalog entry**: create `catalog/<service>/catalog-info.yaml` using the same shape as an existing entry (see `catalog/nextcloud/catalog-info.yaml` for the template — `apiVersion: backstage.io/v1alpha1`, `kind: Component`, `argocd/app-name` + `backstage.io/kubernetes-id` annotations, `owner: group:homelab/<owner>`, `system: homelab`). Pull the hostname from the ArgoCD app's ingress `host:` value if present. Ask the user for a description/owner if it can't be inferred.
- **Unregistered entry**: add `- ./<service>/catalog-info.yaml` to `catalog/all.yaml`'s `spec.targets`.
- **Orphaned entry**: ask the user before deleting — the service may be intentionally paused rather than removed.
- **Stale annotations / malformed YAML**: fix directly and show the diff.

## Notes

- This skill only touches files under `catalog/`. It never modifies `k8s/argocd/applications/` — that's the source of truth for what's deployed.
- Always report what was found before making changes; don't silently "fix" things the user didn't ask about.
- After changes, remind the user Backstage needs its catalog location refreshed (or wait for its periodic re-scan) to pick up edits — this skill doesn't restart or query the live Backstage instance.
