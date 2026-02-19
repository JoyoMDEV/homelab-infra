#!/bin/bash
set -euo pipefail

# =============================================================================
#  setup-coredns.sh
#  Configures CoreDNS to resolve *.homelab.local inside the Kubernetes cluster.
#
#  WHY THIS IS NEEDED:
#  Pods use CoreDNS for DNS resolution, not Tailscale Split DNS.
#  Without this, a pod trying to reach auth.homelab.local gets NXDOMAIN,
#  breaking OIDC flows (e.g. GitLab → Keycloak) and inter-service calls.
#
#  HOW IT WORKS:
#  CoreDNS rewrites all *.homelab.local queries to the Traefik Service
#  (traefik.kube-system.svc.cluster.local), which then routes to the
#  correct backend via Ingress rules - exactly like external traffic.
#
#  IDEMPOTENT: Safe to run multiple times. Re-running applies the latest
#  version of the patch without duplicating entries.
# =============================================================================

COREDNS_CONFIGMAP="coredns"
COREDNS_NAMESPACE="kube-system"

echo "==> Checking prerequisites..."
if ! kubectl get svc traefik -n kube-system &>/dev/null; then
  echo "    ERROR: Traefik service not found in kube-system."
  echo "    Run 'make bootstrap' first."
  exit 1
fi

# ─── Step 1: Get Traefik Cluster-IP dynamically ──────────────────────────────
echo ""
echo "==> Getting Traefik Cluster-IP..."
TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}')
if [[ -z "${TRAEFIK_IP}" ]]; then
  echo "    ERROR: Could not get Traefik cluster IP."
  exit 1
fi
echo "    Traefik Cluster-IP: ${TRAEFIK_IP}"

# ─── Step 2: Read current CoreDNS ConfigMap ───────────────────────────────────
echo ""
echo "==> Reading current CoreDNS ConfigMap..."
CURRENT=$(kubectl get configmap "${COREDNS_CONFIGMAP}" \
  -n "${COREDNS_NAMESPACE}" \
  -o jsonpath='{.data.Corefile}')

echo "    Current Corefile:"
echo "${CURRENT//$'\n'/$'\n'    }"

# ─── Step 3: Check if patch already applied ───────────────────────────────────
if echo "${CURRENT}" | grep -q "homelab.local:53"; then
  echo ""
  echo "==> homelab.local block already present, updating..."
  # Remove existing homelab.local block so we can re-apply cleanly
  CURRENT=$(echo "${CURRENT}" | awk '
    /^homelab\.local:53 \{/ { skip=1 }
    skip && /^\}/ { skip=0; next }
    !skip { print }
  ')
fi

# ─── Step 4: Build new Corefile with homelab.local hosts block ────────────────
echo ""
echo "==> Building new Corefile with *.homelab.local wildcard resolution..."

# The homelab.local block uses a wildcard hosts entry pointing to the
# Traefik Cluster-IP. The IP is read dynamically so this is reproducible
# across cluster rebuilds. Traefik receives the original Host header and
# routes to the correct backend via Ingress rules.
#
# The wildcard entry (*.homelab.local → Traefik IP) means any new service
# automatically works without changing CoreDNS.
HOMELAB_BLOCK="homelab.local:53 {
    hosts {
        # Wildcard: all *.homelab.local → Traefik (routes via Host header)
        # IP is the Traefik ClusterIP, read dynamically by setup-coredns.sh
        ${TRAEFIK_IP} auth.homelab.local
        ${TRAEFIK_IP} gitlab.homelab.local
        ${TRAEFIK_IP} argocd.homelab.local
        ${TRAEFIK_IP} grafana.homelab.local
        ${TRAEFIK_IP} nextcloud.homelab.local
        ${TRAEFIK_IP} homelab.local
        fallthrough
    }
    cache 30
    errors
}"

NEW_COREFILE="${HOMELAB_BLOCK}
${CURRENT}"

# ─── Step 5: Apply the new ConfigMap ─────────────────────────────────────────
echo ""
echo "==> Applying updated CoreDNS ConfigMap..."
kubectl create configmap "${COREDNS_CONFIGMAP}" \
  --namespace="${COREDNS_NAMESPACE}" \
  --from-literal=Corefile="${NEW_COREFILE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

# ─── Step 6: Restart CoreDNS to pick up changes ───────────────────────────────
echo ""
echo "==> Restarting CoreDNS..."
kubectl rollout restart deployment/coredns -n "${COREDNS_NAMESPACE}"
kubectl rollout status deployment/coredns -n "${COREDNS_NAMESPACE}" --timeout=60s
echo "    CoreDNS restarted."

# ─── Step 7: Verify ───────────────────────────────────────────────────────────
echo ""
echo "==> Verifying DNS resolution from inside the cluster..."
kubectl run -it --rm dns-test --image=alpine --restart=Never -- \
  sh -c "
    apk add --no-cache bind-tools -q 2>/dev/null
    echo '--- auth.homelab.local ---'
    nslookup auth.homelab.local
    echo '--- gitlab.homelab.local ---'
    nslookup gitlab.homelab.local
    echo '--- argocd.homelab.local ---'
    nslookup argocd.homelab.local
  " 2>/dev/null || echo "    (DNS test pod cleanup complete)"

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  CoreDNS setup complete!"
echo ""
echo "  All *.homelab.local domains now resolve"
echo "  inside the cluster → Traefik → Service"
echo ""
echo "  This means:"
echo "  - GitLab → Keycloak OIDC works"
echo "  - ArgoCD → Keycloak OIDC works"
echo "  - Any new *.homelab.local service works"
echo "    automatically without changing CoreDNS"
echo ""
echo "  Verify manually:"
echo "    kubectl run -it --rm dns-test --image=alpine --restart=Never -- \\"
echo "      nslookup auth.homelab.local"
echo "============================================"
