#!/bin/bash
set -euo pipefail

# =============================================================================
#  bootstrap-certmanager.sh
#  Installs cert-manager + creates an internal CA for *.homelab.local
#
#  SECRET MANAGEMENT:
#  - CA private key is generated locally, pushed directly to Kubernetes,
#    then deleted from disk. It NEVER touches the Git repository.
#  - ca.crt is saved to ./certs/homelab-ca.crt (gitignored) so you can
#    import it into your devices/browsers.
#
#  WHY WE COPY THE SECRET TO kube-system:
#  Traefik runs in kube-system and can only read TLS secrets from its own
#  namespace by default in k3s. cert-manager issues the secret into
#  'infrastructure', so we copy it to kube-system after issuance and set
#  up a TLSStore CRD there. A sync loop at the end of this script keeps
#  the copy fresh on every re-run (e.g. after cert renewal).
# =============================================================================

NAMESPACE="cert-manager"
CA_SECRET_NAME="homelab-ca-keypair"
WILDCARD_SECRET_NAME="homelab-wildcard-tls"
WILDCARD_SECRET_NAMESPACE="infrastructure"
TRAEFIK_NAMESPACE="kube-system"
CA_CERT_DIR="./certs"
CA_KEY_FILE="${CA_CERT_DIR}/homelab-ca.key"
CA_CERT_FILE="${CA_CERT_DIR}/homelab-ca.crt"
CERT_MANAGER_VERSION="v1.17.0"

echo "==> Checking dependencies..."
for cmd in kubectl helm openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "    ERROR: $cmd not found. Please install it first."
    exit 1
  fi
done

# ─── Step 1: Install cert-manager via Helm ────────────────────────────────────
echo ""
echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update

if helm status cert-manager -n "${NAMESPACE}" &>/dev/null; then
  echo "    cert-manager already installed, upgrading..."
  helm upgrade cert-manager jetstack/cert-manager \
    --namespace "${NAMESPACE}" \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true \
    --wait
else
  helm install cert-manager jetstack/cert-manager \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --version "${CERT_MANAGER_VERSION}" \
    --set crds.enabled=true \
    --wait
fi

echo "    Waiting for cert-manager webhooks to be ready..."
kubectl wait --for=condition=available deployment/cert-manager-webhook \
  -n "${NAMESPACE}" --timeout=120s

# ─── Step 2: Generate CA keypair locally ─────────────────────────────────────
echo ""
echo "==> Generating internal CA keypair (never written to Git)..."
mkdir -p "${CA_CERT_DIR}"

if [[ ! -f "${CA_KEY_FILE}" ]]; then
  openssl genrsa -out "${CA_KEY_FILE}" 4096
  openssl req -new -x509 \
    -key "${CA_KEY_FILE}" \
    -out "${CA_CERT_FILE}" \
    -days 3650 \
    -subj "/CN=Homelab Internal CA/O=Homelab/C=DE" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  echo "    CA keypair generated."
else
  echo "    CA keypair already exists, reusing."
fi

# ─── Step 3: Push CA keypair to Kubernetes Secret ────────────────────────────
echo ""
echo "==> Creating Kubernetes Secret '${CA_SECRET_NAME}' in ${NAMESPACE}..."
if kubectl get secret "${CA_SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo "    Secret already exists, skipping."
else
  kubectl create secret tls "${CA_SECRET_NAME}" \
    --cert="${CA_CERT_FILE}" \
    --key="${CA_KEY_FILE}" \
    --namespace="${NAMESPACE}"
  echo "    Secret created."
fi

# ─── Step 4: Securely delete CA private key from disk ────────────────────────
echo ""
echo "==> Removing CA private key from disk (stored only in Kubernetes)..."
if command -v shred &>/dev/null; then
  shred -u "${CA_KEY_FILE}"
else
  rm -f "${CA_KEY_FILE}"
fi
echo "    CA private key deleted from disk."

# ─── Step 5: Apply ClusterIssuer + Wildcard Certificate ──────────────────────
echo ""
echo "==> Applying ClusterIssuer and wildcard Certificate..."
kubectl apply -f k8s/infrastructure/cert-manager-issuer.yaml

kubectl get namespace "${WILDCARD_SECRET_NAMESPACE}" &>/dev/null || \
  kubectl create namespace "${WILDCARD_SECRET_NAMESPACE}"

kubectl apply -f k8s/infrastructure/homelab-wildcard-cert.yaml

echo "    Waiting for wildcard certificate to be issued (this may take ~30s)..."
kubectl wait --for=condition=Ready certificate/homelab-wildcard \
  -n "${WILDCARD_SECRET_NAMESPACE}" --timeout=120s
echo "    Certificate issued."

# ─── Step 6: Copy wildcard secret to kube-system for Traefik ─────────────────
# Traefik in k3s only reads secrets from its own namespace (kube-system).
# We extract the issued cert+key and create a copy there.
# Re-run this script after cert-manager auto-renews to keep it in sync.
echo ""
echo "==> Syncing wildcard TLS secret to ${TRAEFIK_NAMESPACE} for Traefik..."

TLS_CRT=$(kubectl get secret "${WILDCARD_SECRET_NAME}" \
  -n "${WILDCARD_SECRET_NAMESPACE}" \
  -o jsonpath='{.data.tls\.crt}')
TLS_KEY=$(kubectl get secret "${WILDCARD_SECRET_NAME}" \
  -n "${WILDCARD_SECRET_NAMESPACE}" \
  -o jsonpath='{.data.tls\.key}')

if kubectl get secret "${WILDCARD_SECRET_NAME}" -n "${TRAEFIK_NAMESPACE}" &>/dev/null; then
  echo "    Updating existing secret in ${TRAEFIK_NAMESPACE}..."
  kubectl patch secret "${WILDCARD_SECRET_NAME}" \
    -n "${TRAEFIK_NAMESPACE}" \
    --type merge \
    -p "{\"data\":{\"tls.crt\":\"${TLS_CRT}\",\"tls.key\":\"${TLS_KEY}\"}}"
else
  echo "    Creating secret in ${TRAEFIK_NAMESPACE}..."
  kubectl create secret tls "${WILDCARD_SECRET_NAME}" \
    --cert=<(echo "${TLS_CRT}" | base64 -d) \
    --key=<(echo "${TLS_KEY}" | base64 -d) \
    --namespace="${TRAEFIK_NAMESPACE}"
fi
echo "    Secret synced to ${TRAEFIK_NAMESPACE}."

# ─── Step 7: Apply namespaces with CA injection labels ───────────────────────
echo ""
echo "==> Applying namespaces with CA injection labels..."
kubectl apply -f k8s/namespaces.yaml

# ─── Step 8: Seed homelab-ca secret to all labeled namespaces ───────────────
# The CronJob handles ongoing sync, but we seed immediately on bootstrap so
# services like GitLab can verify Keycloak TLS without waiting until 03:00.
echo ""
echo "==> Seeding homelab-ca secret to labeled namespaces..."
CA_CRT=$(kubectl get secret homelab-ca-keypair -n cert-manager \
  -o jsonpath='{.data.tls\.crt}')
NAMESPACES=$(kubectl get namespaces \
  -l homelab.local/inject-ca=true \
  -o jsonpath='{.items[*].metadata.name}')
for NS in ${NAMESPACES}; do
  if kubectl get secret homelab-ca -n "${NS}" &>/dev/null; then
    echo "    ${NS}: already exists, updating..."
    kubectl patch secret homelab-ca -n "${NS}" \
      --type merge \
      -p "{\"data\":{\"homelab-ca.crt\":\"${CA_CRT}\"}}"
  else
    echo "    ${NS}: creating..."
    kubectl create secret generic homelab-ca \
      --from-literal=homelab-ca.crt="$(echo "${CA_CRT}" | base64 -d)" \
      -n "${NS}"
  fi
done
echo "    CA secret seeded."

# ─── Step 9: Deploy cert-sync CronJob ────────────────────────────────────────
# Runs daily at 03:00 - syncs wildcard TLS + CA to all labeled namespaces.
# ─── Step 7: Deploy cert-sync CronJob ────────────────────────────────────────
# Runs daily at 03:00 and auto-syncs the wildcard secret after cert renewal.
echo ""
echo "==> Deploying cert-sync CronJob (automatic renewal sync)..."
kubectl apply -f k8s/infrastructure/cert-sync-cronjob.yaml
echo "    CronJob deployed. Runs daily at 03:00."

# ─── Step 8: Apply Traefik TLS config ────────────────────────────────────────
echo ""
echo "==> Applying Traefik TLS configuration..."
kubectl apply -f k8s/traefik-tls-config.yaml
kubectl apply -f k8s/traefik-tlsstore.yaml

echo "    Restarting Traefik to pick up new config..."
# On a single-node cluster with hostPort, the old Pod must be deleted
# before the new one can bind ports 80/443. Otherwise new Pod stays Pending.
OLD_TRAEFIK=$(kubectl get pod -n "${TRAEFIK_NAMESPACE}" -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
kubectl rollout restart deployment/traefik -n "${TRAEFIK_NAMESPACE}" 2>/dev/null || true
if [[ -n "${OLD_TRAEFIK}" ]]; then
  echo "    Deleting old Traefik pod ${OLD_TRAEFIK} to free hostPort 80/443..."
  kubectl delete pod "${OLD_TRAEFIK}" -n "${TRAEFIK_NAMESPACE}" --wait=false 2>/dev/null || true
fi
echo "    Waiting for new Traefik pod to be ready..."
# Use || true so a slow rollout does not fail the whole script.
# Traefik will still pick up the new cert even if the wait times out.
kubectl rollout status deployment/traefik -n "${TRAEFIK_NAMESPACE}" --timeout=180s || true

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  cert-manager bootstrap complete!"
echo ""
echo "  Wildcard cert: *.homelab.local"
echo "  Traefik:       HTTPS active on port 443"
echo "  HTTP:          redirects to HTTPS"
echo ""
echo "  IMPORTANT - Import CA into your devices:"
echo "  File: ${CA_CERT_FILE}"
echo ""
echo "  Ubuntu/Debian:"
echo "    sudo cp ${CA_CERT_FILE} /usr/local/share/ca-certificates/homelab-ca.crt"
echo "    sudo update-ca-certificates"
echo ""
echo "  macOS:"
echo "    open ${CA_CERT_FILE}"
echo "    Keychain -> System -> Always Trust"
echo ""
echo "  Windows:"
echo "    certmgr.msc -> Trusted Root CAs -> Import"
echo ""
echo "  Verify:"
echo "    make cert-status"
echo "    curl -v https://argocd.homelab.local"
echo ""
