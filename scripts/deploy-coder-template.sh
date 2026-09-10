#!/bin/bash
set -euo pipefail

# =============================================================================
#  deploy-coder-template.sh
#  Pushes the Terraform-defined Coder workspace template
#  (k8s/coder-templates/homelab-workspace/) to the running Coder instance.
#  Coder templates aren't native Kubernetes resources ArgoCD can sync
#  directly, so this stays a manual/scripted step - matching this repo's
#  scripts/setup-<service>.sh convention.
#
#  VORAUSSETZUNGEN:
#  - coder CLI installiert (https://coder.com/docs/install/cli)
#  - Eingeloggt: coder login https://coder.homelab.local
#
#  USAGE:
#    ./scripts/deploy-coder-template.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/k8s/coder-templates/homelab-workspace"

echo "==> Pushing Coder template from ${TEMPLATE_DIR}..."
coder templates push homelab-workspace \
  --directory "${TEMPLATE_DIR}" \
  --yes

echo "==> Setting default autostop TTL..."
coder templates edit homelab-workspace --default-ttl 0h

echo "    Template gepusht. Workspace erstellen mit:"
echo "      coder create --template homelab-workspace <workspace-name>"
