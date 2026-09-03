## What it is

The official Hetzner-maintained cert-manager webhook (`github.com/hetzner/cert-manager-webhook-hetzner`) that implements ACME DNS-01 challenge solving against the Hetzner Cloud DNS API, deployed via its official Helm chart.

## Why it's here

Public TLS certificates for `johannesmoseler.de` (used by the publicly-exposed services behind `traefik-public`, e.g. `login.svc.johannesmoseler.de`, `overleaf.svc.johannesmoseler.de`) are issued by Let's Encrypt via DNS-01, which requires a webhook that can create the `_acme-challenge` TXT record at Hetzner. The old DNS-01 solvers (`dns.hetzner.com` API, including third-party forks like `vadimkim`) stopped working when Hetzner shut down that legacy DNS API on 2026-05-27 — this webhook targets the new Hetzner Cloud API instead and is the one Hetzner itself maintains going forward.

## How it's configured

- ArgoCD Application: `k8s/argocd/applications/cert-manager-webhook-hetzner.yaml`
- Chart: `cert-manager-webhook-hetzner` from `https://charts.hetzner.cloud`, `targetRevision: "0.8.0"`
- Values inlined in the Application: `groupName: acme.johannesmoseler.de`
- Destination namespace: `cert-manager` (same namespace as cert-manager itself, per the chart's own documentation requirement; cert-manager is installed by `scripts/bootstrap-certmanager.sh`)
- ExternalSecret: `k8s/security/external-secrets/cert-manager/hetzner-dns-token.yaml` (`hetzner-dns-token`, namespace `cert-manager`), pulling `token` from Vault path `homelab/public/hetzner-dns-token`. The token must be a Hetzner **Cloud project** API token (read+write) from the project the DNS zone belongs to — not the old DNS-zone token from the retired DNS console.
- Extra RBAC in `k8s/security/cert-manager-webhook-hetzner-rbac.yaml`: a Role/RoleBinding granting the webhook's ServiceAccount `get` on the `hetzner-dns-token` Secret specifically — the chart doesn't ship this itself since the Secret is created by the ExternalSecret, not a chart template, and challenges fail with a "cannot get resource secrets ... forbidden" error without it.
- Consumed by two `ClusterIssuer`s in `k8s/security/letsencrypt-issuer.yaml` (`letsencrypt-staging` and `letsencrypt-prod`), both configured with `solvers[].dns01.webhook.groupName: acme.johannesmoseler.de` and `solverName: hetzner`, referencing the same `hetzner-dns-token` secret.

## How to change it

- **Upgrade the webhook**: bump `targetRevision` in `k8s/argocd/applications/cert-manager-webhook-hetzner.yaml` to a newer chart version from `https://charts.hetzner.cloud`.
- **Rotate the API token**: `vault kv put secret/homelab/public/hetzner-dns-token token=<new-cloud-token>` — the ExternalSecret refreshes hourly (`refreshInterval: 1h`), or force it sooner with `kubectl -n cert-manager annotate externalsecret hetzner-dns-token force-sync=$(date +%s) --overwrite`.
- **Debug a failing DNS-01 challenge**: check `kubectl -n cert-manager logs deploy/cert-manager-webhook-hetzner`, verify the RBAC in `k8s/security/cert-manager-webhook-hetzner-rbac.yaml` still grants access to the secret, and confirm which `ClusterIssuer` (staging vs. prod, see `k8s/security/letsencrypt-issuer.yaml`) the failing `Certificate`/`CertificateRequest` is using — staging should always be validated first given Let's Encrypt's production rate limits.
