#!/bin/bash
# =============================================================================
# Compare Baseline vs Tuned Results
# =============================================================================
# This script compares the most recent baseline and tuned test results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Find most recent result files
BASELINE_FILE=$(ls -t "${RESULTS_DIR}"/baseline-*.json 2>/dev/null | head -1)
TUNED_FILE=$(ls -t "${RESULTS_DIR}"/tuned-*.json 2>/dev/null | head -1)

if [ -z "$BASELINE_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} No baseline results found. Run baseline test first."
    exit 1
fi

if [ -z "$TUNED_FILE" ]; then
    echo -e "${RED}[ERROR]${NC} No tuned results found. Run tuned test first."
    exit 1
fi

echo "=============================================="
echo "       PERFORMANCE COMPARISON REPORT"
echo "=============================================="
echo ""
echo "Baseline file: $(basename $BASELINE_FILE)"
echo "Tuned file:    $(basename $TUNED_FILE)"
echo ""

# Extract values using simple parsing (works without jq)
get_json_value() {
    local file=$1
    local key=$2
    grep -o "\"${key}\": *[^,}]*" "$file" | head -1 | sed 's/.*: *//' | tr -d '"'
}

# Get baseline values
B_SYNC_DURATION=$(get_json_value "$BASELINE_FILE" "duration_seconds" | head -1)
B_APPS_SYNCED=$(get_json_value "$BASELINE_FILE" "apps_synced")
B_APPS_FAILED=$(get_json_value "$BASELINE_FILE" "apps_failed")
B_RESYNC_DURATION=$(grep -A2 "resync_test" "$BASELINE_FILE" | grep "duration_seconds" | grep -o '[0-9]*')
B_REPO_RESTARTS=$(grep -A2 "pod_restarts" "$BASELINE_FILE" | grep "repo_server" | grep -o '[0-9]*')
B_CTRL_RESTARTS=$(grep -A3 "pod_restarts" "$BASELINE_FILE" | grep "controller" | grep -o '[0-9]*')

# Get tuned values
T_SYNC_DURATION=$(get_json_value "$TUNED_FILE" "duration_seconds" | head -1)
T_APPS_SYNCED=$(get_json_value "$TUNED_FILE" "apps_synced")
T_APPS_FAILED=$(get_json_value "$TUNED_FILE" "apps_failed")
T_RESYNC_DURATION=$(grep -A2 "resync_test" "$TUNED_FILE" | grep "duration_seconds" | grep -o '[0-9]*')
T_REPO_RESTARTS=$(grep -A2 "pod_restarts" "$TUNED_FILE" | grep "repo_server" | grep -o '[0-9]*')
T_CTRL_RESTARTS=$(grep -A3 "pod_restarts" "$TUNED_FILE" | grep "controller" | grep -o '[0-9]*')

# Calculate improvements
calc_improvement() {
    local baseline=$1
    local tuned=$2
    if [ -n "$baseline" ] && [ -n "$tuned" ] && [ "$baseline" != "0" ]; then
        echo "scale=1; (($baseline - $tuned) / $baseline) * 100" | bc 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

SYNC_IMPROVEMENT=$(calc_improvement "$B_SYNC_DURATION" "$T_SYNC_DURATION")
RESYNC_IMPROVEMENT=$(calc_improvement "$B_RESYNC_DURATION" "$T_RESYNC_DURATION")

# Display comparison table
echo "┌─────────────────────────┬────────────┬────────────┬─────────────┐"
echo "│         Metric          │  Baseline  │   Tuned    │ Improvement │"
echo "├─────────────────────────┼────────────┼────────────┼─────────────┤"
printf "│ %-23s │ %10s │ %10s │ %11s │\n" "Sync Duration (sec)" "${B_SYNC_DURATION:-N/A}" "${T_SYNC_DURATION:-N/A}" "${SYNC_IMPROVEMENT}%"
printf "│ %-23s │ %10s │ %10s │ %11s │\n" "Apps Synced" "${B_APPS_SYNCED:-N/A}" "${T_APPS_SYNCED:-N/A}" "-"
printf "│ %-23s │ %10s │ %10s │ %11s │\n" "Apps Failed" "${B_APPS_FAILED:-N/A}" "${T_APPS_FAILED:-N/A}" "-"
printf "│ %-23s │ %10s │ %10s │ %11s │\n" "Resync Duration (sec)" "${B_RESYNC_DURATION:-N/A}" "${T_RESYNC_DURATION:-N/A}" "${RESYNC_IMPROVEMENT}%"
printf "│ %-23s │ %10s │ %10s │ %11s │\n" "Repo-server Restarts" "${B_REPO_RESTARTS:-N/A}" "${T_REPO_RESTARTS:-N/A}" "-"
printf "│ %-23s │ %10s │ %10s │ %11s │\n" "Controller Restarts" "${B_CTRL_RESTARTS:-N/A}" "${T_CTRL_RESTARTS:-N/A}" "-"
echo "└─────────────────────────┴────────────┴────────────┴─────────────┘"
echo ""

# Summary
echo "=============================================="
echo "                  SUMMARY"
echo "=============================================="
echo ""

if [ -n "$SYNC_IMPROVEMENT" ] && [ "$SYNC_IMPROVEMENT" != "N/A" ]; then
    if (( $(echo "$SYNC_IMPROVEMENT > 0" | bc -l 2>/dev/null || echo 0) )); then
        echo -e "${GREEN}✓ Sync time improved by ${SYNC_IMPROVEMENT}%${NC}"
    else
        echo -e "${YELLOW}⚠ Sync time did not improve (${SYNC_IMPROVEMENT}%)${NC}"
    fi
fi

if [ "${T_APPS_FAILED:-0}" -lt "${B_APPS_FAILED:-0}" ]; then
    echo -e "${GREEN}✓ Fewer failed syncs (${B_APPS_FAILED} → ${T_APPS_FAILED})${NC}"
elif [ "${T_APPS_FAILED:-0}" -eq "${B_APPS_FAILED:-0}" ]; then
    echo -e "${BLUE}○ Same number of failed syncs (${T_APPS_FAILED})${NC}"
else
    echo -e "${RED}✗ More failed syncs (${B_APPS_FAILED} → ${T_APPS_FAILED})${NC}"
fi

if [ "${T_REPO_RESTARTS:-0}" -lt "${B_REPO_RESTARTS:-0}" ]; then
    echo -e "${GREEN}✓ Fewer repo-server restarts (${B_REPO_RESTARTS} → ${T_REPO_RESTARTS})${NC}"
elif [ "${T_REPO_RESTARTS:-0}" -eq "0" ]; then
    echo -e "${GREEN}✓ No repo-server restarts${NC}"
fi

echo ""
echo "=============================================="
echo ""
echo "For detailed metrics, review the JSON files:"
echo "  - $BASELINE_FILE"
echo "  - $TUNED_FILE"
echo ""
