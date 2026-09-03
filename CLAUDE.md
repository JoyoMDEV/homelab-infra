# homelab-infra

Hybrid k3s cluster (2 Hetzner Cloud servers + 2 home nodes) managed with Terraform, Ansible, and ArgoCD. See `README.md` for the architecture diagram and CI/CD flow.

## Repo layout

- `terraform/` — Hetzner Cloud provisioning (servers, network, firewall). State is local and gitignored.
- `ansible/` — server configuration (`roles/`: `common`, `hardening`, `k3s_server`, `k3s_agent`, `samba`, `tailscale`, `backup`).
- `k8s/argocd/applications/` — one ArgoCD `Application` per deployed service. `k8s/argocd/root.yaml` is the app-of-apps that watches this directory.
- `k8s/security/external-secrets/<category>/` — one `ExternalSecret` per service, grouped by category (`auth`, `productivity`, `infrastructure`, `monitoring`, `dashboard`, `gitlab`, `cert-manager`, `security`, `backstage`).
- `k8s/charts/` — local Helm charts for services not available upstream.
- `k8s/values/` — standalone Helm values files referenced by ArgoCD apps.
- `catalog/` — Backstage software catalog (`catalog/org/` for org/group/user entities, `catalog/<service>/catalog-info.yaml` per service, all registered via `catalog/all.yaml`).
- `scripts/` — one-off `setup-<service>.sh` bootstrap scripts (Vault secret seeding, storage provisioning, etc.) run manually, not by CI.

## Conventions

**Secrets always flow through Vault.** Never put a real secret value in a `Secret`, `ConfigMap`, or Helm `values:` block. Every service instead gets an `ExternalSecret` under `k8s/security/external-secrets/<category>/<service>-secret.yaml`, pointing at a Vault path `homelab/<k8s-namespace>/<service>-secret` via the `vault` `ClusterSecretStore`. Seed the actual values into Vault with a `scripts/setup-<service>.sh` script — never inline them in the repo.

**One ArgoCD Application per service**, in `k8s/argocd/applications/<service>.yaml`: `spec.project: default`, `syncPolicy.automated: {prune: true, selfHeal: true}`, `syncOptions: [CreateNamespace=true]`. `spec.destination.namespace` is the service's k8s namespace (matches its `external-secrets` category in most cases). Always pin `targetRevision` to a real chart/tag version — never leave a placeholder.

**Ingress**: Traefik (`ingressClassName: traefik`), host `<service>.homelab.local`, TLS via the `homelab-wildcard-tls` secret (cert-manager internal CA). DNS for `*.homelab.local` is served by the Samba AD DC over Tailscale split DNS.

**Backstage catalog** (`catalog/`) should stay in sync with `k8s/argocd/applications/` — every deployed service should have a matching `catalog/<service>/catalog-info.yaml` registered in `catalog/all.yaml`, with `argocd/app-name` and `backstage.io/kubernetes-id` annotations matching the ArgoCD app name and k8s namespace/labels. Every service also gets `catalog/<service>/docs/index.md` (referenced via a `backstage.io/techdocs-ref: dir:.` annotation) with four fixed sections, in order: **What it is**, **Why it's here**, **How it's configured** (citing the real ArgoCD Application/Helm values/ExternalSecret/Vault path for that service), and **How to change it** (concrete steps, e.g. "to rotate this token, run `scripts/setup-X.sh`"). Keep it in sync whenever the service's config changes. Rendered via TechDocs' local generator (`mkdocs`, no external pipeline) — see `docs/superpowers/specs/2026-09-03-backstage-narrative-docs-design.md`.

**Never edit directly**: `kubeconfig`, `terraform/*.tfstate*`, `certs/**` — these are gitignored, high-blast-radius files (cluster credentials, Terraform state, internal CA cert). A project hook in `.claude/settings.json` blocks edits to these paths.

## Linting

`pre-commit` (not installed locally as of writing) runs `yamllint`, `ansible-lint`, `terraform fmt`/`validate`, `shellcheck`, and `gitleaks` on commit — see `.pre-commit-config.yaml`. A project hook auto-runs `yamllint`/`terraform fmt` on file edits when those tools are available locally.
