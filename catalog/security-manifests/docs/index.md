## What it is

`security-manifests` is not a Helm chart deployment — it's an ArgoCD Application that recursively syncs the raw Kubernetes manifests under `k8s/security/` directly (`source.path: k8s/security`, `directory.recurse: true`). It covers cluster-security-adjacent resources: the Vault `ClusterSecretStore`, cert-manager `ClusterIssuer`s and a `Certificate`, an RBAC `Role`/`RoleBinding` for the cert-manager Hetzner DNS webhook, Cilium `CiliumNetworkPolicy` network isolation rules, and every per-service `ExternalSecret` under `k8s/security/external-secrets/**/`.

## Why it's here

Before this app existed, these manifests had to be applied by hand (`kubectl apply -f k8s/security/...`) as part of `scripts/setup-hcvault.sh` and the Vault setup runbook — a comment at the top of `k8s/argocd/applications/security-manifest.yaml` explicitly flags that those manual steps need to be removed now that this app is active, since ArgoCD's self-heal would otherwise fight anyone editing these resources by hand. Bundling them into one app-of-manifests keeps the Vault trust root (`ClusterSecretStore`), the TLS issuance chain (`ClusterIssuer`s + `Certificate`), and every service's `ExternalSecret` under GitOps control instead of being a set of ad hoc, undocumented `kubectl apply` commands.

## How it's configured

- ArgoCD Application file: `k8s/argocd/applications/security-manifest.yaml` (note: filename is singular `security-manifest.yaml`, not `security-manifests.yaml`) — `repoURL` is this repo itself (`https://github.com/JoyoMDEV/homelab-infra.git`), `targetRevision: main`, `source.path: k8s/security` with `directory.recurse: true`. Fallback `destination.namespace` is `security`, used only for the handful of cluster-scoped resources here (the `ClusterSecretStore` and the `CiliumClusterwideNetworkPolicy`); every other manifest sets its own `metadata.namespace`.
- What actually lives under `k8s/security/` and gets synced:
  - `k8s/security/vault-cluster-secret-store.yaml` — the `vault` `ClusterSecretStore` that every `ExternalSecret` in the cluster references; connects to `http://vault.security.svc.cluster.local:8200` via Vault's Kubernetes auth method.
  - `k8s/security/letsencrypt-issuer.yaml` — `letsencrypt-staging` and `letsencrypt-prod` cert-manager `ClusterIssuer`s, both using the `hetzner` DNS-01 solver webhook and the `hetzner-dns-token` secret.
  - `k8s/security/public-wildcard-cert.yaml` — the `svc-wildcard` `Certificate` for `*.svc.johannesmoseler.de`, issued via `letsencrypt-prod`, shared by public-facing services (Overleaf, Minecraft) in namespace `public`.
  - `k8s/security/cert-manager-webhook-hetzner-rbac.yaml` — a `Role`/`RoleBinding` in namespace `cert-manager` granting the `cert-manager-webhook-hetzner` ServiceAccount `get` on the `hetzner-dns-token` Secret specifically (the chart doesn't ship this RBAC itself).
  - `k8s/security/network-policies/public-tier.yaml` and `k8s/security/network-policies/minecraft-tier-network-policies.yaml` — Cilium `CiliumNetworkPolicy` resources implementing default-deny + explicit allow rules for the `public`, `overleaf`, and `minecraft` namespaces.
  - `k8s/security/external-secrets/**/*.yaml` — every `ExternalSecret` in the cluster, grouped by category directory (`auth`, `security`, `productivity`, `infrastructure`, `monitoring`, `gitlab`, `cert-manager`, `automation`, `backup`, `backstage`), each pointing at a `homelab/<namespace>/<name>` path in Vault via the `vault` `ClusterSecretStore` defined above.

## How to change it

- Because this app syncs a raw manifest directory rather than a Helm chart, any file added, edited, or removed under `k8s/security/` (with `directory.recurse: true`) is picked up on the next ArgoCD sync — there is no version to bump.
- To add a new service's secret, create `k8s/security/external-secrets/<category>/<service>-secret.yaml` following the existing pattern (`ExternalSecret` → `vault` `ClusterSecretStore` → Vault path `homelab/<namespace>/<service>-secret`), and seed the real value into Vault with a `scripts/setup-<service>.sh` script — never inline it here.
- To add or adjust network isolation, edit or add a `CiliumNetworkPolicy` file under `k8s/security/network-policies/`; note the additive model documented in the comments there — once any policy selects a pod for a direction, only explicitly allowed traffic passes, so a new default-deny needs matching allow rules.
- To rotate the Vault connection details or auth role for ESO, edit `k8s/security/vault-cluster-secret-store.yaml`; the corresponding Vault-side Kubernetes auth role is created separately by `scripts/setup-hcvault.sh`.
- To change TLS issuance (e.g. switch a cert from staging to prod, or add a new `ClusterIssuer`), edit `k8s/security/letsencrypt-issuer.yaml`; per the comment there, always validate against `letsencrypt-staging` first since `letsencrypt-prod` has strict Let's Encrypt rate limits.
