#!/bin/bash
# =============================================================================
# Apply Disk Pressure Fix (emptyDir sizeLimit)
# =============================================================================
# The Argo CD Helm chart doesn't support emptyDir sizeLimit directly.
# This script patches the repo-server deployment to add sizeLimit to /tmp.
#
# Run this AFTER installing Argo CD with Helm.

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

NAMESPACE="${NAMESPACE:-argocd}"
SIZE_LIMIT="${SIZE_LIMIT:-4Gi}"

echo "=============================================="
echo "      APPLYING DISK PRESSURE FIX"
echo "=============================================="
echo ""
echo "Namespace: ${NAMESPACE}"
echo "Size Limit: ${SIZE_LIMIT}"
echo ""

# Check if deployment exists
if ! kubectl get deployment argocd-repo-server -n ${NAMESPACE} &>/dev/null; then
    log_warn "argocd-repo-server deployment not found in namespace ${NAMESPACE}"
    exit 1
fi

# Show current volume configuration
log_info "Current /tmp volume configuration:"
kubectl get deployment argocd-repo-server -n ${NAMESPACE} \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")]}'
echo ""
echo ""

# Find the index of the tmp volume
TMP_INDEX=$(kubectl get deployment argocd-repo-server -n ${NAMESPACE} \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | grep -n "^tmp$" | cut -d: -f1)

if [ -z "$TMP_INDEX" ]; then
    log_warn "Could not find 'tmp' volume. Volumes available:"
    kubectl get deployment argocd-repo-server -n ${NAMESPACE} \
      -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}'
    exit 1
fi

# Adjust for 0-based index
TMP_INDEX=$((TMP_INDEX - 1))
log_info "Found 'tmp' volume at index: ${TMP_INDEX}"

# Apply patch
log_info "Applying sizeLimit patch..."
kubectl patch deployment argocd-repo-server -n ${NAMESPACE} --type='json' -p="[
  {\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/${TMP_INDEX}/emptyDir\", \"value\": {\"sizeLimit\": \"${SIZE_LIMIT}\"}}
]"

# Wait for rollout
log_info "Waiting for repo-server to restart..."
kubectl rollout status deployment/argocd-repo-server -n ${NAMESPACE} --timeout=120s

# Verify the fix
log_info "Verifying fix applied:"
kubectl get deployment argocd-repo-server -n ${NAMESPACE} \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")]}'
echo ""
echo ""

# Wait for new pod to be ready, then check disk usage
log_info "Waiting for new pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n ${NAMESPACE} --timeout=120s

# Get the NEW pod name after rollout
REPO_POD=$(kubectl get pod -n ${NAMESPACE} -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
log_info "Disk usage in new pod (${REPO_POD}):"
kubectl exec -n ${NAMESPACE} ${REPO_POD} -- df -h /tmp

echo ""
echo "=============================================="
echo "      DISK PRESSURE FIX APPLIED"
echo "=============================================="
echo ""
echo "The /tmp volume now has a sizeLimit of ${SIZE_LIMIT}."
echo "This prevents disk exhaustion and pod eviction."
echo ""
