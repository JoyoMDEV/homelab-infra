## What it is

A single-node [Garage](https://garagehq.deuxfleurs.fr) instance — an S3-compatible object store built by Deuxfleurs, AGPLv3 — deployed as shared infrastructure alongside MinIO.

## Why it's here

Supabase Storage needed a genuinely open-source S3 backend (MinIO's OSS console was gutted in 2025) — Garage was picked specifically for small self-hosted deployments over the alternative (SeaweedFS), which has more moving parts than this cluster's scale needs. Deployed as *shared* infra (like MinIO) rather than Supabase-only, so future services can reuse it with their own bucket/key rather than standing up another instance.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/garage.yaml` — Garage's own chart, sourced directly from `git.deuxfleurs.fr/Deuxfleurs/garage.git` (`script/helm/garage`), pinned `v2.4.1`, namespace `infrastructure`. Single-node mode (`garage.singleNode: true`) — the storage layout is auto-assigned on first boot (no manual `garage layout assign`/`apply` needed, a feature since Garage v2.3).
- No secrets management of its own at the instance level — per-consumer buckets and scoped access keys are created via the `garage` CLI (`kubectl exec -n infrastructure garage-0 -- /garage ...` — note the absolute path; this image has no shell and nothing on `$PATH`) and written to Vault by whichever service's setup script needs them (e.g. `scripts/setup-supabase-storage.sh` for the `supabase-storage` bucket).

## How to change it

- **Add a bucket/key for a new consumer**: see `catalog/supabase`'s "How to change it" for the exact `garage` CLI commands.
- **Resize storage**: edit `k8s/argocd/applications/garage.yaml`'s `persistence.data.size` and let ArgoCD reconcile (grows the existing PVC if the storage class supports online expansion; otherwise a manual PVC resize/replace is needed).
