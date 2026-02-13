# Homelab Infrastructure

Hybrid Kubernetes cluster: 2 Home-Nodes + 2 Hetzner Cloud servers, managed with Terraform, Ansible & ArgoCD.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Tailscale Mesh VPN                    │
├──────────────────┬──────────────────┬───────────────────┤
│  Hetzner CX53    │  Home Node 01    │  Home Node 02     │
│  k3s-server      │  k3s-worker-01   │  k3s-worker-02    │
│  32 GB / 16 vCPU │  16 GB / 4C 8T   │  16 GB / 4C 8T   │
│  Control Plane   │  Worker          │  Worker           │
│  Samba AD DC     │                  │                   │
├──────────────────┤                  │                   │
│  Hetzner CX43    │                  │                   │
│  k3s-worker-03   │                  │                   │
│  16 GB / 8 vCPU  │                  │                   │
└──────────────────┴──────────────────┴───────────────────┘

DNS: *.homelab.local → Samba AD DC (Tailscale Split DNS)
Ingress: Traefik (hostPort 80/443) → Services
```

## Project Structure

```
homelab-infra/
├── .devcontainer/              # Devcontainer (Go, Python, Terraform, Helm, k9s)
│   ├── devcontainer.json
│   └── post-create.sh
│
├── terraform/                  # Hetzner Cloud provisioning
│   ├── main.tf                 #   Provider config
│   ├── variables.tf            #   Token, SSH key, location
│   ├── servers.tf              #   CX53 + private network + firewall (CX43 prepared)
│   ├── outputs.tf              #   Server IPs, SSH command
│   └── terraform.tfvars.example
│
├── ansible/                    # Server configuration
│   ├── ansible.cfg
│   ├── .vault_password         #   Vault password (NOT committed)
│   ├── inventory/
│   │   ├── hosts.yml           #   Server + workers (workers commented out)
│   │   └── group_vars/
│   │       └── all/
│   │           ├── vars.yml    #   Non-secret variables
│   │           └── vault.yml   #   Encrypted secrets (ansible-vault)
│   ├── roles/
│   │   ├── common/             #   Base packages, SSH hardening, UFW
│   │   ├── tailscale/          #   Tailscale (accept-dns=false on server)
│   │   ├── k3s_server/         #   k3s control plane over Tailscale
│   │   ├── k3s_agent/          #   k3s worker nodes
│   │   └── samba_ad/           #   Samba AD DC (HOMELAB.LOCAL, wildcard DNS)
│   └── playbooks/
│       ├── site.yml            #   Full setup (common → tailscale → k3s → samba)
│       └── cluster.yml         #   k3s only (server + agents)
│
├── k8s/                        # Kubernetes manifests
│   ├── namespaces.yaml         #   All namespace definitions
│   ├── traefik-config.yaml     #   Traefik hostPort 80/443 (HelmChartConfig)
│   ├── values/
│   │   └── argocd.yaml         #   ArgoCD Helm values
│   ├── argocd/
│   │   ├── root.yaml           #   App-of-Apps root application
│   │   └── applications/       #   ArgoCD Application CRDs
│   │       ├── redis.yaml      #     Redis standalone
│   │       └── infrastructure.yaml # Points to k8s/infrastructure/
│   └── infrastructure/         # Shared infra manifests
│       └── postgres-cluster.yaml # CloudNativePG cluster (1 instance)
│
├── scripts/
│   └── bootstrap-argocd.sh     # One-time bootstrap (CNPG, Redis, ArgoCD)
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

# 3. Set up Ansible secrets
make vault-edit
# Fill in: vault_tailscale_auth_key, vault_samba_admin_password, etc.

# 4. Configure server (Ubuntu, Tailscale, k3s, Samba AD)
make ansible-ping
make ansible-run

# 5. Set up Tailscale Split DNS
# In Tailscale Admin Panel → DNS → Add nameserver
# Server Tailscale IP, restrict to: homelab.local

# 6. Bootstrap Kubernetes services
make bootstrap

# 7. Verify
make status
make apps
```

## What Gets Deployed

### Via Ansible (on the host)
- Ubuntu hardening (SSH keys only, UFW, fail2ban)
- Tailscale mesh VPN
- k3s single-node cluster (Flannel over tailscale0)
- Samba AD DC (HOMELAB.LOCAL, wildcard *.homelab.local DNS)

### Via Bootstrap Script (Helm + kubectl)
- Traefik hostPort config (port 80/443)
- CloudNativePG operator + PostgreSQL cluster
- Redis secret (auto-generated)
- ArgoCD + root App-of-Apps

### Via ArgoCD (GitOps)
- Redis (Bitnami Helm chart)
- PostgreSQL cluster manifest
- All future services (just add YAML to k8s/argocd/applications/)

## Adding a New Service

Create a file in `k8s/argocd/applications/`, commit and push. ArgoCD syncs automatically.

Example (`k8s/argocd/applications/my-service.yaml`):
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
| `make bootstrap` | Bootstrap k8s services (one-time) |
| `make status` | Cluster overview (nodes, pods, resources) |
| `make pods` | List all pods |
| `make apps` | ArgoCD application status |
| `make argocd-pw` | Show ArgoCD admin password |

## Secrets Management

**Ansible**: Encrypted with `ansible-vault`. Password in `ansible/.vault_password` (never committed).
```bash
make vault-edit    # Edit secrets
make vault-view    # View secrets
```

**Kubernetes**: Created by bootstrap script (Redis) or by operators (PostgreSQL).
Sealed Secrets or HashiCorp Vault integration planned for later.

## DNS

All services are accessible via `*.homelab.local` through Tailscale Split DNS.
Samba AD DC serves a wildcard A record pointing to the server's Tailscale IP.

| Service | URL |
|---------|-----|
| ArgoCD | http://argocd.homelab.local |
| Future: Keycloak | http://auth.homelab.local |
| Future: GitLab | http://gitlab.homelab.local |
| Future: Grafana | http://grafana.homelab.local |

## Progress

- [x] Devcontainer + linting + pre-commit
- [x] Terraform: Hetzner CX53 + private network + firewall
- [x] Ansible: common, tailscale, k3s_server, k3s_agent, samba_ad
- [x] Samba AD DC: HOMELAB.LOCAL with wildcard DNS over Tailscale
- [x] k3s single-node cluster over Tailscale
- [x] Traefik ingress (hostPort 80/443)
- [x] ArgoCD bootstrap + App-of-Apps
- [x] CloudNativePG + PostgreSQL cluster
- [x] Redis
- [ ] Keycloak SSO (connects to Samba AD via LDAP)
- [ ] GitLab CE (Omnibus)
- [ ] Remaining services (Nextcloud, Vaultwarden, Paperless, ...)
- [ ] Monitoring stack (Prometheus, Grafana, Loki)
- [ ] Phase 2: Stalwart Mail, Portfolio, public access
