# Load Testing and Simulation Guide

Simple test cases to verify each performance tuning fix.

---

## Prerequisites

```bash
# Verify cluster and Argo CD are running
kubectl get nodes
kubectl get pods -n argocd
```

---

## Test Setup: Metrics Access

Open a **separate terminal** and keep this running during all tests:

```bash
kubectl port-forward -n argocd argocd-application-controller-0 8082:8082
```

---

## Test 1: Sync Performance (Parallelism)

**Problem:** Slow syncs during peak deployment windows
**Fix:** Increased `--status-processors=50` and `--operation-processors=30`

### What to Do

**Terminal 1:** Create 20 apps simultaneously (each with unique namespace to avoid conflicts)
```bash
for i in $(seq 1 20); do
  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-app-$i
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: test-app-ns-$i
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
done
```

> **Note:** Each app deploys to its own namespace (`test-app-ns-1`, `test-app-ns-2`, etc.) to avoid resource conflicts. If all apps deploy to the same namespace, they'll fight over the same `guestbook-ui` resources and show `SharedResourceWarning`.

**Terminal 2:** Watch sync progress (start immediately)
```bash
watch -n 2 'kubectl get applications -n argocd --no-headers | wc -l && echo "---" && kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status" | grep -v Synced | head -10'
```

**Terminal 3:** Watch workqueue depth
```bash
watch -n 2 'curl -s localhost:8082/metrics 2>/dev/null | grep "workqueue_depth{" | head -5'
```

### What to Observe

| Metric | Baseline (Default) | Tuned | How to Check |
|--------|-------------------|-------|--------------|
| Time for all 20 apps to sync | 2-4 minutes | 30-60 seconds | Stopwatch from start to all "Synced" |
| Workqueue depth during sync | High (15-20+) | Low (5-10) | Terminal 3 |
| Apps stuck in "Syncing" | Many | Few/None | Terminal 2 |

### Verify Tuning Applied

```bash
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o "processors=[0-9]*"
```

**Expected:** `processors=50` and `processors=30`

### Cleanup

```bash
# Delete all test applications
kubectl delete applications -n argocd --all

# Delete test namespaces
for i in $(seq 1 20); do
  kubectl delete namespace test-app-ns-$i --ignore-not-found=true &
done
wait
```

---

## Test 2: Disk Pressure (EmptyDir SizeLimit)

**Problem:** Repo-server /tmp fills up, causes pod eviction
**Fix:** EmptyDir with `sizeLimit: 4Gi`

### What to Do

```bash
# Get repo-server pod
REPO_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')

# Check current disk config
echo "=== Current /tmp usage ==="
kubectl exec -n argocd $REPO_POD -- df -h /tmp

# Try to create a 5GB file (larger than 4Gi limit)
echo "=== Creating 5GB file (should fail if sizeLimit works) ==="
kubectl exec -n argocd $REPO_POD -- dd if=/dev/zero of=/tmp/testfile bs=1M count=5000 2>&1 || echo "Write failed (expected with sizeLimit)"

# Check disk after
echo "=== Disk usage after test ==="
kubectl exec -n argocd $REPO_POD -- df -h /tmp

# Check if pod is still running
echo "=== Pod status ==="
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

### What to Observe

| Behavior | Baseline (Default) | Tuned |
|----------|-------------------|-------|
| Can write unlimited data to /tmp | Yes (dangerous) | No (stops at ~4Gi) |
| 5GB write succeeds | Yes | No (fails with "No space left") |
| Pod gets evicted | Possible | No |

### Verify Tuning Applied

```bash
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")].emptyDir}'
```

**Expected:** `{"sizeLimit":"4Gi"}`

### Cleanup

```bash
REPO_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n argocd $REPO_POD -- rm -f /tmp/testfile
```

---

## Test 3: Resource Limits (OOM/Throttling Prevention)

**Problem:** Pods get OOM killed or CPU throttled under load
**Fix:** Proper resource requests/limits

### What to Do

```bash
# Check resource configuration
echo "=== Repo-Server Resources ==="
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | python3 -m json.tool 2>/dev/null || \
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'

echo ""
echo "=== Controller Resources ==="
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' | python3 -m json.tool 2>/dev/null || \
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'

# Check for any OOM events
echo ""
echo "=== OOM Events (should be empty) ==="
kubectl get events -n argocd | grep -i "oom\|killed\|evict" || echo "No OOM events found"

# Check pod restart counts
echo ""
echo "=== Pod Restarts ==="
kubectl get pods -n argocd -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'
```

### What to Observe

| Component | Baseline (Default) | Tuned |
|-----------|-------------------|-------|
| Repo-server memory limit | None or 256Mi | 2Gi |
| Controller memory limit | None or 256Mi | 4Gi |
| Repo-server CPU limit | None or 250m | 2000m |
| Controller CPU limit | None or 250m | 2000m |
| OOM events | Possible under load | None |
| Pod restarts | May occur | 0 |

---

## Test 4: Git Fetch Reliability (Retry & Timeout)

**Problem:** Git operations fail due to timeouts or rate limiting
**Fix:** `ARGOCD_GIT_ATTEMPTS_COUNT=3` and `ARGOCD_EXEC_TIMEOUT=180s`

### What to Do

```bash
# Check environment variables in repo-server
echo "=== Repo-Server Env Vars ==="
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].env[*]}' | tr ',' '\n' | grep -E "ARGOCD_GIT|ARGOCD_EXEC"
```

### What to Observe

| Setting | Baseline (Default) | Tuned |
|---------|-------------------|-------|
| ARGOCD_GIT_ATTEMPTS_COUNT | 1 (no retry) | 3 |
| ARGOCD_EXEC_TIMEOUT | 90s | 180s |

### Simulate (Optional)

To test retry behavior, you would need a git repo that intermittently fails. For Kind testing, just verify the env vars are set correctly.

---

## Quick Verification Checklist

Run this to verify all tuning is applied:

```bash
echo "=========================================="
echo "   PERFORMANCE TUNING VERIFICATION"
echo "=========================================="

echo ""
echo "1. Controller Parallelism:"
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -E "processors|resync"

echo ""
echo "2. Repo-Server Disk Limit:"
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")].emptyDir}'

echo ""
echo "3. Repo-Server Resources:"
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='requests: {.spec.template.spec.containers[0].resources.requests}, limits: {.spec.template.spec.containers[0].resources.limits}'

echo ""
echo "4. Controller Resources:"
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='requests: {.spec.template.spec.containers[0].resources.requests}, limits: {.spec.template.spec.containers[0].resources.limits}'

echo ""
echo "5. Git Retry Settings:"
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].env[*]}' | tr ',' '\n' | grep -E "GIT_ATTEMPTS|EXEC_TIMEOUT"

echo ""
echo "=========================================="
```

### Expected Output (Tuned)

```
1. Controller Parallelism:
--status-processors=50
--operation-processors=30
--app-resync=180

2. Repo-Server Disk Limit:
{"sizeLimit":"4Gi"}

3. Repo-Server Resources:
requests: {"cpu":"500m","memory":"512Mi"}, limits: {"cpu":"2000m","memory":"2Gi"}

4. Controller Resources:
requests: {"cpu":"500m","memory":"1Gi"}, limits: {"cpu":"2000m","memory":"4Gi"}

5. Git Retry Settings:
{"name":"ARGOCD_GIT_ATTEMPTS_COUNT","value":"3"}
{"name":"ARGOCD_EXEC_TIMEOUT","value":"180s"}
```

---

## Summary: Before vs After

| Problem | Baseline Behavior | Tuned Behavior |
|---------|------------------|----------------|
| **Slow Syncs** | 20 apps take 2-4 min, high queue | 20 apps take 30-60 sec, low queue |
| **Disk Pressure** | /tmp can fill node disk, pod evicted | /tmp limited to 4Gi, no eviction |
| **OOM/Throttle** | Pods crash under heavy load | Pods have headroom, stable |
| **Git Failures** | Single attempt, 90s timeout | 3 retries, 180s timeout |

---

## Cleanup

```bash
# Delete test applications
kubectl delete applications -n argocd --all

# Delete test namespaces
for i in $(seq 1 20); do
  kubectl delete namespace test-app-ns-$i --ignore-not-found=true &
done
wait

# (Optional) Uninstall Argo CD
helm uninstall argocd -n argocd

# (Optional) Delete Kind cluster
kind delete cluster --name argocd-perf-test
```
