# Homelab Infrastructure

Hybrid Kubernetes cluster: 1 Hetzner Cloud server + 2 home nodes, managed with Terraform, Ansible & ArgoCD.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Tailscale Mesh VPN                   │
├──────────────────┬──────────────────┬───────────────────┤
│  Hetzner CX53    │  Home: Mini-PC   │  Home: Raspberry  │
│  k3s-server      │  k3s-worker-     │  Pi 4B             │
│  32 GB / 16 vCPU │  minipc          │  k3s-worker-pi     │
│  Control Plane   │  Worker          │  Worker (throttled │
│  Samba AD DC     │                  │  in summer - light │
│                  │                  │  workloads only)   │
└──────────────────┴──────────────────┴───────────────────┘

  (A second Hetzner CX43 worker is defined but commented out in
  terraform/servers.tf - not currently provisioned.)

CNI:     Cilium (migrated from Flannel, see docs/cilium-migration.md;
         kube-proxy still active, replacement not yet done)
DNS:     *.homelab.local → Samba AD DC (Tailscale Split DNS)
Ingress: Traefik (hostPort 80/443) → Services
TLS:     cert-manager internal CA → Wildcard *.homelab.local
Secrets: HashiCorp Vault → External Secrets Operator → K8s Secrets
CI/CD:   GitLab Runner (k3s) → Job Pods → Deploy
```

## CI/CD

```
git push
  └── GitLab (gitlab.homelab.local)
        └── GitLab Runner Pod (k3s, Namespace: gitlab)   ← läuft dauerhaft
              └── Job Pod (image per Pipeline definiert)  ← startet pro Job
                    └── build / test / deploy
```

Der Runner ist ein **Instance Runner** — ein Runner für alle Repos.
Job-Images werden pro Pipeline definiert (`node:20-alpine`, `golang:1.22`, etc.)

## Project Structure

```
homelab-infra/
├── .devcontainer/              # Devcontainer (Go, Python, Terraform, Helm, k9s)
├── .claude/                    # Claude Code project config - see CLAUDE.md
│
├── terraform/                  # Hetzner Cloud provisioning
│   ├── main.tf
│   ├── variables.tf
│   ├── servers.tf              #   CX53 (active) + CX43 worker (commented out)
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── ansible/                    # Server configuration
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.yml            #   server (Hetzner) + workers (home) groups
│   │   └── group_vars/all/
│   │       ├── vars.yml         #   Non-secret variables
│   │       └── vault.yml        #   Encrypted secrets (ansible-vault)
│   ├── roles/
│   │   ├── common/              #   Base packages, bootstrap-open SSH/6443, CA trust
│   │   ├── hardening/           #   Separate, manual: locks SSH/k3s-API to tailscale0
│   │   ├── tailscale/           #   Tailscale mesh VPN
│   │   ├── k3s_server/          #   k3s control plane
│   │   ├── k3s_agent/           #   k3s worker nodes
│   │   ├── samba/                #   Samba AD DC (HOMELAB.LOCAL, wildcard DNS)
│   │   └── backup/               #   Samba AD backup timer
│   ├── site.yml / cluster.yml / harden_ssh.yml / migrate-to-cilium.yml
│
├── k8s/                         # Kubernetes manifests
│   ├── namespaces.yaml
│   ├── argocd/
│   │   ├── root.yaml            #   App-of-Apps root
│   │   └── applications/        #   One Application per service - see "What Gets Deployed"
│   ├── security/                #   RBAC, network policies, Vault, ExternalSecrets
│   │   ├── vault-cluster-secret-store.yaml
│   │   ├── letsencrypt-issuer.yaml
│   │   ├── network-policies/    #   CiliumNetworkPolicy, default-deny + explicit exceptions
│   │   └── external-secrets/    #   One ExternalSecret per service, grouped by category
│   │       ├── auth/ automation/ backstage/ backup/ cert-manager/
│   │       └── gitlab/ infrastructure/ monitoring/ productivity/ security/
│   ├── infrastructure/          #   Postgres cluster, cert-sync, MinIO backup, CA hooks
│   ├── charts/                  #   Local Helm charts (gitlab-omnibus, backstage)
│   ├── values/                  #   Standalone Helm values (argocd.yaml)
│   ├── public/                  #   Authelia + public-domain IngressRoutes (overleaf, minecraft)
│   ├── overleaf/                #   Raw manifests (mongo replica set, etc.)
│   └── minecraft/               #   Raw manifests
│
├── catalog/                     # Backstage software catalog
│   ├── all.yaml                 #   Location - registers every catalog-info.yaml below
│   ├── org/homelab.yaml         #   System/Group/User entities
│   └── <service>/catalog-info.yaml   # One per deployed service
│
├── scripts/                     # One-off setup scripts, run manually (not by CI)
│   ├── bootstrap-argocd.sh          #   One-time: CNPG, Redis, ArgoCD (pre-Vault bootstrap)
│   ├── bootstrap-certmanager.sh     #   One-time: cert-manager, internal CA (pre-Vault bootstrap)
│   ├── setup-hcvault.sh             #   One-time: Vault init/unseal, policies, K8s auth
│   ├── migrate-secrets-to-vault.sh  #   One-time: seed Vault from already-live secrets
│   ├── setup-databases.sh           #   Postgres DBs/roles + Vault secrets (Keycloak, GitLab, Nextcloud, Paperless phase 1)
│   ├── setup-<service>.sh           #   Per-service Vault secret setup (gitlab-runner, minio, monitoring,
│   │                                     nocodb, paperless, renovate, restic-ssh, vaultwarden, velero)
│   ├── add-authelia-user.sh         #   Add/update an Authelia user in Vault
│   ├── setup-coredns.sh / setup-nextcloud-storage.sh
│   └── test-cnpg-recovery.sh / test-velero-recovery.sh
│
├── docs/                        # Runbooks
│   ├── vault-setup.md / backup-strategy.md / cilium-migration.md
│   ├── gitlab-runner-setup.md / keycloak-setup.md / monitoring-setup.md
│   └── nextcloud-setup.md / nextcloud-apps.md / paperless-setup.md / group-management.md
│
├── certs/                      # gitignored - local CA cert for device import
│   └── homelab-ca.crt
│
├── CLAUDE.md                   # Conventions for AI coding agents working in this repo
├── .pre-commit-config.yaml
├── .yamllint.yml
├── .golangci.yml
├── .editorconfig
├── .gitignore
├── Makefile
└── README.md
```

## Quick Start

```bash
# 1. Open in VS Code devcontainer
code .  # → "Reopen in Container"

# 2. Provision Hetzner server
make tf-init
make tf-plan
make tf-apply

# 3. Configure Ansible secrets
make vault-edit
# Fill in: vault_tailscale_auth_key, vault_samba_admin_password, etc.

# 4. Configure server (Ubuntu, Tailscale, k3s, Samba AD)
make ansible-ping
make ansible-run

# 5. Set up Tailscale Split DNS
# Tailscale Admin Panel → DNS → Add nameserver
# → Server Tailscale IP, restrict to: homelab.local

# 6. Bootstrap Kubernetes services (pre-Vault, chicken-and-egg exceptions)
make bootstrap        # CNPG, Redis, ArgoCD
make bootstrap-certs  # cert-manager, internal CA, wildcard HTTPS
make setup-coredns    # *.homelab.local DNS resolution inside the cluster

# 7. Bootstrap Vault, then everything else goes through it
export VAULT_TOKEN="..."          # root token from setup-hcvault.sh's output
./scripts/setup-hcvault.sh        # init/unseal, policies, K8s auth method
./scripts/migrate-secrets-to-vault.sh   # seed Vault from what bootstrap already created

# 8. Import CA certificate into your devices (once per device)
make cert-ca

# 9. Set up individual services (each reads/writes Vault directly)
#    See scripts/setup-<service>.sh - GitLab Runner, MinIO, Monitoring,
#    NocoDB, Paperless, Renovate, Restic SSH, Vaultwarden, Velero
make runner-setup
make setup-monitoring
# ... etc, one per service - see the Makefile / scripts/ list above

# 10. Verify
make status
make apps
make runner-status
```

Adding a service later? See "Adding a New Service" below, or ask Claude Code to run the
`/new-service` skill (see `.claude/skills/new-service/`), which scaffolds the ArgoCD
Application, ExternalSecret, and catalog entry together.

## What Gets Deployed

### Via Ansible (on the host)
- Ubuntu hardening (SSH keys only, UFW, fail2ban)
- Tailscale mesh VPN
- k3s cluster (Cilium CNI over tailscale0)
- Samba AD DC (HOMELAB.LOCAL, wildcard `*.homelab.local` DNS)

### Via Bootstrap Scripts (one-time, pre-Vault)
- Traefik hostPort config (80/443) + HTTP→HTTPS redirect
- CloudNativePG operator + shared PostgreSQL cluster (`homelab-pg`)
- Redis (Bitnami)
- ArgoCD + root App-of-Apps
- cert-manager + internal CA + wildcard TLS certificate
- HashiCorp Vault + Kubernetes auth method + policies

### Via ArgoCD (GitOps) - `k8s/argocd/applications/`
All secrets for these come from Vault via `ExternalSecret` (`k8s/security/external-secrets/`),
never committed to Git - see "Secrets Management" below.

| App | Namespace | What it is |
|-----|-----------|------------|
| `external-secrets` | external-secrets | External Secrets Operator |
| `security-manifests` | security | Network policies, ExternalSecrets, Vault ClusterSecretStore |
| `traefik-public` | public | Second Traefik instance for internet-facing services |
| `cert-manager-webhook-hetzner` | cert-manager | Hetzner DNS webhook for DNS-01 challenges |
| `infrastructure` | infrastructure | Postgres cluster, cert-sync CronJob, wildcard cert, MinIO backup |
| `redis` | infrastructure | Shared Redis cache |
| `minio` | infrastructure | S3-compatible object storage |
| `keycloak` | auth | SSO / identity provider (LDAP → Samba AD, OIDC for everything else) |
| `gitlab` + `gitlab-runner` | gitlab | Self-hosted GitLab CE (Omnibus) + Instance Runner |
| `vault` | security | HashiCorp Vault (also managed as an ArgoCD app for upgrades) |
| `vaultwarden` | security | Bitwarden-compatible password manager |
| `nextcloud` | productivity | File sync & sharing |
| `paperless` | productivity | Document management (Paperless-ngx) |
| `nocodb` | productivity | No-code database / spreadsheet UI |
| `overleaf` | overleaf | Collaborative LaTeX editor |
| `backstage` | backstage | Internal developer portal / this software catalog |
| `monitoring` | monitoring | Prometheus + Grafana + Alertmanager (kube-prometheus-stack) |
| `loki` + `alloy` | monitoring | Log aggregation (Loki) + log/metrics shipping (Alloy) |
| `renovate` | automation | Automated dependency update bot |
| `velero` | backup | Cluster backup/restore |
| `public` | public | Authelia forward-auth + public IngressRoutes (overleaf, minecraft) |

## TLS / HTTPS

All `*.homelab.local` services are served over HTTPS using an internal CA managed by cert-manager.
See `make cert-ca` for device import instructions.

## GitLab SSH

GitLab SSH läuft auf Port **2222** (Tailscale only):

```bash
# ~/.ssh/config (wird automatisch vom Devcontainer post-create.sh gesetzt)
Host gitlab.homelab.local
    Port 2222
    User git
    IdentityFile ~/.ssh/id_ed25519

# Clone
git clone ssh://git@gitlab.homelab.local:2222/jmoseler/my-repo.git
```

## Adding a New Service

Three pieces, following the conventions in `CLAUDE.md`:

1. **`k8s/argocd/applications/my-service.yaml`** - the ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://some-chart-repo.example.com
    chart: my-service
    targetRevision: "1.2.3"   # pin a real version, never a placeholder
    helm:
      values: |
        ingress:
          enabled: true
          ingressClassName: traefik
          hosts:
            - my-service.homelab.local
          tls:
            - secretName: homelab-wildcard-tls
              hosts:
                - my-service.homelab.local
  destination:
    server: https://kubernetes.default.svc
    namespace: my-namespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

2. **`k8s/security/external-secrets/<category>/my-service-secret.yaml`** - if it needs credentials,
   pointing at `homelab/my-namespace/my-service-secret` in Vault. Seed the actual values with a
   `scripts/setup-my-service.sh` script (see existing ones for the pattern) - never inline them.

3. **`catalog/my-service/catalog-info.yaml`** - registered in `catalog/all.yaml`, so it shows up
   in Backstage.

Commit and push - ArgoCD syncs automatically. Or ask Claude Code to run `/new-service`, which
scaffolds all three.

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all commands |
| `make lint` | Run all linters (pre-commit) |
| `make tf-init` / `tf-plan` / `tf-apply` / `tf-destroy` / `tf-output` | Terraform |
| `make ansible-ping` | Test SSH to all hosts |
| `make ansible-run` | Run full site playbook |
| `make ansible-check` | Dry-run site playbook |
| `make ansible-cluster` | Run k3s cluster playbook only |
| `make ansible-samba` | Run Samba AD role only |
| `make ansible-backup` | Run Samba backup role only |
| `make harden-ssh` | Lock SSH/k3s-API to tailscale0 (manual, post-bootstrap - read `ansible/roles/hardening/README.md` first) |
| `make migrate-cilium-workers` / `migrate-cilium-workers-clean` / `migrate-cilium-server` | Flannel → Cilium migration phases (see `docs/cilium-migration.md`) |
| `make vault-edit` / `vault-view` | Edit/view Ansible Vault secrets |
| `make bootstrap` | Bootstrap k8s services (CNPG, Redis, ArgoCD) |
| `make bootstrap-certs` | Bootstrap cert-manager + internal CA |
| `make setup-coredns` | Configure CoreDNS for `*.homelab.local` |
| `make setup-monitoring` | Setup Grafana OIDC + Alertmanager secrets (writes to Vault) |
| `make runner-setup` / `runner-status` / `runner-logs` | GitLab instance runner setup + status |
| `make status` | Cluster overview (nodes, pods, certs, resources) |
| `make pods` | List all pods |
| `make apps` | ArgoCD application status |
| `make argocd-pw` | Show ArgoCD admin password |
| `make cert-status` | Show all certificates and issuers |
| `make cert-ca` | Show CA cert details + import instructions |
| `make cert-sync` | Manually trigger wildcard cert sync to kube-system |
| `make velero-status` | Show Velero backup status and storage location |
| `make recovery-test` | Run all recovery tests (quarterly): Postgres + Velero |
| `make samba-backup-status` | Show Samba backup timer status on server |

## Secrets Management

**Ansible:** Encrypted with `ansible-vault`. Password in `ansible/.vault_password` (never committed).

**Kubernetes:** All service secrets flow through **HashiCorp Vault**, never committed to Git and
never created directly as plain `Secret` manifests:

```
scripts/setup-<service>.sh  →  vault kv put secret/homelab/<namespace>/<service>-secret
                                          │
k8s/security/external-secrets/<category>/<service>-secret.yaml  (ExternalSecret, watches that path)
                                          │
External Secrets Operator  →  creates/owns the actual Kubernetes Secret  →  Pod
```

- Vault runs as `vault-0` in the `security` namespace, accessed via `kubectl exec` (see
  `scripts/setup-hcvault.sh` for the init/unseal/policy setup).
- Each service's setup script is idempotent: it checks Vault first and reuses the existing
  value instead of generating a new one on every re-run.
- `scripts/migrate-secrets-to-vault.sh` is the one-time bridge script that seeded Vault from
  secrets that existed before Vault did - see `docs/vault-setup.md`.
- `homelab-ca-keypair` (cert-manager) and the initial `redis-secret` (infrastructure) are the only
  exceptions: they're created directly by the bootstrap scripts, before Vault/ESO exist to manage
  them (chicken-and-egg).

## DNS

All services accessible via `*.homelab.local` through Tailscale Split DNS (internal), or via the
public Traefik instance + Authelia for the few internet-facing ones.

| Service | URL |
|---------|-----|
| ArgoCD | https://argocd.homelab.local |
| Keycloak | https://auth.homelab.local |
| GitLab | https://gitlab.homelab.local (SSH: Port 2222) |
| GitLab Registry | https://registry.homelab.local |
| Vault (HashiCorp) | https://hcvault.homelab.local |
| Vaultwarden | https://vault.homelab.local |
| Nextcloud | https://nextcloud.homelab.local |
| Paperless-ngx | https://paperless.homelab.local |
| NocoDB | https://nocodb.homelab.local |
| MinIO Console | https://minio-console.homelab.local |
| Grafana | https://grafana.homelab.local |
| Backstage | https://backstage.homelab.local |
| Overleaf (public) | https://overleaf.svc.johannesmoseler.de |
| Authelia (public) | https://login.svc.johannesmoseler.de |

## Progress

- [x] Devcontainer + linting + pre-commit
- [x] Terraform: Hetzner CX53 + private network + firewall
- [x] Ansible: common, hardening, tailscale, k3s_server, k3s_agent, samba, backup
- [x] Samba AD DC: HOMELAB.LOCAL with wildcard DNS over Tailscale
- [x] k3s cluster over Tailscale, migrated Flannel → Cilium
- [x] Traefik ingress (hostPort 80/443) + HTTP→HTTPS redirect + second public instance
- [x] ArgoCD bootstrap + App-of-Apps
- [x] CloudNativePG + shared PostgreSQL cluster
- [x] Redis
- [x] HashiCorp Vault + External Secrets Operator - all service secrets migrated off direct kubectl-created Secrets
- [x] GitLab CE (Omnibus) + SSH on Port 2222 (Tailscale only) + GitLab Runner
- [x] cert-manager + internal CA + wildcard TLS for *.homelab.local
- [x] Keycloak SSO (LDAP → Samba AD, OIDC for GitLab, ArgoCD, Nextcloud, Grafana, Paperless)
- [x] Nextcloud, Paperless-ngx, NocoDB, Vaultwarden, MinIO, Overleaf
- [x] Backstage software catalog (all deployed services registered)
- [x] Monitoring stack (Prometheus, Grafana, Loki, Alloy, Alertmanager)
- [x] Renovate (automated dependency updates)
- [x] Velero (cluster backup/restore) + quarterly recovery tests
- [x] Authelia + public IngressRoutes (Overleaf, Minecraft) on a separate public Traefik instance
- [ ] Second Hetzner worker (CX43) - defined in Terraform, not yet provisioned
- [ ] kube-proxy replacement (Cilium-native)
- [ ] Phase 2: Stalwart Mail
