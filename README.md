# Homelab Infrastructure

Hybrid Kubernetes cluster: 2 Home-Nodes + 2 Hetzner Cloud servers, managed with Terraform, Ansible & ArgoCD.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Tailscale Mesh VPN                   │
├──────────────────┬──────────────────┬───────────────────┤
│  Hetzner CX53    │  Home Node 01    │  Home Node 02     │
│  k3s-server      │  k3s-worker-01   │  k3s-worker-02    │
│  32 GB / 16 vCPU │  16 GB / 4C 8T   │  16 GB / 4C 8T    │
│  Control Plane   │  Worker          │  Worker           │
│  Samba AD DC     │                  │                   │
├──────────────────┤                  │                   │
│  Hetzner CX43    │                  │                   │
│  k3s-worker-03   │                  │                   │
│  16 GB / 8 vCPU  │                  │                   │
└──────────────────┴──────────────────┴───────────────────┘

DNS:     *.homelab.local → Samba AD DC (Tailscale Split DNS)
Ingress: Traefik (hostPort 80/443) → Services
TLS:     cert-manager internal CA → Wildcard *.homelab.local
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
│   ├── devcontainer.json
│   └── post-create.sh
│
├── terraform/                  # Hetzner Cloud provisioning
│   ├── main.tf
│   ├── variables.tf
│   ├── servers.tf              #   CX53 + private network + firewall
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── ansible/                    # Server configuration
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── hosts.yml
│   │   └── group_vars/all/
│   │       ├── vars.yml        #   Non-secret variables
│   │       └── vault.yml       #   Encrypted secrets (ansible-vault)
│   ├── roles/
│   │   ├── common/             #   Base packages, SSH hardening, UFW
│   │   ├── tailscale/          #   Tailscale mesh VPN
│   │   ├── k3s_server/         #   k3s control plane
│   │   ├── k3s_agent/          #   k3s worker nodes
│   │   └── samba_ad/           #   Samba AD DC (HOMELAB.LOCAL, wildcard DNS)
│   └── playbooks/
│       ├── site.yml
│       └── cluster.yml
│
├── k8s/                        # Kubernetes manifests
│   ├── namespaces.yaml
│   ├── traefik-tls-config.yaml #   Traefik hostPort 80/443 + HTTP→HTTPS redirect
│   ├── traefik-tlsstore.yaml   #   Traefik default TLS cert (wildcard)
│   ├── values/
│   │   └── argocd.yaml
│   ├── argocd/
│   │   ├── root.yaml           #   App-of-Apps root
│   │   └── applications/
│   │       ├── cert-manager.yaml
│   │       ├── keycloak.yaml
│   │       ├── gitlab.yaml
│   │       ├── gitlab-runner.yaml  #   GitLab Instance Runner (k8s executor)
│   │       ├── nextcloud.yaml
│   │       ├── redis.yaml
│   │       └── infrastructure.yaml
│   ├── infrastructure/
│   │   ├── postgres-cluster.yaml
│   │   ├── cert-manager-issuer.yaml
│   │   ├── homelab-wildcard-cert.yaml
│   │   ├── cert-sync-cronjob.yaml
│   │   └── nextcloud-middleware.yaml
│   └── charts/
│       └── gitlab-omnibus/     #   GitLab CE custom Helm chart
│
├── scripts/
│   ├── bootstrap-argocd.sh         #   One-time: CNPG, Redis, ArgoCD
│   ├── bootstrap-certmanager.sh    #   One-time: cert-manager, internal CA, wildcard cert
│   ├── setup-databases.sh          #   One-time: PostgreSQL databases + secrets
│   ├── setup-gitlab-runner.sh      #   One-time: GitLab Runner Token + Secret
│   └── setup-nextcloud-storage.sh  #   One-time: Storage Box as WebDAV External Storage
│
├── docs/
│   ├── gitlab-runner-setup.md  #   GitLab Runner Runbook + Pipeline-Beispiele
│   ├── keycloak-setup.md       #   Keycloak SSO setup runbook
│   └── nextcloud-setup.md      #   Nextcloud setup runbook
│
├── certs/                      # gitignored - local CA cert for device import
│   └── homelab-ca.crt
│
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

# 6. Bootstrap Kubernetes services
make bootstrap        # CNPG, Redis, ArgoCD
make bootstrap-certs  # cert-manager, internal CA, wildcard HTTPS
make setup-coredns    # *.homelab.local DNS resolution inside the cluster

# 7. Import CA certificate into your devices (once per device)
make cert-ca

# 8. Setup GitLab Runner
# GitLab → Admin Area → CI/CD → Runners → New instance runner
# Tags: k8s, Run untagged jobs: ✅ → Token kopieren
make runner-setup     # Token wird interaktiv abgefragt

# 9. Verify
make status
make apps
make runner-status
```

## What Gets Deployed

### Via Ansible (on the host)
- Ubuntu hardening (SSH keys only, UFW, fail2ban)
- Tailscale mesh VPN
- k3s single-node cluster (Flannel over tailscale0)
- Samba AD DC (HOMELAB.LOCAL, wildcard `*.homelab.local` DNS)

### Via Bootstrap Scripts (one-time)
- Traefik hostPort config (80/443) + HTTP→HTTPS redirect
- CloudNativePG operator + PostgreSQL cluster
- Redis (secret auto-generated)
- ArgoCD + root App-of-Apps
- cert-manager + internal CA + wildcard TLS certificate
- cert-sync CronJob (daily auto-renewal sync)
- CoreDNS wildcard config for `*.homelab.local`
- GitLab Runner Secret + Instance Runner Registration

### Via ArgoCD (GitOps)
- cert-manager (Helm upgrades)
- Redis (Bitnami)
- Keycloak (SSO, connected to Samba AD via LDAP)
- GitLab CE (Omnibus) + GitLab Runner (k8s executor)
- Nextcloud (with Keycloak OIDC + Hetzner Storage Box via WebDAV)
- All future services

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

Create `k8s/argocd/applications/my-service.yaml`, commit and push. ArgoCD syncs automatically.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://some-chart-repo.example.com
    chart: my-service
    targetRevision: 1.*
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

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all commands |
| `make lint` | Run all linters (pre-commit) |
| `make tf-init` | Terraform init |
| `make tf-plan` | Terraform plan |
| `make tf-apply` | Terraform apply |
| `make tf-output` | Show Terraform outputs |
| `make ansible-ping` | Test SSH to all hosts |
| `make ansible-run` | Run full site playbook |
| `make ansible-check` | Dry-run site playbook |
| `make ansible-cluster` | Run k3s cluster playbook only |
| `make ansible-samba` | Run Samba AD role only |
| `make vault-edit` | Edit Ansible Vault secrets |
| `make vault-view` | View Ansible Vault secrets |
| `make bootstrap` | Bootstrap k8s services (CNPG, Redis, ArgoCD) |
| `make bootstrap-certs` | Bootstrap cert-manager + internal CA |
| `make setup-coredns` | Configure CoreDNS for `*.homelab.local` |
| `make runner-setup` | Setup GitLab instance runner (one-time) |
| `make runner-status` | Show Runner Pod + active jobs |
| `make runner-logs` | Tail Runner logs |
| `make status` | Cluster overview (nodes, pods, certs, resources) |
| `make pods` | List all pods |
| `make apps` | ArgoCD application status |
| `make argocd-pw` | Show ArgoCD admin password |
| `make cert-status` | Show all certificates and issuers |
| `make cert-ca` | Show CA cert details + import instructions |
| `make cert-sync` | Manually trigger wildcard cert sync to kube-system |

## Secrets Management

**Ansible:** Encrypted with `ansible-vault`. Password in `ansible/.vault_password` (never committed).

**Kubernetes:** Created by bootstrap scripts or operators. Never committed to Git.

| Secret | Namespace | Created by |
|--------|-----------|------------|
| `homelab-ca-keypair` | cert-manager | `bootstrap-certmanager.sh` |
| `homelab-wildcard-tls` | infrastructure, kube-system | cert-manager + sync |
| `redis-secret` | infrastructure | `bootstrap-argocd.sh` |
| `keycloak-secret` | auth | `setup-databases.sh` |
| `keycloak-db-secret` | auth | `setup-databases.sh` |
| `gitlab-secret` | gitlab | `setup-databases.sh` |
| `gitlab-rails-secrets` | gitlab | `setup-databases.sh` |
| `gitlab-runner-secret` | gitlab | `setup-gitlab-runner.sh` |
| `nextcloud-secret` | productivity | `setup-databases.sh` |

## DNS

All services accessible via `*.homelab.local` through Tailscale Split DNS.

| Service | URL |
|---------|-----|
| ArgoCD | https://argocd.homelab.local |
| Keycloak | https://auth.homelab.local |
| GitLab | https://gitlab.homelab.local (SSH: Port 2222) |
| GitLab Registry | https://registry.homelab.local |
| Nextcloud | https://nextcloud.homelab.local |
| Future: Grafana | https://grafana.homelab.local |

## Progress

- [x] Devcontainer + linting + pre-commit
- [x] Terraform: Hetzner CX53 + private network + firewall
- [x] Ansible: common, tailscale, k3s_server, k3s_agent, samba_ad
- [x] Samba AD DC: HOMELAB.LOCAL with wildcard DNS over Tailscale
- [x] k3s single-node cluster over Tailscale
- [x] Traefik ingress (hostPort 80/443) + HTTP→HTTPS redirect
- [x] ArgoCD bootstrap + App-of-Apps
- [x] CloudNativePG + PostgreSQL cluster
- [x] Redis
- [x] GitLab CE (Omnibus) + SSH on Port 2222 (Tailscale only)
- [x] GitLab Runner (k8s executor, instance runner)
- [x] cert-manager + internal CA + wildcard TLS for *.homelab.local
- [x] Keycloak SSO (LDAP → Samba AD, OIDC for GitLab + ArgoCD)
- [x] Nextcloud (OIDC via Keycloak, Storage Box via WebDAV)
- [ ] Portfolio CI/CD Pipeline (build → deploy to Hetzner Webhosting)
- [ ] Monitoring stack (Prometheus, Grafana, Loki)
- [ ] Remaining services (Vaultwarden, Paperless, ...)
- [ ] Phase 2: Stalwart Mail, public access
