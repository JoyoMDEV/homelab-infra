#!/bin/bash
set -euo pipefail

echo "==> Installing tools..."

# k9s
curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz | sudo tar xz -C /usr/local/bin k9s

# Python tools
pip install --break-system-packages --quiet ansible-core ansible-lint yamllint pre-commit

# Go tools
go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
go install golang.org/x/tools/cmd/goimports@latest

# Pre-commit hooks
pre-commit install

# Install ansible collections
cd ansible && ansible-galaxy install -r collections/requirements.yml

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ==> SSH Config: GitLab entry
echo "==> Configuring SSH for GitLab..."

SSH_CONFIG="/home/vscode/.ssh/config"
GITLAB_ENTRY="Host gitlab.homelab.local
    Port 2222
    User git
    IdentityFile ~/.ssh/id_ed25519"

# Datei anlegen falls sie noch nicht existiert
if [ ! -f "$SSH_CONFIG" ]; then
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
fi

if grep -q "gitlab.homelab.local" "$SSH_CONFIG" 2>/dev/null; then
    echo "    GitLab SSH config entry already present, skipping."
else
    # Sicherstellen dass die Datei mit einer Leerzeile endet vor dem Anhängen
    if [ -s "$SSH_CONFIG" ]; then
        echo "" >> "$SSH_CONFIG"
    fi
    echo "$GITLAB_ENTRY" >> "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
    echo "    GitLab SSH config entry added."
fi

echo "==> Done!"
