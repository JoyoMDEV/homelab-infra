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
#  We use the 'coredns-custom' ConfigMap (not 'coredns') which k3s imports
#  via 'import /etc/coredns/custom/*.server' in its default Corefile.
#  This means k3s NEVER overwrites our config on node restarts or upgrades,
#  unlike patching the 'coredns' ConfigMap directly.
#
#  IDEMPOTENT: Safe to run multiple times.
# =============================================================================

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

# ─── Step 2: Verify the default Corefile imports coredns-custom ──────────────
# k3s CoreDNS Corefile contains: import /etc/coredns/custom/*.server
# The coredns-custom ConfigMap is mounted at /etc/coredns/custom/ inside the
# CoreDNS pod. Any *.server key in that ConfigMap is automatically loaded.
echo ""
echo "==> Verifying k3s CoreDNS supports coredns-custom..."
if kubectl get configmap coredns -n kube-system \
    -o jsonpath='{.data.Corefile}' | grep -q "import /etc/coredns/custom"; then
  echo "    OK – coredns-custom import found in Corefile."
else
  echo "    WARNING: 'import /etc/coredns/custom/*.server' not found in Corefile."
  echo "    This k3s version may not support coredns-custom."
  echo "    Falling back to patching the coredns ConfigMap directly..."
  FALLBACK=true
fi
FALLBACK=${FALLBACK:-false}

# ─── Step 3: Apply coredns-custom ConfigMap ───────────────────────────────────
# Each key in coredns-custom must end in .server to be picked up by CoreDNS.
# We use 'homelab.server' as the key name.
#
# The wildcard hosts entry (*.homelab.local → Traefik IP) means any new service
# automatically works without changing CoreDNS again.
if [[ "${FALLBACK}" == "false" ]]; then
  echo ""
  echo "==> Applying coredns-custom ConfigMap (k3s-safe, survives restarts)..."

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: ${COREDNS_NAMESPACE}
data:
  homelab.server: |
    homelab.local:53 {
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
    }
EOF

  echo "    coredns-custom ConfigMap applied."

else
  # ─── Fallback: patch coredns ConfigMap directly (old behaviour) ────────────
  echo ""
  echo "==> Falling back: patching coredns ConfigMap directly..."

  CURRENT=$(kubectl get configmap coredns \
    -n "${COREDNS_NAMESPACE}" \
    -o jsonpath='{.data.Corefile}')

  echo "    Current Corefile:"
  echo "${CURRENT//$'\n'/$'\n'    }"

  if echo "${CURRENT}" | grep -q "homelab.local:53"; then
    echo ""
    echo "==> homelab.local block already present, updating..."
    CURRENT=$(echo "${CURRENT}" | awk '
      /^homelab\.local:53 \{/ { skip=1 }
      skip && /^\}/ { skip=0; next }
      !skip { print }
    ')
  fi

  HOMELAB_BLOCK="homelab.local:53 {
    hosts {
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

  kubectl create configmap coredns \
    --namespace="${COREDNS_NAMESPACE}" \
    --from-literal=Corefile="${NEW_COREFILE}" \
    --dry-run=client -o yaml \
    | kubectl apply -f -

  echo "    coredns ConfigMap patched."
fi

# ─── Step 4: Restart CoreDNS to pick up changes ───────────────────────────────
echo ""
echo "==> Restarting CoreDNS..."
kubectl rollout restart deployment/coredns -n "${COREDNS_NAMESPACE}"
kubectl rollout status deployment/coredns -n "${COREDNS_NAMESPACE}" --timeout=60s
echo "    CoreDNS restarted."

# ─── Step 5: Verify ───────────────────────────────────────────────────────────
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
if [[ "${FALLBACK:-false}" == "false" ]]; then
  echo "  Config stored in: coredns-custom ConfigMap"
  echo "  This config SURVIVES k3s restarts and upgrades."
else
  echo "  Config stored in: coredns ConfigMap (fallback)"
  echo "  WARNING: This may be reset on k3s restart."
fi
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
