## What it is

External Secrets Operator (ESO) is the Kubernetes controller that syncs secret material from HashiCorp Vault into native Kubernetes `Secret` objects, by reconciling `ExternalSecret` custom resources against a `ClusterSecretStore`. It is the mechanism this repo's whole secrets pipeline runs on, not a consumer of any particular service's secrets.

## Why it's here

This repo's convention (see root `CLAUDE.md`) is that no real secret value is ever committed to the repo — every service instead gets an `ExternalSecret` pointing at a Vault path, and ESO is what actually performs that sync. Every other service documented in this catalog (Keycloak, Vaultwarden, GitLab, Nextcloud, Paperless, Grafana, Velero, etc.) depends on this controller running correctly; if it's down, no ExternalSecret can refresh and Vault secret rotations stop reaching the cluster.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/external-secrets.yaml` — chart `external-secrets` from `https://charts.external-secrets.io`, `targetRevision: 2.3.0`, deployed to namespace `external-secrets`, synced with `ServerSideApply=true` (needed because the chart manages its own CRDs).
- Values are inlined in the Application (`spec.source.helm.values`), not a separate `k8s/values/external-secrets.yaml` file. Key settings: `crds.create: true`, `replicaCount: 1` for the main controller, webhook, and cert-controller components, and a `serviceMonitor` enabled with `release: monitoring` label so Prometheus (via the kube-prometheus-stack `ServiceMonitor` selector) picks up its metrics.
- The `ClusterSecretStore` it reconciles against, `vault`, is defined separately in `k8s/security/vault-cluster-secret-store.yaml` (part of the `security-manifests` app, not this one): it points at `http://vault.security.svc.cluster.local:8200`, KV engine `secret` v2, and authenticates via Vault's Kubernetes auth method using the `external-secrets` ServiceAccount in the `external-secrets` namespace.
- On the Vault side, `scripts/setup-hcvault.sh` creates the corresponding Kubernetes auth role: `vault write auth/kubernetes/role/external-secrets bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets policies=reader ttl=1h`. This is deliberately scoped to only the `reader` policy — no Vault Agent Injector or direct `vault write auth/kubernetes/login` calls exist elsewhere in this repo.
- Every `ExternalSecret` under `k8s/security/external-secrets/**/*.yaml` (grouped by category: `auth`, `security`, `productivity`, `infrastructure`, `monitoring`, `gitlab`, `cert-manager`, `automation`, `backup`, `backstage`) is what this controller reconciles; those manifests are shipped by the separate `security-manifests` ArgoCD app, which recursively syncs `k8s/security/`.

## How to change it

- To change the ESO version, bump `targetRevision` in `k8s/argocd/applications/external-secrets.yaml` and let ArgoCD sync — watch for CRD changes since `crds.create: true` and `ServerSideApply=true` are both set.
- To change replica counts or resource limits for the controller, webhook, or cert-controller, edit the inlined `spec.source.helm.values` block in that same file.
- To debug a stuck secret, check the `ExternalSecret` status: `kubectl get externalsecret -A` and `kubectl describe externalsecret <name> -n <namespace>`. A `force-sync=<timestamp>` annotation (as used by `scripts/setup-vaultwarden.sh` and `scripts/setup-databases.sh`) triggers an immediate re-sync instead of waiting for `refreshInterval` (typically `1h` across this repo's ExternalSecrets).
- To change how ESO authenticates to Vault (auth method, policy, TTL), edit the `vault_exec write auth/kubernetes/role/external-secrets ...` block in `scripts/setup-hcvault.sh` and re-run it, and/or edit `k8s/security/vault-cluster-secret-store.yaml`.
