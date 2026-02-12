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

echo "==> Done!"
