#!/bin/bash
set -euo pipefail

NAMESPACE="automation"
SECRET_NAME="renovate-secret"

echo ""
echo "============================================"
echo "  Renovate Bot – Secret Setup"
echo "============================================"
echo ""

if ! kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  kubectl create namespace "${NAMESPACE}"
fi

echo "==> GitHub Fine-grained Personal Access Token"
echo "    Berechtigungen für JoyoMDEV/homelab-infra:"
echo "      Contents:      Read and Write"
echo "      Pull requests: Read and Write"
echo ""
read -rsp "    Token eingeben (wird nicht angezeigt): " GITHUB_TOKEN
echo ""

if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "FEHLER: Kein Token angegeben."
  exit 1
fi

if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
fi

# RENOVATE_TOKEN ist der Key den Renovate via existingSecret erwartet
kubectl create secret generic "${SECRET_NAME}" \
  --from-literal=RENOVATE_TOKEN="${GITHUB_TOKEN}" \
  -n "${NAMESPACE}"

echo "Secret erstellt mit Key: RENOVATE_TOKEN"
echo ""
echo "Nächster Schritt – manuellen Lauf triggern:"
echo "  kubectl create job renovate-test-\$(date +%s) --from=cronjob/renovate -n ${NAMESPACE}"
