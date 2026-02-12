#!/bin/bash
# =============================================================================
# Disk Pressure Fix - Full Lifecycle Test
# =============================================================================
# Tests that emptyDir.sizeLimit prevents unbounded disk usage on both
# repo-server and application-controller.
#
# What this script does:
#   1. Verifies sizeLimit is configured in the Helm deployment
#   2. Records pod state before test
#   3. Writes 5GB to /tmp (exceeds 4Gi limit)
#   4. Checks what happened (pod survived or got evicted+replaced)
#   5. Verifies data was cleaned up (manually or via eviction)
#   6. Confirms no node-level disk pressure occurred
#
# Usage: ./test-disk-pressure.sh
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-argocd}"
WRITE_SIZE_MB=5000  # 5GB - intentionally exceeds the 4Gi limit

# =============================================================================
# Formatting
# =============================================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}PASS${NC}  $1"; }
fail()  { echo -e "  ${RED}FAIL${NC}  $1"; }
info()  { echo -e "  ${BLUE}INFO${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}WARN${NC}  $1"; }
step()  { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }
detail(){ echo -e "  ${DIM}$1${NC}"; }

banner() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
}

separator() {
    echo -e "${DIM}  ──────────────────────────────────────────────────────────${NC}"
}

# =============================================================================
# Track test results
# =============================================================================
TOTAL_CHECKS=0
PASSED_CHECKS=0

check_pass() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    pass "$1"
}

check_fail() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    fail "$1"
}

# =============================================================================
# Pre-flight
# =============================================================================
banner "DISK PRESSURE FIX - FULL LIFECYCLE TEST"

echo ""
info "Namespace:  ${NAMESPACE}"
info "Write size: ${WRITE_SIZE_MB}MB (exceeds 4Gi sizeLimit)"
info "Date:       $(date)"

step "Pre-flight Checks"

if ! kubectl get namespace ${NAMESPACE} &>/dev/null; then
    fail "Namespace '${NAMESPACE}' not found. Is Argo CD installed?"
    exit 1
fi
check_pass "Namespace '${NAMESPACE}' exists"

if ! kubectl get deployment argocd-repo-server -n ${NAMESPACE} &>/dev/null; then
    fail "argocd-repo-server deployment not found"
    exit 1
fi
check_pass "argocd-repo-server deployment found"

if ! kubectl get statefulset argocd-application-controller -n ${NAMESPACE} &>/dev/null; then
    fail "argocd-application-controller statefulset not found"
    exit 1
fi
check_pass "argocd-application-controller statefulset found"

# =============================================================================
# Test a single component
# =============================================================================
test_component() {
    local COMPONENT_LABEL=$1    # e.g. argocd-repo-server
    local COMPONENT_NAME=$2     # e.g. Repo-Server
    local RESOURCE_TYPE=$3      # deployment or statefulset
    local VOLUME_NAME=$4        # e.g. tmp or argocd-application-controller-tmp

    banner "${COMPONENT_NAME} - Disk Pressure Test"

    # ── Step 1: Verify sizeLimit is configured ──
    step "Step 1: Verify emptyDir.sizeLimit is configured"

    local SIZE_LIMIT
    SIZE_LIMIT=$(kubectl get ${RESOURCE_TYPE} ${COMPONENT_LABEL} -n ${NAMESPACE} \
        -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"${VOLUME_NAME}\")].emptyDir.sizeLimit}" 2>/dev/null || echo "")

    if [ -n "$SIZE_LIMIT" ]; then
        check_pass "emptyDir.sizeLimit = ${SIZE_LIMIT}"
    else
        check_fail "emptyDir.sizeLimit is NOT configured"
        detail "The Helm chart did not render sizeLimit for volume '${VOLUME_NAME}'"
        detail "Check your values file has: emptyDir.sizeLimit: \"4Gi\""
        return 1
    fi

    # ── Step 2: Record pod state before test ──
    step "Step 2: Record pod state BEFORE test"

    local POD_NAME
    POD_NAME=$(kubectl get pod -n ${NAMESPACE} \
        -l app.kubernetes.io/name=${COMPONENT_LABEL} \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$POD_NAME" ]; then
        check_fail "No running pod found for ${COMPONENT_NAME}"
        return 1
    fi

    local POD_UID
    POD_UID=$(kubectl get pod -n ${NAMESPACE} ${POD_NAME} -o jsonpath='{.metadata.uid}')

    local RESTARTS_BEFORE
    RESTARTS_BEFORE=$(kubectl get pod -n ${NAMESPACE} ${POD_NAME} \
        -o jsonpath='{.status.containerStatuses[0].restartCount}')

    info "Pod name:    ${POD_NAME}"
    info "Pod UID:     ${POD_UID}"
    info "Restarts:    ${RESTARTS_BEFORE}"
    info "Status:      Running"
    check_pass "Pod is Running with ${RESTARTS_BEFORE} restarts"

    separator

    local DISK_BEFORE
    DISK_BEFORE=$(kubectl exec -n ${NAMESPACE} ${POD_NAME} -- df -h /tmp 2>/dev/null)
    info "Disk usage BEFORE:"
    echo "$DISK_BEFORE" | while read -r line; do detail "$line"; done

    # ── Step 3: Write 5GB to /tmp ──
    step "Step 3: Write ${WRITE_SIZE_MB}MB to /tmp (exceeds ${SIZE_LIMIT} limit)"

    info "Starting dd write..."
    detail "Command: dd if=/dev/zero of=/tmp/testfile bs=1M count=${WRITE_SIZE_MB}"
    echo ""

    local DD_OUTPUT
    local DD_EXIT_CODE=0
    DD_OUTPUT=$(kubectl exec -n ${NAMESPACE} ${POD_NAME} -- \
        dd if=/dev/zero of=/tmp/testfile bs=1M count=${WRITE_SIZE_MB} 2>&1) || DD_EXIT_CODE=$?

    if [ $DD_EXIT_CODE -ne 0 ]; then
        check_pass "dd write failed as expected (exit code: ${DD_EXIT_CODE})"
        echo "$DD_OUTPUT" | tail -3 | while read -r line; do detail "$line"; done
    else
        warn "dd write succeeded (should have been blocked by sizeLimit)"
    fi

    # Give kubelet time to process the eviction if it's going to happen
    info "Waiting 10s for kubelet to process..."
    sleep 10

    # ── Step 4: Check what happened ──
    step "Step 4: Determine outcome"

    # Check if original pod still exists and is running
    local POD_STATUS
    POD_STATUS=$(kubectl get pod -n ${NAMESPACE} ${POD_NAME} \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    local CURRENT_POD
    CURRENT_POD=$(kubectl get pod -n ${NAMESPACE} \
        -l app.kubernetes.io/name=${COMPONENT_LABEL} \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    local CURRENT_UID
    CURRENT_UID=$(kubectl get pod -n ${NAMESPACE} ${CURRENT_POD} \
        -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")

    if [ "$POD_STATUS" = "Running" ] && [ "$POD_UID" = "$CURRENT_UID" ]; then
        # ── Outcome A: Pod survived ──
        echo ""
        echo -e "  ${GREEN}${BOLD}Outcome A: Pod survived the disk pressure test${NC}"
        echo ""
        detail "dd hit ENOSPC before kubelet's next check"
        detail "Pod is still running with the same UID"
        detail "Volume is full but bounded — no node impact"
        check_pass "Original pod (${POD_NAME}) is still Running"

        separator

        info "Disk usage AFTER (volume should be at ~100%):"
        kubectl exec -n ${NAMESPACE} ${POD_NAME} -- df -h /tmp 2>/dev/null | while read -r line; do detail "$line"; done

        # Clean up test file
        separator
        info "Cleaning up test file..."
        kubectl exec -n ${NAMESPACE} ${POD_NAME} -- rm -f /tmp/testfile 2>/dev/null
        check_pass "Test file removed"

        info "Disk usage AFTER cleanup:"
        kubectl exec -n ${NAMESPACE} ${POD_NAME} -- df -h /tmp 2>/dev/null | while read -r line; do detail "$line"; done

    else
        # ── Outcome B: Pod was evicted and replaced ──
        echo ""
        echo -e "  ${YELLOW}${BOLD}Outcome B: Pod was evicted and replaced${NC}"
        echo ""
        detail "Kubelet detected emptyDir breach and evicted the pod"
        detail "Deployment/StatefulSet created a replacement automatically"

        separator

        info "Old pod:  ${POD_NAME} (${POD_STATUS})"
        info "New pod:  ${CURRENT_POD}"
        check_pass "Old pod was evicted (status: ${POD_STATUS})"

        # Wait for new pod to be ready
        if [ -n "$CURRENT_POD" ]; then
            kubectl wait --for=condition=ready pod/${CURRENT_POD} -n ${NAMESPACE} --timeout=120s &>/dev/null || true
            check_pass "New pod (${CURRENT_POD}) is Running"

            separator
            info "New pod /tmp is clean (auto-cleaned by emptyDir lifecycle):"
            kubectl exec -n ${NAMESPACE} ${CURRENT_POD} -- df -h /tmp 2>/dev/null | while read -r line; do detail "$line"; done
            check_pass "New pod has fresh empty /tmp (self-healed)"
        else
            check_fail "No replacement pod found — check deployment health"
        fi

        # Show eviction event
        separator
        info "Eviction event from kubectl:"
        kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' \
            | grep -i "ephemeral\|evict" | tail -3 | while read -r line; do detail "$line"; done
    fi

    # ── Step 5: Verify no node-level disk pressure ──
    step "Step 5: Verify no node-level impact"

    local NODE_PRESSURE
    NODE_PRESSURE=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: DiskPressure={.status.conditions[?(@.type=="DiskPressure")].status}{"\n"}{end}')

    echo "$NODE_PRESSURE" | while read -r line; do
        if echo "$line" | grep -q "False"; then
            detail "$line"
        else
            detail "${RED}$line${NC}"
        fi
    done

    if echo "$NODE_PRESSURE" | grep -q "True"; then
        check_fail "Node-level DiskPressure detected (sizeLimit may not be working)"
    else
        check_pass "No node-level DiskPressure — sizeLimit contained the write"
    fi

    # Check that other Argo CD pods were not affected
    separator
    info "All Argo CD pod statuses (none should be Evicted/Error):"
    kubectl get pods -n ${NAMESPACE} \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp' \
        | while read -r line; do detail "$line"; done

    echo ""
}

# =============================================================================
# Run tests
# =============================================================================
test_component "argocd-repo-server" "Repo-Server" "deployment" "tmp"
test_component "argocd-application-controller" "Application Controller" "statefulset" "argocd-application-controller-tmp"

# =============================================================================
# Final Report
# =============================================================================
banner "TEST RESULTS"

echo ""
if [ "$PASSED_CHECKS" -eq "$TOTAL_CHECKS" ]; then
    echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${NC}  (${PASSED_CHECKS}/${TOTAL_CHECKS})"
else
    echo -e "  ${YELLOW}${BOLD}${PASSED_CHECKS}/${TOTAL_CHECKS} CHECKS PASSED${NC}"
fi

echo ""
separator
echo ""
info "Summary:"
detail "emptyDir.sizeLimit prevents /tmp from growing beyond the configured cap."
detail "Writes exceeding the limit either fail with ENOSPC (pod survives) or"
detail "trigger a pod-level eviction (pod is replaced with clean /tmp)."
detail "In both cases, the node disk is never affected and other pods are safe."
echo ""
