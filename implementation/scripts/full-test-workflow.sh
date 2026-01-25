#!/bin/bash
# =============================================================================
# Full Test Workflow - Automated Baseline vs Tuned Comparison
# =============================================================================
# This script automates the entire testing workflow:
# 1. Install Argo CD with default values
# 2. Run baseline tests
# 3. Upgrade to tuned configuration
# 4. Run tuned tests
# 5. Compare results
#
# Usage: ./full-test-workflow.sh [NUM_APPS]
# Example: ./full-test-workflow.sh 50

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUM_APPS=${1:-30}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

print_banner() {
    echo ""
    echo "=============================================="
    echo "$1"
    echo "=============================================="
    echo ""
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
print_banner "PRE-FLIGHT CHECKS"

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please install kubectl."
    exit 1
fi
log_info "kubectl: OK"

# Check helm
if ! command -v helm &> /dev/null; then
    log_error "helm not found. Please install helm."
    exit 1
fi
log_info "helm: OK"

# Check cluster connection
if ! kubectl cluster-info &> /dev/null; then
    log_error "Cannot connect to Kubernetes cluster. Is your cluster running?"
    exit 1
fi
log_info "Cluster connection: OK"

# Check if Kind cluster
CONTEXT=$(kubectl config current-context)
log_info "Using context: ${CONTEXT}"

echo ""
log_info "Test configuration: ${NUM_APPS} applications"
echo ""

read -p "Ready to start full test workflow? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted."
    exit 0
fi

# =============================================================================
# Phase 1: Setup
# =============================================================================
print_banner "PHASE 1: SETUP"

# Add Helm repo
log_step "Adding Argo CD Helm repository..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# Create namespace
log_step "Creating namespaces..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace test-apps --dry-run=client -o yaml | kubectl apply -f -

# =============================================================================
# Phase 2: Baseline Testing
# =============================================================================
print_banner "PHASE 2: BASELINE TESTING (Default Config)"

# Check if Argo CD is already installed
if helm status argocd -n argocd &>/dev/null; then
    log_warn "Argo CD is already installed. Uninstalling for clean baseline..."
    helm uninstall argocd -n argocd
    sleep 10
fi

# Install with defaults
log_step "Installing Argo CD with DEFAULT configuration..."
helm install argocd argo/argo-cd \
    --namespace argocd \
    --set server.service.type=NodePort \
    --wait --timeout 5m

# Wait for pods to be ready
log_step "Waiting for all pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/part-of=argocd -n argocd --timeout=300s

log_info "Argo CD installed with default configuration"

# Show current configuration
log_step "Current configuration (should show defaults):"
kubectl get statefulset argocd-application-controller -n argocd -o jsonpath='{.spec.template.spec.containers[0].resources}' | head -c 200
echo ""

# Run baseline tests
log_step "Running baseline tests..."
export NUM_APPS
"${SCRIPT_DIR}/run-baseline-test.sh"

# =============================================================================
# Phase 3: Upgrade to Tuned Configuration
# =============================================================================
print_banner "PHASE 3: UPGRADE TO TUNED CONFIGURATION"

# Clean up test apps from baseline
log_step "Cleaning up baseline test applications..."
kubectl delete applications -n argocd -l test-suite=baseline --ignore-not-found=true
sleep 5

# Upgrade with tuned values
log_step "Upgrading Argo CD with TUNED configuration..."
helm upgrade argocd argo/argo-cd \
    --namespace argocd \
    --values "${SCRIPT_DIR}/../helm/values-performance.yaml" \
    --wait --timeout 5m

# Wait for pods to be ready
log_step "Waiting for all pods to restart with new configuration..."
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

log_info "Argo CD upgraded with tuned configuration"

# Show new configuration
log_step "New configuration (should show tuned values):"
echo "Controller args:"
kubectl get statefulset argocd-application-controller -n argocd -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | tr ',' '\n' | grep -E "processors|resync"
echo ""
echo "Repo-server emptyDir:"
kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")]}' 2>/dev/null
echo ""

# =============================================================================
# Phase 4: Tuned Testing
# =============================================================================
print_banner "PHASE 4: TUNED CONFIGURATION TESTING"

# Run tuned tests
log_step "Running tuned configuration tests..."
"${SCRIPT_DIR}/run-tuned-test.sh"

# =============================================================================
# Phase 5: Compare Results
# =============================================================================
print_banner "PHASE 5: COMPARISON"

"${SCRIPT_DIR}/compare-results.sh"

# =============================================================================
# Summary
# =============================================================================
print_banner "TEST WORKFLOW COMPLETE"

log_info "All tests completed successfully!"
echo ""
echo "Results are saved in: ${SCRIPT_DIR}/../results/"
echo ""
echo "Next steps:"
echo "  1. Review the comparison output above"
echo "  2. Check detailed JSON results in the results folder"
echo "  3. Run disk pressure simulation: ./simulate-disk-pressure.sh"
echo "  4. Clean up: ./cleanup.sh"
echo ""

# Get admin password for UI access
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null)
if [ -n "$ARGOCD_PWD" ]; then
    echo "Argo CD UI Access:"
    echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
    echo "  URL: https://localhost:8080"
    echo "  Username: admin"
    echo "  Password: ${ARGOCD_PWD}"
fi
