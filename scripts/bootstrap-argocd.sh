#!/bin/bash
set -euo pipefail

echo "==> Creating namespaces..."
kubectl apply -f k8s/namespaces.yaml

echo "==> Configuring Traefik (hostPort 80/443)..."
kubectl apply -f k8s/infrastructure/traefik-config.yaml
echo "    Waiting for Traefik to restart..."
sleep 15

echo "==> Installing ArgoCD via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --values k8s/values/argocd.yaml \
  --wait

echo "==> Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=300s

echo "==> Ensuring Ingress host is correct..."
kubectl patch ingress argocd-server -n argocd --type merge \
  -p '{"spec":{"rules":[{"host":"argocd.homelab.local","http":{"paths":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"argocd-server","port":{"number":80}}}}]}}]}}' \
  2>/dev/null || true

echo "==> Getting initial admin password..."
ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo ""
echo "============================================"
echo "  ArgoCD is ready!"
echo "  URL: https://argocd.homelab.local"
echo "  User: admin"
echo "  Password: ${ARGOCD_PW}"
echo "============================================"
echo ""

echo "==> Applying root application (App-of-Apps)..."
kubectl apply -f k8s/argocd/root.yaml

echo "==> Done! ArgoCD will now sync all applications from Git."
echo "    Check status: kubectl get applications -n argocd"
