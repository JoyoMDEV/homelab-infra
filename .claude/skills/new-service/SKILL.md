---
name: new-service
description: Scaffold a new self-hosted service (ArgoCD Application + Vault-backed ExternalSecret + Backstage catalog entry) following this repo's conventions. Use when onboarding a new app to the homelab cluster.
---

# new-service

Scaffolds the boilerplate for a new service deployed via ArgoCD in this repo, following the conventions in `CLAUDE.md`. Every service in this cluster needs the same three pieces; this skill creates all of them consistently instead of copy-pasting from an existing app by hand.

## Inputs to collect

Ask the user (or infer from context) for:

1. **Service name** (lowercase, hyphenated, e.g. `paperless`) — used as the k8s resource name, ArgoCD app name, and directory name.
2. **Category / namespace** — the k8s namespace it deploys into. Check existing categories first: `ls k8s/security/external-secrets/` and `ls k8s/argocd/applications/` for precedent (`productivity`, `infrastructure`, `monitoring`, `auth`, `dashboard`, `gitlab`, `security`, `cert-manager`, `backstage`). Reuse an existing category/namespace when the service fits; only introduce a new one if none fit.
3. **Source**: a Helm chart (repo URL + chart name + version) or a local chart path (`k8s/charts/<name>`)?
4. **Hostname**: usually `<service>.homelab.local`.
5. **Secret keys needed**: what does the ExternalSecret need to pull from Vault (DB creds, OIDC client secret, admin password, etc.)?
6. **Description/owner** for the Backstage catalog entry.

## Steps

1. **ArgoCD Application** — create `k8s/argocd/applications/<service>.yaml`. Use an existing app in the same category as a style reference (e.g. `k8s/argocd/applications/nextcloud.yaml` for Helm-chart-from-repo, or another app for a local chart). Required shape:
   ```yaml
   apiVersion: argoproj.io/v1alpha1
   kind: Application
   metadata:
     name: <service>
     namespace: argocd
     finalizers:
       - resources-finalizer.argocd.argoproj.io
   spec:
     project: default
     source:
       repoURL: <chart repo or this git repo for local charts>
       chart: <chart name>       # omit + use `path:` for local charts
       targetRevision: "<pinned version — never a placeholder>"
       helm:
         values: |
           # ...
     destination:
       server: https://kubernetes.default.svc
       namespace: <category/namespace>
     syncPolicy:
       automated:
         prune: true
         selfHeal: true
       syncOptions:
         - CreateNamespace=true
   ```
   Reference secret values via `existingSecret`/`secretKeyRef` pointing at `<service>-secret` — never inline real values in `values:`.

2. **ExternalSecret** — create `k8s/security/external-secrets/<category>/<service>-secret.yaml`:
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: <service>-secret
     namespace: <category/namespace>
   spec:
     refreshInterval: 1h
     secretStoreRef:
       name: vault
       kind: ClusterSecretStore
     target:
       name: <service>-secret
       creationPolicy: Owner
     data:
       - secretKey: <key>
         remoteRef:
           key: homelab/<category/namespace>/<service>-secret
           property: <key>
       # one entry per secret key
   ```
   List every secret key the ArgoCD app's `values:` references via `secretKeyRef`.

3. **Bootstrap script (optional, only if secrets need seeding)** — if the service needs generated or externally-sourced secret values, create `scripts/setup-<service>.sh` following the style of an existing `scripts/setup-*.sh` script: write the actual secret values into Vault at `homelab/<category/namespace>/<service>-secret` using the Vault CLI. Never hardcode real secret values anywhere else in the repo.

4. **Backstage catalog entry** — create `catalog/<service>/catalog-info.yaml`:
   ```yaml
   apiVersion: backstage.io/v1alpha1
   kind: Component
   metadata:
     name: <service>
     description: <short description>
     annotations:
       argocd/app-name: <service>
       backstage.io/kubernetes-id: <service>
     links:
       - url: https://<service>.homelab.local
         title: <Service Display Name>
   spec:
     type: service
     lifecycle: production
     owner: group:homelab/<owner>
     system: homelab
   ```
   Register it by adding `- ./<service>/catalog-info.yaml` to the `spec.targets` list in `catalog/all.yaml`.

5. **Summarize** what was created and any manual follow-up needed (e.g. running the setup script to seed Vault, or `kubectl port-forward`/checking the ArgoCD UI once it syncs).

## Notes

- Never write real secret values into any file created by this skill — `ExternalSecret` only references Vault paths.
- If you're unsure which category/namespace fits, prefer reusing an existing one — see the "Backstage catalog" and "One ArgoCD Application per service" conventions in `CLAUDE.md`.
- Don't run `terraform apply`, `kubectl apply`, or push commits as part of this skill — it only scaffolds files for the user to review.
