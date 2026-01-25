#!/bin/bash
# =============================================================================
# Cleanup Script - Remove Test Resources
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo "=============================================="
echo "           CLEANUP TEST RESOURCES"
echo "=============================================="
echo ""

# Delete test applications
log_info "Deleting test applications..."
kubectl delete applications -n argocd -l test-suite=baseline --ignore-not-found=true
kubectl delete applications -n argocd -l test-suite=tuned --ignore-not-found=true

# Delete test namespace resources
log_info "Cleaning up test namespace..."
kubectl delete all --all -n test-apps --ignore-not-found=true 2>/dev/null || true

# Optional: Full reset
read -p "Do you want to completely uninstall Argo CD? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_warn "Uninstalling Argo CD..."
    helm uninstall argocd -n argocd 2>/dev/null || true
    kubectl delete namespace argocd --ignore-not-found=true
    kubectl delete namespace test-apps --ignore-not-found=true
    log_info "Argo CD uninstalled"
fi

# Optional: Delete Kind cluster
read -p "Do you want to delete the Kind cluster? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_warn "Deleting Kind cluster..."
    kind delete cluster --name argocd-perf-test 2>/dev/null || true
    log_info "Kind cluster deleted"
fi

echo ""
log_info "Cleanup complete!"
