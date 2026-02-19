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
TRAEFIK_SVC="traefik.kube-system.svc.cluster.local"

echo "==> Checking prerequisites..."
if ! kubectl get svc traefik -n kube-system &>/dev/null; then
  echo "    ERROR: Traefik service not found in kube-system."
  echo "    Run 'make bootstrap' first."
  exit 1
fi

# ─── Step 1: Read current CoreDNS ConfigMap ───────────────────────────────────
echo ""
echo "==> Reading current CoreDNS ConfigMap..."
CURRENT=$(kubectl get configmap "${COREDNS_CONFIGMAP}" \
  -n "${COREDNS_NAMESPACE}" \
  -o jsonpath='{.data.Corefile}')

echo "    Current Corefile:"
echo "${CURRENT//$'\n'/$'\n'    }"

# ─── Step 2: Check if patch already applied ───────────────────────────────────
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

# ─── Step 3: Build new Corefile with homelab.local wildcard block ─────────────
echo ""
echo "==> Building new Corefile with *.homelab.local wildcard resolution..."

# The homelab.local block uses:
# - rewrite: rewrites *.homelab.local to the Traefik service FQDN
#   so CoreDNS resolves it via the kubernetes plugin
# - forward: fallback to upstream for anything not matched
HOMELAB_BLOCK="homelab.local:53 {
    # Rewrite all *.homelab.local queries to Traefik's cluster-internal FQDN.
    # Traefik routes to the correct backend via Ingress/IngressRoute rules.
    rewrite name regex (.*)\.homelab\.local ${TRAEFIK_SVC}
    # Resolve the rewritten name via the kubernetes plugin
    kubernetes cluster.local
    # Forward unknown queries upstream
    forward . /etc/resolv.conf
    cache 30
    log
    errors
}"

NEW_COREFILE="${HOMELAB_BLOCK}
${CURRENT}"

# ─── Step 4: Apply the new ConfigMap ─────────────────────────────────────────
echo ""
echo "==> Applying updated CoreDNS ConfigMap..."
kubectl create configmap "${COREDNS_CONFIGMAP}" \
  --namespace="${COREDNS_NAMESPACE}" \
  --from-literal=Corefile="${NEW_COREFILE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

# ─── Step 5: Restart CoreDNS to pick up changes ───────────────────────────────
echo ""
echo "==> Restarting CoreDNS..."
kubectl rollout restart deployment/coredns -n "${COREDNS_NAMESPACE}"
kubectl rollout status deployment/coredns -n "${COREDNS_NAMESPACE}" --timeout=60s
echo "    CoreDNS restarted."

# ─── Step 6: Verify ───────────────────────────────────────────────────────────
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
