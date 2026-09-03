## What it is

HashiCorp Vault (official `hashicorp/vault` Helm chart), running standalone (no HA, no auto-unseal)
with file storage, TLS terminated at Traefik, and its own OIDC login against Keycloak plus a
Kubernetes auth method for the External Secrets Operator.

## Why it's here

It's the single source of truth for every secret in this cluster — the "Secrets always flow
through Vault" rule in this repo's conventions exists because of this instance. Every deployed
service that needs a credential gets an `ExternalSecret` under
`k8s/security/external-secrets/<category>/` pointing at a Vault KV-v2 path under
`homelab/<namespace>/...`, resolved through the `vault` `ClusterSecretStore`
(`k8s/security/vault-cluster-secret-store.yaml`). This replaces secrets ever being committed to
Git or created ad hoc with `kubectl create secret`. It's also the login backend for human admin
access to Vault itself, via OIDC against Keycloak.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/vault.yaml` — Helm chart `vault` from
  `https://helm.releases.hashicorp.com`, `targetRevision: "0.32.0"`, image `hashicorp/vault:1.21.2`,
  no separate values file (values inlined in `spec.source.helm.values`). Destination namespace
  `security`.
- Key inline values: `injector.enabled: false` (no Vault Agent Injector — this repo uses External
  Secrets Operator instead), `server.standalone.enabled: true` with `storage "file"` at
  `/vault/data` (5Gi PVC, `ReadWriteOnce`), `global.tlsDisable: true` (Traefik terminates TLS,
  Vault itself speaks plain HTTP internally), a readiness probe tuned to treat "sealed" as healthy
  (`sealedcode=204`) so the pod isn't killed while sealed, and an extra volume mounting the
  `homelab-ca` secret into the container plus `SSL_CERT_DIR` so Vault's outbound OIDC calls to
  Keycloak trust the internal CA.
- Ingress: `hcvault.homelab.local`, `ingressClassName: traefik`, TLS via `homelab-wildcard-tls`.
- ClusterSecretStore consumer: `k8s/security/vault-cluster-secret-store.yaml` points the External
  Secrets Operator at `http://vault.security.svc.cluster.local:8200`, KV path `secret`
  (`version: v2`), authenticating via the Kubernetes auth method through the `external-secrets`
  ServiceAccount/role.
- Vault itself has no `ExternalSecret` of its own (it's the secret backend, not a consumer) — its
  root token and unseal keys instead live in the Ansible Vault (`make vault-edit` /
  `make vault-view`, per `README.md`), not in Kubernetes at all.
- Namespace: `security`.

## How to change it

- To bump the chart or Vault image version, edit `targetRevision` / `server.image.tag` in
  `k8s/argocd/applications/vault.yaml`.
- Initial bootstrap (init/unseal, audit log, KV engine, policies, Kubernetes auth method, OIDC
  auth against Keycloak) is done via `scripts/setup-hcvault.sh`. It's idempotent — rerun it with
  `--skip-init` to reconfigure auth methods/policies without touching an already-initialized
  Vault (it will prompt for the existing root token and unseal keys).
- Policies are namespace-scoped (`ns-<namespace>` policies restricting reads to
  `secret/data/homelab/<namespace>/*`) plus a broad `admin` policy and a `reader` policy (used by
  the `external-secrets` Kubernetes auth role). To add a new namespace's policy, add it to the
  `for NS in ...` loop near the top of `scripts/setup-hcvault.sh` and rerun the script.
- To add a brand-new secret for a service, follow this repo's standard pattern: write a
  `scripts/setup-<service>.sh` script that does `vault kv put secret/homelab/<namespace>/<name> ...`
  (see `scripts/setup-minio.sh` for the pattern), then add a matching `ExternalSecret` under
  `k8s/security/external-secrets/<category>/`.
- `scripts/migrate-secrets-to-vault.sh` is a one-time bridge script (already run) that seeded
  Vault from secrets that existed in the cluster before Vault/ESO did — useful as a reference for
  the full list of Vault paths currently in use, but not something to run again in normal
  operation.
- Losing/rotating unseal keys or the root token requires re-running the `operator init`/`unseal`
  flow — see `docs/vault-setup.md` for the full runbook.
