#!/bin/bash
# =============================================================================
# Simulate Disk Pressure on Repo-Server
# =============================================================================
# This script fills up the repo-server /tmp to simulate disk pressure
#
# With DEFAULT config: This will cause pod eviction
# With TUNED config (emptyDir sizeLimit): This will fail gracefully

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=============================================="
echo "       DISK PRESSURE SIMULATION"
echo "=============================================="
echo ""

# Get repo-server pod
REPO_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$REPO_POD" ]; then
    log_error "Repo-server pod not found. Is Argo CD installed?"
    exit 1
fi

log_info "Using pod: ${REPO_POD}"

# Check current configuration
VOLUME_CONFIG=$(kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")].emptyDir.sizeLimit}' 2>/dev/null)

if [ -n "$VOLUME_CONFIG" ]; then
    log_info "EmptyDir sizeLimit configured: ${VOLUME_CONFIG}"
    log_info "Disk pressure will be limited by sizeLimit (tuned config)"
else
    log_warn "No sizeLimit configured (default config)"
    log_warn "This may cause pod eviction!"
fi

echo ""

# Show initial disk usage
log_info "Initial disk usage:"
kubectl exec -n argocd ${REPO_POD} -- df -h /tmp
echo ""

# Confirm before proceeding
read -p "Proceed with disk pressure simulation? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted."
    exit 0
fi

# Create files to fill disk
log_info "Creating large files in /tmp..."

# Start monitoring in background
kubectl get events -n argocd --watch &
EVENTS_PID=$!

# Create files (500MB each)
for i in 1 2 3 4 5 6 7 8; do
    log_info "Creating file ${i} (500MB)..."
    if kubectl exec -n argocd ${REPO_POD} -- dd if=/dev/zero of=/tmp/testfile${i} bs=1M count=500 2>/dev/null; then
        log_info "File ${i} created successfully"
    else
        log_warn "File ${i} creation failed (likely hit sizeLimit - this is expected with tuned config)"
        break
    fi

    # Show current usage
    kubectl exec -n argocd ${REPO_POD} -- df -h /tmp 2>/dev/null || log_warn "Pod may have been evicted"

    # Check if pod is still running
    POD_STATUS=$(kubectl get pod -n argocd ${REPO_POD} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Terminated")
    if [ "$POD_STATUS" != "Running" ]; then
        log_error "Pod is no longer running! Status: ${POD_STATUS}"
        break
    fi

    sleep 2
done

# Stop event monitoring
kill $EVENTS_PID 2>/dev/null || true

echo ""
echo "=============================================="
echo "              RESULTS"
echo "=============================================="

# Check final state
REPO_POD_NEW=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ "$REPO_POD" != "$REPO_POD_NEW" ]; then
    log_error "Pod was replaced! Original: ${REPO_POD}, New: ${REPO_POD_NEW}"
    log_error "This indicates pod eviction due to disk pressure (DEFAULT config behavior)"
else
    log_info "Pod survived disk pressure test"
    if [ -n "$VOLUME_CONFIG" ]; then
        log_info "EmptyDir sizeLimit prevented excessive disk usage (TUNED config)"
    fi
fi

# Show events
echo ""
log_info "Recent events:"
kubectl get events -n argocd --sort-by='.lastTimestamp' | tail -10

# Cleanup
echo ""
read -p "Clean up test files? (Y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    log_info "Cleaning up test files..."
    CURRENT_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$CURRENT_POD" ]; then
        kubectl exec -n argocd ${CURRENT_POD} -- sh -c 'rm -f /tmp/testfile*' 2>/dev/null || true
        log_info "Cleanup complete"
    fi
fi

echo ""
log_info "Disk pressure simulation complete!"
