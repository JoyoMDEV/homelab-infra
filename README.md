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
```

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
│   │       ├── redis.yaml
│   │       └── infrastructure.yaml
│   ├── infrastructure/
│   │   ├── postgres-cluster.yaml
│   │   ├── cert-manager-issuer.yaml    # ClusterIssuer (references secret, no key in git)
│   │   ├── homelab-wildcard-cert.yaml  # Wildcard cert for *.homelab.local
│   │   └── cert-sync-cronjob.yaml      # Daily sync of wildcard secret to kube-system
│   └── charts/
│       └── gitlab-omnibus/     #   GitLab CE custom Helm chart
│
├── scripts/
│   ├── bootstrap-argocd.sh     #   One-time: CNPG, Redis, ArgoCD
│   ├── bootstrap-certmanager.sh#   One-time: cert-manager, internal CA, wildcard cert
│   └── setup-databases.sh      #   One-time: PostgreSQL databases + secrets
│
├── certs/                      # gitignored - local CA cert for device import
│   └── homelab-ca.crt          #   Import into browsers/OS to trust *.homelab.local
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

# 7. Import CA certificate into your devices (once per device)
# File: certs/homelab-ca.crt
# Ubuntu: sudo cp certs/homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# macOS:  open certs/homelab-ca.crt → Keychain: System → Always Trust
# Windows: certmgr.msc → Trusted Root CAs → Import

# 8. Verify
make status
make apps
curl -v https://argocd.homelab.local
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

### Via ArgoCD (GitOps)
- cert-manager (Helm upgrades)
- Redis (Bitnami)
- Keycloak (SSO, connected to Samba AD via LDAP)
- GitLab CE (Omnibus)
- All future services

## TLS / HTTPS

All `*.homelab.local` services are served over HTTPS using an internal CA managed by cert-manager.

**How it works:**
1. `bootstrap-certmanager.sh` generates a CA keypair locally
2. The CA key is pushed to a Kubernetes Secret and **immediately deleted from disk** (never touches Git)
3. cert-manager issues a wildcard certificate for `*.homelab.local`
4. A CronJob syncs the wildcard secret to `kube-system` daily (required for Traefik)
5. Traefik uses the wildcard cert as the default for all Ingress routes

**Secret management:** The CA private key lives only in the `homelab-ca-keypair` Kubernetes Secret. The `certs/` directory (gitignored) holds only `homelab-ca.crt` for device import.

**Certificate renewal** is fully automatic: cert-manager renews 30 days before expiry, the daily CronJob syncs the new cert to Traefik.

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
| `make status` | Cluster overview (nodes, pods, certs, resources) |
| `make pods` | List all pods |
| `make apps` | ArgoCD application status |
| `make argocd-pw` | Show ArgoCD admin password |
| `make cert-status` | Show all certificates and issuers |
| `make cert-ca` | Show CA cert details + import instructions |
| `make cert-sync` | Manually trigger wildcard cert sync to kube-system |

## Secrets Management

**Ansible:** Encrypted with `ansible-vault`. Password in `ansible/.vault_password` (never committed).
```bash
make vault-edit    # Edit secrets
make vault-view    # View secrets
```

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

## DNS

All services accessible via `*.homelab.local` through Tailscale Split DNS.
Samba AD DC serves a wildcard A record pointing to the server's Tailscale IP.

| Service | URL |
|---------|-----|
| ArgoCD | https://argocd.homelab.local |
| Keycloak | https://auth.homelab.local |
| GitLab | https://gitlab.homelab.local |
| GitLab Registry | https://registry.homelab.local |
| Future: Grafana | https://grafana.homelab.local |
| Future: Nextcloud | https://nextcloud.homelab.local |

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
- [x] GitLab CE (Omnibus)
- [x] cert-manager + internal CA + wildcard TLS for *.homelab.local
- [ ] Keycloak SSO (LDAP → Samba AD, OIDC for GitLab)
- [ ] Remaining services (Nextcloud, Vaultwarden, Paperless, ...)
- [ ] Monitoring stack (Prometheus, Grafana, Loki)
- [ ] Phase 2: Stalwart Mail, Portfolio, public access
