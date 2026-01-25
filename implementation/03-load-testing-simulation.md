# Load Testing and Simulation Guide (Manual Testing)

This guide provides step-by-step manual testing instructions to simulate Argo CD performance issues and compare baseline vs tuned configurations.

---

## Testing Workflow Overview

```
STEP 1: Install Argo CD with DEFAULT values
STEP 2: Set up metrics collection
STEP 3: Run Test A, B, C, D (collect metrics for each)
STEP 4: Upgrade to TUNED values
STEP 5: Run same tests again
STEP 6: Compare results
```

---

## Prerequisites

```bash
# Verify cluster is running
kubectl get nodes

# Verify kubectl context
kubectl config current-context
# Should show: kind-argocd-perf-test
```

---

## Step 1: Install Argo CD with Default Values (Baseline)

```bash
# Add Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create namespaces
kubectl create namespace argocd
kubectl create namespace test-apps

# Install with DEFAULT values (no tuning)
helm install argocd argo/argo-cd \
  --namespace argocd \
  --wait

# Verify all pods are running
kubectl get pods -n argocd
```

**Expected output:**
```
NAME                                               READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                    1/1     Running   0          2m
argocd-applicationset-controller-xxx               1/1     Running   0          2m
argocd-dex-server-xxx                              1/1     Running   0          2m
argocd-notifications-controller-xxx                1/1     Running   0          2m
argocd-redis-xxx                                   1/1     Running   0          2m
argocd-repo-server-xxx                             1/1     Running   0          2m
argocd-server-xxx                                  1/1     Running   0          2m
```

---

## Step 2: Set Up Metrics Collection

### 2.1 Open Metrics Port (Run in separate terminal)

```bash
# Terminal 1: Port forward directly to the application-controller pod
# (The controller exposes metrics on port 8082)
kubectl port-forward -n argocd argocd-application-controller-0 8082:8082
```

Keep this terminal open during all tests.

### 2.2 Verify Metrics Access

```bash
# Terminal 2: Test metrics endpoint
curl -s localhost:8082/metrics | head -20
```

**Expected output:** You should see Prometheus metrics format:
```
# HELP argocd_app_info Information about application.
# TYPE argocd_app_info gauge
argocd_app_info{...} 1
```

**Troubleshooting:** If the above doesn't work, check available services/pods:
```bash
# List services
kubectl get svc -n argocd

# List pods
kubectl get pods -n argocd

# Alternative: port-forward using pod label
kubectl port-forward -n argocd pod/$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].metadata.name}') 8082:8082
```

### 2.3 Key Metrics Commands

Save these commands - you'll use them during each test:

```bash
# 1. Sync duration (how long syncs take)
curl -s localhost:8082/metrics | grep argocd_app_sync_total

# 2. Reconcile duration (time to compare desired vs actual state)
curl -s localhost:8082/metrics | grep argocd_app_reconcile

# 3. Workqueue depth (how many apps waiting to be processed)
curl -s localhost:8082/metrics | grep workqueue_depth

# 4. Workqueue adds (rate of new items added)
curl -s localhost:8082/metrics | grep workqueue_adds_total

# 5. Pod restarts
kubectl get pods -n argocd -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'
```

---

## Step 3: Run Manual Tests (Baseline)

### Test A: Sync Performance Under Load

**Purpose:** Test how long it takes to sync multiple applications simultaneously.

**What this tests:** Problem 2 (Slow Syncs During Peak Windows)

#### A.1 Create 30 Applications

```bash
# Create 30 apps at once
for i in $(seq 1 30); do
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
    namespace: test-apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
done
```

#### A.2 Watch Sync Progress

```bash
# Watch apps syncing (run immediately after creating apps)
watch -n 2 'kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" | head -35'
```

#### A.3 What to Look For

| Metric | Where to Check | Baseline (Default) Expected | Tuned Expected |
|--------|----------------|----------------------------|----------------|
| Time for all 30 apps to sync | Watch the `watch` command | 2-5 minutes | 30-90 seconds |
| Apps stuck in "Syncing" | SYNC column shows "Syncing" | Many apps stuck | Fewer/none stuck |
| Workqueue depth | `curl -s localhost:8082/metrics \| grep workqueue_depth` | High (>20) | Low (<10) |

#### A.4 Record Your Results

```bash
# After all apps show "Synced", check these:

# Workqueue depth
curl -s localhost:8082/metrics | grep "workqueue_depth{"

# Total syncs
curl -s localhost:8082/metrics | grep "argocd_app_sync_total"
```

**Write down:**
- Total time for all 30 apps to sync: _______ seconds
- Workqueue depth during sync: _______
- Any apps failed to sync: _______

---

### Test B: Disk Pressure Simulation

**Purpose:** Fill up repo-server's /tmp to see if it causes pod eviction.

**What this tests:** Problem 1 (Repo-Server Disk Pressure)

#### B.1 Check Initial Disk Usage

```bash
# Get repo-server pod name
REPO_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $REPO_POD"

# Check current disk usage
kubectl exec -n argocd $REPO_POD -- df -h /tmp
```

**Expected output:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       59G   15G   41G  27% /tmp    <-- Uses node filesystem (DEFAULT)
```

#### B.2 Fill Up Disk

```bash
# Open another terminal to watch events
kubectl get events -n argocd --watch

# In main terminal, create large files
kubectl exec -n argocd $REPO_POD -- dd if=/dev/zero of=/tmp/largefile1 bs=1M count=500
kubectl exec -n argocd $REPO_POD -- dd if=/dev/zero of=/tmp/largefile2 bs=1M count=500
kubectl exec -n argocd $REPO_POD -- dd if=/dev/zero of=/tmp/largefile3 bs=1M count=500

# Check disk usage after each file
kubectl exec -n argocd $REPO_POD -- df -h /tmp
```

#### B.3 What to Look For

| Behavior | Baseline (Default) | Tuned (with sizeLimit) |
|----------|-------------------|------------------------|
| Can create unlimited files | Yes (dangerous) | No (fails at limit) |
| Pod eviction | Possible if node disk fills | No (isolated volume) |
| Events | May show "Evicted" or "DiskPressure" | Shows "write error" at limit |

#### B.4 Check for Pod Restart/Eviction

```bash
# Check if pod was evicted/restarted
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server

# Check pod restarts
kubectl get pods -n argocd -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'

# Check events
kubectl get events -n argocd --sort-by='.lastTimestamp' | tail -10
```

**Write down:**
- Total disk used before failure/limit: _______
- Pod evicted (yes/no): _______
- Pod restarts: _______

#### B.5 Cleanup

```bash
# Clean up test files
kubectl exec -n argocd $REPO_POD -- rm -f /tmp/largefile*
```

---

### Test C: Concurrent Sync Burst (Re-sync)

**Purpose:** Trigger all apps to re-sync at once, simulating deployment burst.

**What this tests:** Problem 3 (Failed Syncs Under Load)

#### C.1 Trigger Hard Refresh on All Apps

```bash
# Force all apps to re-sync
for i in $(seq 1 30); do
  kubectl patch application test-app-$i -n argocd --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' &
done
wait
echo "All refresh requests sent"
```

#### C.2 Watch During Re-sync

```bash
# In one terminal - watch apps
watch -n 1 'kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status" | grep -v Synced | head -20'

# In another terminal - watch workqueue
watch -n 1 'curl -s localhost:8082/metrics 2>/dev/null | grep "workqueue_depth{"'
```

#### C.3 What to Look For

| Metric | Baseline (Default) | Tuned |
|--------|-------------------|-------|
| Workqueue depth spike | High (20-30+) | Lower (5-15) |
| Time to clear queue | Longer | Shorter |
| Failed syncs | Possible | Fewer/none |

#### C.4 Check for Failures

```bash
# Check for any sync failures
kubectl get applications -n argocd -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,MESSAGE:.status.conditions[0].message' | grep -v Synced
```

**Write down:**
- Peak workqueue depth: _______
- Time for all apps to re-sync: _______
- Any failed syncs: _______

---

### Test D: Resource Usage Check

**Purpose:** See how much CPU/memory components are using.

**What this tests:** Problem 3 (Failed Syncs Under Load - OOM/Throttling)

#### D.1 Check Resource Usage

```bash
# If metrics-server is installed
kubectl top pods -n argocd

# Or describe pods for resource requests/limits
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server | grep -A 5 "Limits:\|Requests:"
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-application-controller | grep -A 5 "Limits:\|Requests:"
```

#### D.2 What to Look For

| Component | Baseline Default Limits | Tuned Limits |
|-----------|------------------------|--------------|
| repo-server | None or low | cpu: 2000m, memory: 2Gi |
| controller | None or low | cpu: 2000m, memory: 4Gi |

#### D.3 Check for OOM Kills or Throttling

```bash
# Check if any container was OOM killed
kubectl get pods -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

# Check events for OOM
kubectl get events -n argocd | grep -i oom
```

**Write down:**
- repo-server CPU/Memory usage: _______
- controller CPU/Memory usage: _______
- Any OOM kills: _______

---

## Step 4: Clean Up Baseline Test Apps

```bash
# Delete all test applications
kubectl delete applications -n argocd --all

# Clean up test namespace
kubectl delete all --all -n test-apps

# Verify cleanup
kubectl get applications -n argocd
```

---

## Step 5: Upgrade to Tuned Configuration

```bash
# Upgrade with performance-tuned values
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values implementation/helm/values-performance.yaml \
  --wait

# Verify pods restart with new config
kubectl rollout status deployment/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd

# Verify new settings applied
echo "=== Controller Args ==="
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'

echo ""
echo "=== Repo-server emptyDir ==="
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")]}'
```

**Expected output should show:**
```
=== Controller Args ===
--status-processors=50
--operation-processors=30
...

=== Repo-server emptyDir ===
{"emptyDir":{"sizeLimit":"4Gi"},"name":"tmp"}
```

---

## Step 6: Run Same Tests with Tuned Config

Repeat Tests A, B, C, D from Step 3 and record results.

---

## Step 7: Compare Results

Use this table to compare your recorded results:

| Test | Metric | Baseline Result | Tuned Result | Improved? |
|------|--------|-----------------|--------------|-----------|
| A | Sync duration (30 apps) | _____ sec | _____ sec | |
| A | Workqueue depth | _____ | _____ | |
| B | Disk filled before limit | _____ | _____ | |
| B | Pod eviction | yes/no | yes/no | |
| B | Pod restarts | _____ | _____ | |
| C | Re-sync time | _____ sec | _____ sec | |
| C | Peak queue depth | _____ | _____ | |
| C | Failed syncs | _____ | _____ | |
| D | OOM kills | yes/no | yes/no | |

---

## Quick Reference: Where to Find Each Metric

| Metric | Command |
|--------|---------|
| `argocd_app_sync_total` | `curl -s localhost:8082/metrics \| grep argocd_app_sync_total` |
| `argocd_app_reconcile_duration_seconds` | `curl -s localhost:8082/metrics \| grep argocd_app_reconcile` |
| `workqueue_depth` | `curl -s localhost:8082/metrics \| grep "workqueue_depth{"` |
| `workqueue_adds_total` | `curl -s localhost:8082/metrics \| grep workqueue_adds_total` |
| Pod restarts | `kubectl get pods -n argocd -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'` |
| Disk usage | `kubectl exec -n argocd <repo-pod> -- df -h /tmp` |
| Resource usage | `kubectl top pods -n argocd` (requires metrics-server) |
| Events (eviction, OOM) | `kubectl get events -n argocd --sort-by='.lastTimestamp'` |

---

## Cleanup

```bash
# Delete all test applications
kubectl delete applications -n argocd --all

# Delete test namespace
kubectl delete namespace test-apps

# (Optional) Uninstall Argo CD
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# (Optional) Delete Kind cluster
kind delete cluster --name argocd-perf-test
```
