#!/bin/bash
set -euo pipefail

echo "==> Creating namespaces..."
kubectl apply -f k8s/namespaces.yaml

echo "==> Configuring Traefik (hostPort 80/443)..."
kubectl apply -f k8s/traefik-config.yaml
echo "    Waiting for Traefik to restart..."
sleep 15

echo "==> Creating infrastructure secrets..."
if ! kubectl get secret redis-secret -n infrastructure &>/dev/null; then
  REDIS_PW=$(openssl rand -base64 24)
  kubectl create secret generic redis-secret \
    --from-literal=redis-password="$REDIS_PW" \
    -n infrastructure
  echo "    Redis secret created"
  echo "    Redis password: $REDIS_PW"
  echo "    (Save this somewhere safe!)"
else
  echo "    Redis secret already exists, skipping"
fi

echo "==> Installing CloudNativePG Operator..."
helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo update
if helm status cnpg-operator -n infrastructure &>/dev/null; then
  echo "    CNPG operator already installed, upgrading..."
  helm upgrade cnpg-operator cnpg/cloudnative-pg \
    --namespace infrastructure --wait
else
  echo "    Installing CNPG operator..."
  helm install cnpg-operator cnpg/cloudnative-pg \
    --namespace infrastructure --create-namespace --wait
fi

echo "==> Waiting for CNPG CRDs to be ready..."
kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=60s

echo "==> Applying PostgreSQL cluster..."
kubectl apply -f k8s/infrastructure/postgres-cluster.yaml

echo "==> Installing ArgoCD via Helm..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
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

echo "==> Applying root application (App-of-Apps)..."
kubectl apply -f k8s/argocd/root.yaml

echo ""
echo "============================================"
echo "  Bootstrap complete!"
echo ""
echo "  ArgoCD:    http://argocd.homelab.local"
echo "  User:      admin"
echo "  Password:  ${ARGOCD_PW}"
echo ""
echo "  PostgreSQL: homelab-pg.infrastructure"
echo "  Redis:      redis-master.infrastructure"
echo "============================================"
echo ""
echo "  Check status:"
echo "    make apps"
echo "    kubectl get pods -n infrastructure"
echo "    kubectl get cluster -n infrastructure"
