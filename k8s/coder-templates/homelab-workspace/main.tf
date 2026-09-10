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
        name  = "SSL_CERT_FILE"
        value = "/etc/ssl/certs/homelab-ca.crt"
      }

      env {
        name  = "CURL_CA_BUNDLE"
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
