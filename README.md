# Homelab Infrastructure

Hybrid Kubernetes cluster managed with Terraform, Ansible & ArgoCD.

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
│   ├── servers.tf
│   └── outputs.tf
│
├── ansible/                    # Server configuration
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.yml
│   ├── roles/
│   │   ├── common/             # Base packages, SSH, NTP, UFW
│   │   ├── tailscale/          # Tailscale mesh VPN
│   │   ├── k3s-server/         # k3s control plane
│   │   ├── k3s-agent/          # k3s worker nodes
│   │   └── samba-ad/           # Samba AD DC
│   └── playbooks/
│       ├── site.yml            # Full setup
│       └── cluster.yml         # k3s only
│
├── charts/                     # Custom Helm charts
│   ├── gitlab-omnibus/
│   ├── invoiceplane/
│   └── pocketbase/
│
├── values/                     # Helm values per environment
│   └── production/
│       ├── gitlab.yaml
│       ├── nextcloud.yaml
│       ├── keycloak.yaml
│       └── ...
│
├── argocd/                     # ArgoCD Application CRDs
│   └── applications/
│
├── namespaces/                 # Kubernetes namespaces
│   ├── gitlab.yaml
│   ├── auth.yaml
│   ├── productivity.yaml
│   ├── security.yaml
│   ├── finance.yaml
│   ├── monitoring.yaml
│   └── ...
│
├── infrastructure/             # Shared infra (PostgreSQL, Redis)
│
├── scripts/                    # Go helper scripts & tooling
│
├── .pre-commit-config.yaml     # Pre-commit hooks
├── .yamllint.yml               # YAML linter config
├── .golangci.yml               # Go linter config
├── .editorconfig               # Editor formatting rules
├── .gitignore
├── .gitlab-ci.yml              # CI pipeline (later)
├── .env.example                # Environment variable template
├── Makefile                    # Common commands (later)
└── README.md
```

## Setup

```bash
# Open in VS Code devcontainer (installs everything)
code .
# → "Reopen in Container"

# Install pre-commit hooks
pre-commit install

# Verify
pre-commit run --all-files
```

## Pre-commit Hooks

Runs automatically on every `git commit`:

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

## Devcontainer Tools

Pre-installed in the devcontainer:

- **Go** (latest) + golangci-lint, goimports
- **Python 3.12** + Ansible, ansible-lint, yamllint
- **Node.js 20** (Helm chart testing)
- **Terraform** + tflint
- **kubectl** + Helm + k9s
- **Docker-in-Docker**
- **pre-commit**
