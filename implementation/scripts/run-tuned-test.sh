#!/bin/bash
# =============================================================================
# Tuned Test Script (Performance-Tuned Argo CD Configuration)
# =============================================================================
# This script:
# 1. Verifies Argo CD is running with tuned config
# 2. Creates test applications
# 3. Runs load tests
# 4. Collects metrics
# 5. Saves results to tuned-results.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_FILE="${RESULTS_DIR}/tuned-${TIMESTAMP}.json"
NUM_APPS=${NUM_APPS:-30}
TEST_NAMESPACE="test-apps"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# Setup
# =============================================================================
mkdir -p "${RESULTS_DIR}"

log_info "Starting Tuned Configuration Test Suite"
log_info "Number of test apps: ${NUM_APPS}"
log_info "Results will be saved to: ${RESULTS_FILE}"

# Check Argo CD is running
if ! kubectl get namespace argocd &>/dev/null; then
    log_error "Argo CD namespace not found. Please install Argo CD first."
    exit 1
fi

# Verify tuned configuration is applied
log_info "Verifying tuned configuration..."

OPERATION_PROCESSORS=$(kubectl get statefulset argocd-application-controller -n argocd -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o 'operation-processors=[0-9]*' || echo "not-found")
if [[ "$OPERATION_PROCESSORS" == "not-found" ]]; then
    log_warn "Could not verify tuned config. Make sure you've upgraded with values-performance.yaml"
else
    log_info "Found config: ${OPERATION_PROCESSORS}"
fi

# Create test namespace if not exists
kubectl create namespace ${TEST_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Clean up any existing baseline test apps
log_info "Cleaning up previous test applications..."
kubectl delete applications -n argocd -l test-suite=baseline --ignore-not-found=true
kubectl delete applications -n argocd -l test-suite=tuned --ignore-not-found=true
sleep 5

# Initialize results JSON
cat > "${RESULTS_FILE}" <<EOF
{
  "test_type": "tuned",
  "timestamp": "${TIMESTAMP}",
  "num_apps": ${NUM_APPS},
  "config": "performance-tuned",
  "tests": {}
}
EOF

# =============================================================================
# Test 1: Sync Performance (Burst Creation)
# =============================================================================
log_info "Test 1: Sync Performance - Creating ${NUM_APPS} applications..."

START_TIME=$(date +%s)

for i in $(seq 1 ${NUM_APPS}); do
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tuned-app-${i}
  namespace: argocd
  labels:
    test-suite: tuned
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: ${TEST_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
done

log_info "Waiting for all apps to sync..."

# Wait for apps to sync (max 5 minutes)
TIMEOUT=300
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    SYNCED=$(kubectl get applications -n argocd -l test-suite=tuned -o jsonpath='{.items[?(@.status.sync.status=="Synced")].metadata.name}' | wc -w | tr -d ' ')
    if [ "$SYNCED" -ge "$NUM_APPS" ]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -ne "\r  Synced: ${SYNCED}/${NUM_APPS} (${ELAPSED}s elapsed)"
done
echo ""

END_TIME=$(date +%s)
SYNC_DURATION=$((END_TIME - START_TIME))

log_info "Sync completed in ${SYNC_DURATION} seconds"

# Count sync statuses
SYNCED_COUNT=$(kubectl get applications -n argocd -l test-suite=tuned -o jsonpath='{.items[?(@.status.sync.status=="Synced")].metadata.name}' | wc -w | tr -d ' ')
FAILED_COUNT=$(kubectl get applications -n argocd -l test-suite=tuned -o jsonpath='{.items[?(@.status.sync.status!="Synced")].metadata.name}' | wc -w | tr -d ' ')

# =============================================================================
# Test 2: Resource Usage
# =============================================================================
log_info "Test 2: Collecting resource usage..."

# Get pod resource usage (if metrics-server is installed)
if kubectl top pods -n argocd &>/dev/null; then
    REPO_SERVER_CPU=$(kubectl top pods -n argocd -l app.kubernetes.io/name=argocd-repo-server --no-headers | awk '{print $2}' | head -1)
    REPO_SERVER_MEM=$(kubectl top pods -n argocd -l app.kubernetes.io/name=argocd-repo-server --no-headers | awk '{print $3}' | head -1)
    CONTROLLER_CPU=$(kubectl top pods -n argocd -l app.kubernetes.io/name=argocd-application-controller --no-headers | awk '{print $2}' | head -1)
    CONTROLLER_MEM=$(kubectl top pods -n argocd -l app.kubernetes.io/name=argocd-application-controller --no-headers | awk '{print $3}' | head -1)
else
    log_warn "metrics-server not available, skipping resource metrics"
    REPO_SERVER_CPU="N/A"
    REPO_SERVER_MEM="N/A"
    CONTROLLER_CPU="N/A"
    CONTROLLER_MEM="N/A"
fi

# =============================================================================
# Test 3: Disk Usage
# =============================================================================
log_info "Test 3: Checking repo-server disk usage..."

REPO_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
DISK_USAGE=$(kubectl exec -n argocd ${REPO_POD} -- df -h /tmp | tail -1 | awk '{print $5}')

# Check if emptyDir sizeLimit is applied
VOLUME_CONFIG=$(kubectl get deployment argocd-repo-server -n argocd -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")].emptyDir.sizeLimit}' 2>/dev/null || echo "not-configured")

log_info "Repo-server /tmp usage: ${DISK_USAGE}"
log_info "EmptyDir sizeLimit: ${VOLUME_CONFIG}"

# =============================================================================
# Test 4: Pod Restarts
# =============================================================================
log_info "Test 4: Checking pod restart counts..."

REPO_RESTARTS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
CONTROLLER_RESTARTS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')

# =============================================================================
# Test 5: Trigger Re-sync Burst
# =============================================================================
log_info "Test 5: Triggering re-sync burst..."

RESYNC_START=$(date +%s)

for i in $(seq 1 ${NUM_APPS}); do
    kubectl patch application tuned-app-${i} -n argocd --type merge \
        -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' &
done
wait

# Wait for re-syncs
sleep 30

RESYNC_END=$(date +%s)
RESYNC_DURATION=$((RESYNC_END - RESYNC_START))

# =============================================================================
# Collect Prometheus Metrics (if available)
# =============================================================================
log_info "Collecting controller metrics..."

CONTROLLER_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].metadata.name}')

# Try to get workqueue depth
QUEUE_DEPTH=$(kubectl exec -n argocd ${CONTROLLER_POD} -- sh -c 'curl -s localhost:8082/metrics 2>/dev/null | grep "workqueue_depth{" | head -1 | awk "{print \$2}"' 2>/dev/null || echo "N/A")

# =============================================================================
# Save Results
# =============================================================================
log_info "Saving results..."

cat > "${RESULTS_FILE}" <<EOF
{
  "test_type": "tuned",
  "timestamp": "${TIMESTAMP}",
  "num_apps": ${NUM_APPS},
  "config": "performance-tuned",
  "results": {
    "sync_test": {
      "duration_seconds": ${SYNC_DURATION},
      "apps_synced": ${SYNCED_COUNT},
      "apps_failed": ${FAILED_COUNT}
    },
    "resync_test": {
      "duration_seconds": ${RESYNC_DURATION}
    },
    "resource_usage": {
      "repo_server_cpu": "${REPO_SERVER_CPU}",
      "repo_server_memory": "${REPO_SERVER_MEM}",
      "controller_cpu": "${CONTROLLER_CPU}",
      "controller_memory": "${CONTROLLER_MEM}"
    },
    "disk_usage": {
      "repo_server_tmp": "${DISK_USAGE}",
      "emptydir_sizelimit": "${VOLUME_CONFIG}"
    },
    "pod_restarts": {
      "repo_server": ${REPO_RESTARTS},
      "controller": ${CONTROLLER_RESTARTS}
    },
    "queue_depth": "${QUEUE_DEPTH}"
  }
}
EOF

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
echo "      TUNED CONFIGURATION TEST RESULTS"
echo "=============================================="
echo ""
echo "Sync Performance:"
echo "  - Duration: ${SYNC_DURATION} seconds"
echo "  - Synced: ${SYNCED_COUNT}/${NUM_APPS}"
echo "  - Failed: ${FAILED_COUNT}"
echo ""
echo "Re-sync Burst:"
echo "  - Duration: ${RESYNC_DURATION} seconds"
echo ""
echo "Resource Usage:"
echo "  - Repo-server CPU: ${REPO_SERVER_CPU}"
echo "  - Repo-server Memory: ${REPO_SERVER_MEM}"
echo "  - Controller CPU: ${CONTROLLER_CPU}"
echo "  - Controller Memory: ${CONTROLLER_MEM}"
echo ""
echo "Disk Usage:"
echo "  - Repo-server /tmp: ${DISK_USAGE}"
echo "  - EmptyDir sizeLimit: ${VOLUME_CONFIG}"
echo ""
echo "Pod Restarts:"
echo "  - Repo-server: ${REPO_RESTARTS}"
echo "  - Controller: ${CONTROLLER_RESTARTS}"
echo ""
echo "Queue Depth: ${QUEUE_DEPTH}"
echo ""
echo "Results saved to: ${RESULTS_FILE}"
echo "=============================================="

log_info "Tuned configuration test complete!"
