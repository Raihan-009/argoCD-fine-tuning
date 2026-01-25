# Load Testing and Simulation Guide

This guide covers how to:
1. Deploy Argo CD with **default values** (baseline)
2. Simulate load and observe failures
3. Collect metrics
4. Redeploy with **tuned values**
5. Run the same tests and compare results

---

## Overview: Test Workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         TESTING WORKFLOW                                 │
│                                                                          │
│   PHASE 1: BASELINE                    PHASE 2: TUNED                   │
│   ┌─────────────────────┐              ┌─────────────────────┐          │
│   │ Deploy with         │              │ Deploy with         │          │
│   │ DEFAULT values      │              │ TUNED values        │          │
│   └──────────┬──────────┘              └──────────┬──────────┘          │
│              │                                    │                      │
│              ▼                                    ▼                      │
│   ┌─────────────────────┐              ┌─────────────────────┐          │
│   │ Run Load Tests      │              │ Run Load Tests      │          │
│   │ • Create 50+ apps   │              │ • Same tests        │          │
│   │ • Trigger syncs     │              │                     │          │
│   │ • Fill disk         │              │                     │          │
│   └──────────┬──────────┘              └──────────┬──────────┘          │
│              │                                    │                      │
│              ▼                                    ▼                      │
│   ┌─────────────────────┐              ┌─────────────────────┐          │
│   │ Collect Metrics     │              │ Collect Metrics     │          │
│   │ • Sync duration     │              │ • Sync duration     │          │
│   │ • Failed syncs      │              │ • Failed syncs      │          │
│   │ • Pod restarts      │              │ • Pod restarts      │          │
│   └──────────┬──────────┘              └──────────┬──────────┘          │
│              │                                    │                      │
│              └────────────────┬───────────────────┘                      │
│                               │                                          │
│                               ▼                                          │
│                    ┌─────────────────────┐                              │
│                    │   COMPARE RESULTS   │                              │
│                    │   Baseline vs Tuned │                              │
│                    └─────────────────────┘                              │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

1. Kind cluster running (see `01-kind-cluster-setup.md`)
2. Helm installed
3. kubectl configured
4. Argo CD CLI installed (optional but helpful)

```bash
# Verify cluster is ready
kubectl get nodes
```

---

## Phase 1: Baseline Testing (Default Values)

### Step 1.1: Install Argo CD with Defaults

```bash
# Add Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create namespace
kubectl create namespace argocd

# Install with DEFAULT values (no tuning)
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --wait

# Verify installation
kubectl get pods -n argocd

# Get admin password
ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "Admin password: $ARGOCD_PWD"
```

### Step 1.2: Set Up Test Git Repository

We'll use a public repo with sample apps for testing:

```bash
# Create a namespace for test applications
kubectl create namespace test-apps
```

### Step 1.3: Run Load Test Scripts

Execute the load tests (scripts are in `implementation/scripts/`):

```bash
# Make scripts executable
chmod +x implementation/scripts/*.sh

# Run the full baseline test suite
./implementation/scripts/run-baseline-test.sh
```

---

## Phase 2: Tuned Configuration Testing

### Step 2.1: Upgrade to Tuned Values

```bash
# Upgrade Argo CD with performance tuning
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values implementation/helm/values-performance.yaml \
  --wait

# Verify pods restarted with new config
kubectl get pods -n argocd

# Verify tuned settings applied
kubectl get statefulset argocd-application-controller -n argocd -o yaml | grep -A 5 "args:"
```

### Step 2.2: Run Same Load Tests

```bash
# Run the tuned test suite
./implementation/scripts/run-tuned-test.sh
```

### Step 2.3: Compare Results

```bash
# Generate comparison report
./implementation/scripts/compare-results.sh
```

---

## Manual Testing Steps

If you prefer to run tests manually:

### Test 1: Sync Performance Under Load

This tests **Problem 2: Slow Syncs During Peak Windows**

```bash
# Create 30 applications simultaneously
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

# Watch sync status
watch -n 2 'kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,STATUS:.status.sync.status,HEALTH:.status.health.status"'
```

### Test 2: Disk Pressure Simulation

This tests **Problem 1: Repo-Server Disk Pressure**

```bash
# Get repo-server pod name
REPO_POD=$(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')

# Check current disk usage
kubectl exec -n argocd $REPO_POD -- df -h /tmp

# Create large files to simulate disk pressure (in default config, this will cause issues)
kubectl exec -n argocd $REPO_POD -- sh -c 'dd if=/dev/zero of=/tmp/largefile1 bs=1M count=500'
kubectl exec -n argocd $REPO_POD -- sh -c 'dd if=/dev/zero of=/tmp/largefile2 bs=1M count=500'

# Check disk usage again
kubectl exec -n argocd $REPO_POD -- df -h /tmp

# Watch for pod eviction (in default config)
kubectl get events -n argocd --watch
```

### Test 3: Concurrent Sync Burst

This tests **Problem 3: Failed Syncs Under Load**

```bash
# Trigger sync on all applications simultaneously
for i in $(seq 1 30); do
  kubectl patch application test-app-$i -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' &
done
wait

# Monitor for failures
kubectl get applications -n argocd -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,MESSAGE:.status.conditions[0].message"
```

### Test 4: Monitor Metrics

```bash
# Port forward to access metrics
kubectl port-forward svc/argocd-metrics -n argocd 8082:8082 &

# Fetch key metrics
curl -s localhost:8082/metrics | grep -E "argocd_app_sync|argocd_app_reconcile|workqueue_depth"
```

---

## Metrics Collection

### Key Metrics to Capture

| Metric | What it Shows | Good Value |
|--------|--------------|------------|
| `argocd_app_sync_total` | Total sync operations | N/A (counter) |
| `argocd_app_reconcile_duration_seconds` | Time to reconcile | p95 < 5s |
| `workqueue_depth` | Queue backlog | < 10 |
| `workqueue_adds_total` | Items added to queue | N/A (counter) |
| Pod restarts | Stability | 0 |

### Capture Metrics Script

```bash
# Save metrics snapshot
kubectl exec -n argocd $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].metadata.name}') -- sh -c 'curl -s localhost:8082/metrics' > metrics-$(date +%Y%m%d-%H%M%S).txt
```

---

## Cleanup Between Tests

```bash
# Delete all test applications
kubectl delete applications -n argocd -l app.kubernetes.io/part-of=test-suite

# Or delete all applications
kubectl delete applications -n argocd --all

# Clean up test namespace
kubectl delete namespace test-apps
kubectl create namespace test-apps

# Reset Argo CD (full reinstall)
helm uninstall argocd -n argocd
kubectl delete namespace argocd
```

---

## Expected Results

### Baseline (Default Values)

| Test | Expected Behavior |
|------|-------------------|
| 30 app sync burst | Slow, apps queue up, some may timeout |
| Disk pressure | Pod eviction after ~1GB fill |
| Concurrent syncs | Some failures, high latency |
| Queue depth | High (>20) during burst |

### Tuned Values

| Test | Expected Behavior |
|------|-------------------|
| 30 app sync burst | Faster, parallel processing |
| Disk pressure | Limited to 4Gi, no eviction |
| Concurrent syncs | Fewer failures, lower latency |
| Queue depth | Lower (<10) during burst |

---

## Troubleshooting

### Tests Not Showing Difference

If baseline and tuned results are similar:

1. **Increase load**: Try 50+ apps instead of 30
2. **Reduce Kind resources**: Limit Docker to 4GB RAM to exaggerate resource issues
3. **Check configs applied**: Verify tuned values are actually in use

### Pods Keep Crashing

```bash
# Check pod logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100

# Check events
kubectl get events -n argocd --sort-by='.lastTimestamp'

# Describe pod for details
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
```

---

## Next Steps

After completing tests:

1. Document results in `implementation/results/`
2. Create comparison charts
3. Present findings with before/after metrics
