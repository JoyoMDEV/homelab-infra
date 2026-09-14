terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
  }
}

provider "coder" {}

provider "kubernetes" {
  # Coder server runs in-cluster (namespace "coder") under a ServiceAccount
  # with workspace-management permissions - no kubeconfig needed.
  config_path = null
}

locals {
  namespace = "coder"
  image     = "registry.homelab.local/homelab/projects/coder-workspace:latest"
}

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = <<-EOT
    set -e

    # SSH config for GitHub + the self-hosted GitLab. The private key comes
    # from a Secret volume mounted read-only outside the persistent home PVC
    # (ExternalSecret "coder-secret", key "git-ssh-private-key"); known_hosts
    # is baked into the image at /etc/ssh/ssh_known_hosts.
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    if [ ! -f "$HOME/.ssh/config" ]; then
      printf '%s\n' \
        'Host github.com' \
        '  IdentityFile /etc/coder/ssh/id_ed25519' \
        '  UserKnownHostsFile /etc/ssh/ssh_known_hosts' \
        '  IdentitiesOnly yes' \
        'Host gitlab.homelab.local' \
        '  IdentityFile /etc/coder/ssh/id_ed25519' \
        '  UserKnownHostsFile /etc/ssh/ssh_known_hosts' \
        '  IdentitiesOnly yes' \
        '  Port 2222' \
        > "$HOME/.ssh/config"
      chmod 600 "$HOME/.ssh/config"
    fi

    # Clone this repo automatically - lands on the persistent home PVC, so
    # this only actually runs once per workspace lifetime (idempotent: skips
    # if already cloned from a previous start).
    if [ ! -d "$HOME/homelab-infra/.git" ]; then
      git clone git@github.com:JoyoMDEV/homelab-infra.git "$HOME/homelab-infra" || \
        echo "WARN: homelab-infra clone failed (check the git-ssh-private-key deploy key) - continuing"
    fi

    mkdir -p "$HOME/Code/gitlab"
    if [ ! -d "$HOME/Code/gitlab/context-hub/.git" ]; then
      git clone git@gitlab.homelab.local:homelab/projects/context-hub.git "$HOME/Code/gitlab/context-hub" || \
        echo "WARN: context-hub clone failed - continuing"
    fi

    # Claude Code CLI - installed into the persistent home PVC (not
    # /usr/local, which the non-root "coder" user can't write to) so it
    # survives pod restarts without needing to reinstall every time.
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"
    if ! grep -q '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null; then
      echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
    fi
    if ! command -v claude >/dev/null 2>&1; then
      npm install -g @anthropic-ai/claude-code
    fi

    if command -v claude >/dev/null 2>&1; then
      # Re-run unconditionally on every startup: the config below only ever
      # contains $${VAR}-style references (never literal secret values), so
      # re-adding is idempotent/self-healing rather than something that needs
      # a "already registered" guard - it also automatically repairs a
      # previously-broken registration on the next workspace restart.
      claude mcp add --scope user github github-mcp-server stdio \
        --env GITHUB_PERSONAL_ACCESS_TOKEN='$${GITHUB_MCP_TOKEN}' || \
        echo "WARN: 'claude mcp add github' failed - check 'claude mcp add --help' for the current flag syntax"
      claude mcp add --scope user gitlab mcp-gitlab \
        --env GITLAB_PERSONAL_ACCESS_TOKEN='$${GITLAB_MCP_TOKEN}' \
        --env GITLAB_API_URL="https://gitlab.homelab.local/api/v4" || \
        echo "WARN: 'claude mcp add gitlab' failed - check 'claude mcp add --help' for the current flag syntax"
      claude mcp add --scope user grafana mcp-grafana \
        --env GRAFANA_URL="https://grafana.homelab.local" \
        --env GRAFANA_SERVICE_ACCOUNT_TOKEN='$${GRAFANA_MCP_TOKEN}' || \
        echo "WARN: 'claude mcp add grafana' failed - check 'claude mcp add --help' for the current flag syntax"
    fi

    # CloudCLI - backgrounded, port-check-guarded so it isn't started twice
    # on a workspace restart. A PID-file guard doesn't work here: $HOME is
    # the persistent PVC, so a PID recorded before a restart is compared
    # against the NEW container's PID namespace, where low numbers are
    # likely to be reused by unrelated live processes - a false "already
    # running" match would silently skip starting CloudCLI, with no error.
    # A port check has no such cross-namespace ambiguity.
    #
    # HOST=127.0.0.1 (not CloudCLI's own 0.0.0.0 default) is required:
    # coder_app's proxy gates access, not the listening socket, so a
    # wildcard bind would let any other pod in the cluster reach it
    # directly (this pod runs under coder-workspace-admin/cluster-admin).
    # It also has an unauthenticated first-run account-setup endpoint
    # (until the first user registers), so an open bind is a real land
    # grab, not just defense-in-depth. Explicit PATH= on this line (rather
    # than relying on the earlier export in this same script) protects
    # against a future edit reordering these blocks.
    #
    # No process supervision if it crashes - `coder restart homelab`
    # re-runs this script and starts it again. See $HOME/.cloudcli.log
    # for troubleshooting.
    if ! curl -sf -o /dev/null "http://127.0.0.1:3001/"; then
      PATH="$HOME/.npm-global/bin:$PATH" HOST=127.0.0.1 SERVER_PORT=3001 \
        nohup cloudcli > "$HOME/.cloudcli.log" 2>&1 &
    fi
  EOT

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }
}

resource "coder_app" "cloudcli" {
  agent_id     = coder_agent.main.id
  slug         = "cloudcli"
  display_name = "CloudCLI"
  url          = "http://localhost:3001"
  icon         = "/icon/code.svg"
  share        = "owner"
  # CloudCLI's web UI loads its own JS/CSS via root-absolute paths
  # (/assets/...) with no configurable base path, so Coder's default
  # path-based app serving (https://coder.homelab.local/@user/.../apps/
  # cloudcli/) loads a blank/broken page - the browser fetches assets
  # from the wrong origin. subdomain=true serves it on its own host
  # instead (cloudcli--main--homelab--<user>.coder.homelab.local),
  # which requires CODER_WILDCARD_ACCESS_URL set on the Coder deployment
  # itself (k8s/argocd/applications/coder.yaml) - not just this template.
  subdomain = true
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-homelab-workspace-home"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "50Gi"
      }
    }
  }
}

resource "kubernetes_pod_v1" "main" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = "coder-homelab-workspace"
    namespace = local.namespace
    labels = {
      "app.kubernetes.io/part-of" = "coder"
      "com.coder.resource"        = "true"
      "com.coder.workspace.id"    = data.coder_workspace.me.id
      "com.coder.workspace.name"  = data.coder_workspace.me.name
    }
  }

  spec {
    service_account_name = "coder-workspace-admin"

    image_pull_secrets {
      name = "coder-workspace-registry-pull"
    }

    security_context {
      run_as_user     = 1000
      fs_group        = 1000
      run_as_non_root = true
    }

    container {
      name              = "dev"
      image             = local.image
      image_pull_policy = "Always"
      command           = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        run_as_user = "1000"
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name = "GITHUB_MCP_TOKEN"
        value_from {
          secret_key_ref {
            name     = "coder-secret"
            key      = "github-mcp-token"
            optional = true
          }
        }
      }

      env {
        name = "GITLAB_MCP_TOKEN"
        value_from {
          secret_key_ref {
            name     = "coder-secret"
            key      = "gitlab-mcp-token"
            optional = true
          }
        }
      }

      env {
        name = "GRAFANA_MCP_TOKEN"
        value_from {
          secret_key_ref {
            name     = "coder-secret"
            key      = "grafana-mcp-token"
            optional = true
          }
        }
      }

      env {
        name  = "SSL_CERT_FILE"
        value = "/etc/ssl/certs/homelab-ca.crt"
      }

      env {
        name  = "CURL_CA_BUNDLE"
        value = "/etc/ssl/certs/homelab-ca.crt"
      }

      env {
        name  = "NODE_EXTRA_CA_CERTS"
        value = "/etc/ssl/certs/homelab-ca.crt"
      }

      resources {
        requests = {
          cpu    = "1"
          memory = "2Gi"
        }
        limits = {
          cpu    = "4"
          memory = "8Gi"
        }
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
      }

      volume_mount {
        mount_path = "/etc/coder/ssh"
        name       = "git-ssh-key"
        read_only  = true
      }

      volume_mount {
        mount_path = "/etc/ssl/certs/homelab-ca.crt"
        name       = "homelab-ca"
        sub_path   = "homelab-ca.crt"
        read_only  = true
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata.0.name
      }
    }

    volume {
      name = "git-ssh-key"
      secret {
        secret_name  = "coder-secret"
        default_mode = "0400"
        items {
          key  = "git-ssh-private-key"
          path = "id_ed25519"
        }
      }
    }

    volume {
      name = "homelab-ca"
      secret {
        secret_name = "homelab-ca"
        items {
          key  = "homelab-ca.crt"
          path = "homelab-ca.crt"
        }
      }
    }
  }
}
