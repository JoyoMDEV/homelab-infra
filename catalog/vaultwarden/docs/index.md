## What it is

Vaultwarden is a lightweight, Rust-based server implementation of the Bitwarden password manager API. It provides a self-hosted, Bitwarden-client-compatible password vault, deployed via the community `vaultwarden` Helm chart.

## Why it's here

It gives the cluster owner (and any invited users, since `signupsAllowed: false` keeps registration closed) a self-hosted password manager instead of relying on a third-party cloud vault, reachable at `vault.homelab.local` and usable with any standard Bitwarden client app. Persisted data lives on a `1Gi` PVC so vault contents survive pod restarts, and outbound SMTP is wired up so Vaultwarden can send invite/reset emails via the same mail provider (`mail.your-server.de`) used elsewhere in this homelab.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/vaultwarden.yaml` — chart `vaultwarden` from `https://guerzon.github.io/vaultwarden`, `targetRevision: 0.35.1`, deployed to namespace `security`.
- Values are inlined in the Application (`spec.source.helm.values`), not a separate `k8s/values/vaultwarden.yaml` file. Key settings: `domain: https://vault.homelab.local`, `signupsAllowed: false`, a `1Gi` `ReadWriteOnce` PVC at `/data`, resource requests `64Mi`/`50m` with a `256Mi` memory limit, and `timezone: Europe/Berlin`.
- Ingress: hostname `vault.homelab.local`, `class: traefik`, TLS via the `homelab-wildcard-tls` secret (`tlsSecret`).
- ExternalSecrets (namespace `security`, both via the `vault` `ClusterSecretStore`):
  - `k8s/security/external-secrets/security/vaultwarden-secret.yaml` → Vault path `homelab/security/vaultwarden-secret` (key `admin-token`), synced into Kubernetes Secret `vaultwarden-secret` and referenced by the chart via `adminToken.existingSecret`.
  - `k8s/security/external-secrets/security/vaultwarden-smtp.yaml` → Vault path `homelab/security/vaultwarden-smtp` (keys `SMTP_USERNAME`, `SMTP_PASSWORD`), synced into Kubernetes Secret `vaultwarden` (note: the chart's own expected secret name, not `vaultwarden-smtp`) and referenced via `smtp.existingSecret: vaultwarden` with `existingSecretKey` set per field.

## How to change it

- To change the chart version, bump `targetRevision` in `k8s/argocd/applications/vaultwarden.yaml` and let ArgoCD sync.
- To change domain, storage size, resource limits, or SMTP host settings, edit the inlined `spec.source.helm.values` block in that same file.
- To seed or rotate the admin token and SMTP credentials in Vault, run `scripts/setup-vaultwarden.sh`. It is idempotent: it will not overwrite an existing admin token in Vault, but it always updates SMTP credentials on each run, and it force-syncs the `vaultwarden-secret` and `vaultwarden-smtp` ExternalSecrets afterward. The script also ensures the `security` namespace exists with the `homelab.local/inject-ca=true` and `managed-by=argocd` labels.
- The admin panel is at `https://vault.homelab.local/admin`, authenticated with the Vault-issued admin token.
