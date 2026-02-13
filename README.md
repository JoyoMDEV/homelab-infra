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
│   ├── servers.tf              #   CX53 + network + firewall (CX43 prepared)
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
│   │   └── samba_ad/           #   Samba AD DC (HOMELAB.LOCAL)
│   └── playbooks/
│       ├── site.yml            #   Full setup (common → tailscale → k3s → samba)
│       └── cluster.yml         #   k3s only (server + agents)
│
├── k8s/                        # Kubernetes manifests
│   ├── namespaces.yaml         #   All namespace definitions
│   ├── values/
│   │   └── argocd.yaml         #   ArgoCD Helm values
│   ├── argocd/
│   │   ├── root.yaml           #   App-of-Apps root application
│   │   └── applications/       #   ArgoCD Application CRDs
│   │       ├── argocd.yaml     #     ArgoCD (self-managing)
│   │       ├── cnpg-operator.yaml #  CloudNativePG operator
│   │       ├── redis.yaml      #     Redis standalone
│   │       └── infrastructure.yaml # Points to k8s/infrastructure/
│   └── infrastructure/         # Shared infra manifests
│       └── postgres-cluster.yaml # CloudNativePG cluster (1 instance)
│
├── scripts/
│   └── bootstrap-argocd.sh     # One-time ArgoCD bootstrap
│
├── .pre-commit-config.yaml     # Pre-commit hooks
├── .yamllint.yml               # YAML linter config
├── .golangci.yml               # Go linter config
├── .editorconfig               # Editor formatting rules
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

# 3. Configure server via Ansible
make ansible-ping
make ansible-run

# 4. Bootstrap ArgoCD + core services
make bootstrap

# 5. Check cluster
make status
```

## Makefile Commands

| Command | Description |
|---------|-------------|
| `make help` | Show all commands |
| `make lint` | Run all linters |
| `make tf-init` | Terraform init |
| `make tf-plan` | Terraform plan |
| `make tf-apply` | Terraform apply |
| `make ansible-ping` | Test SSH to all hosts |
| `make ansible-run` | Run full site playbook |
| `make ansible-samba` | Run Samba AD role only |
| `make bootstrap` | Bootstrap ArgoCD (one-time) |
| `make status` | Cluster overview |
| `make pods` | List all pods |
| `make apps` | ArgoCD application status |
| `make vault-edit` | Edit Ansible Vault secrets |
| `make argocd-pw` | Show ArgoCD admin password |

## Deployment Flow

```
Git Push → ArgoCD detects change → Syncs to cluster → Service deployed
```

ArgoCD watches `k8s/argocd/applications/` and automatically deploys any
Application CRD found there. To add a new service, create a YAML in that
directory, commit, push — done.

## Secrets Management

Ansible secrets are managed with `ansible-vault`. The vault password lives
in `ansible/.vault_password` (never committed, in .gitignore).

```bash
make vault-edit              # Edit encrypted secrets
make vault-view              # View encrypted secrets
```

Kubernetes secrets are created manually before deploying services.
Later migration to Sealed Secrets or Vault planned.

## Pre-commit Hooks

| Hook | What it checks |
|------|---------------|
| trailing-whitespace | Trailing spaces |
| end-of-file-fixer | Final newline |
| check-yaml | YAML syntax |
| detect-private-key | Accidental key commits |
| no-commit-to-branch | Blocks direct commits to main |
| yamllint | YAML formatting |
| terraform_fmt | Terraform formatting |
| terraform_validate | Terraform syntax |
| ansible-lint | Ansible best practices |
| golangci-lint | Go linting |
| shellcheck | Shell script analysis |
| gitleaks | Secret leak detection |

## Progress

- [x] Devcontainer + linting + pre-commit
- [x] Terraform: Hetzner CX53 + private network + firewall
- [x] Ansible: common, tailscale, k3s_server, k3s_agent, samba_ad
- [x] Samba AD DC: HOMELAB.LOCAL with Tailscale DNS
- [x] k3s single-node cluster over Tailscale
- [ ] ArgoCD bootstrap + App-of-Apps
- [ ] CloudNativePG + PostgreSQL cluster
- [ ] Redis
- [ ] Keycloak SSO
- [ ] GitLab CE
- [ ] Remaining services (Nextcloud, Vaultwarden, Paperless, ...)
- [ ] Monitoring stack (Prometheus, Grafana, Loki)
- [ ] Phase 2: Stalwart Mail, Portfolio, public access
