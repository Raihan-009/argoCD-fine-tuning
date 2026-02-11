# Disk Pressure Fix - Installation & Testing Guide

Test the native `emptyDir.sizeLimit` fix for repo-server and application-controller using argo-cd Helm chart **v8.5.0+** ([PR #3281](https://github.com/argoproj/argo-helm/pull/3281)).

---

## Prerequisites

- Kind cluster running (see [01-kind-cluster-setup.md](./01-kind-cluster-setup.md))
- Helm 3.x and kubectl installed

```bash
# Verify
kubectl get nodes
helm version
```

---

## Step 1: Clean Up Any Existing Argo CD Installation

```bash
# Check if Argo CD is already installed
helm list -n argocd

# If installed, uninstall for a clean test
helm uninstall argocd -n argocd
kubectl delete namespace argocd --ignore-not-found=true

# Wait for namespace to fully terminate
kubectl wait --for=delete namespace/argocd --timeout=120s 2>/dev/null || true
```

---

## Step 2: Add Helm Repo & Verify Chart Version

```bash
# Add the Argo CD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Confirm v8.5.0+ is available (emptyDir.sizeLimit support)
helm search repo argo/argo-cd --versions | grep "8\\.5\\."
```

Expected output should show chart version `8.5.0` or later.

---

## Step 3: Create Namespace

```bash
kubectl create namespace argocd
```

---

## Step 4: Install Argo CD with Performance-Tuned Values

```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values implementation/helm/values-performance.yaml \
  --version 8.5.0 \
  --wait --timeout 5m
```

Wait for all pods to be ready:

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/part-of=argocd \
  -n argocd --timeout=300s
```

Verify pods:

```bash
kubectl get pods -n argocd
```

---

## Step 5: Verify emptyDir sizeLimit is Applied

### 5.1 Repo-Server

```bash
echo "=== Repo-Server emptyDir volumes ==="
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}: {.emptyDir}{"\n"}{end}' | grep -v "^$"
```

**Expected:** All emptyDir volumes (tmp, plugins, var-files, helm-working-dir) show `{"sizeLimit":"4Gi"}`.

### 5.2 Application Controller

```bash
echo "=== Controller emptyDir volumes ==="
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}: {.emptyDir}{"\n"}{end}' | grep -v "^$"
```

**Expected:** The controller tmp volume shows `{"sizeLimit":"4Gi"}`.

### 5.3 Quick One-Liner Check

```bash
echo "--- Repo-Server ---"
kubectl get deploy argocd-repo-server -n argocd \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="tmp")].emptyDir}'
echo ""
echo "--- Controller ---"
kubectl get sts argocd-application-controller -n argocd \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="argocd-application-controller-tmp")].emptyDir}'
echo ""
```

Both should output: `{"sizeLimit":"4Gi"}`

---

## Step 6: Test Disk Pressure Protection

### 6.1 Repo-Server Disk Test

```bash
# Get repo-server pod
REPO_POD=$(kubectl get pod -n argocd \
  -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{.items[0].metadata.name}')

# Check current /tmp usage
echo "=== Before test ==="
kubectl exec -n argocd $REPO_POD -- df -h /tmp

# Try to write 5GB (exceeds 4Gi limit - should fail)
echo "=== Writing 5GB to /tmp (should fail at ~4Gi) ==="
kubectl exec -n argocd $REPO_POD -- \
  dd if=/dev/zero of=/tmp/testfile bs=1M count=5000 2>&1 || true

# Check disk after
echo "=== After test ==="
kubectl exec -n argocd $REPO_POD -- df -h /tmp

# Verify pod is still running (not evicted)
echo "=== Pod status ==="
kubectl get pod -n argocd $REPO_POD -o jsonpath='Status: {.status.phase}{"\n"}'
```

**Expected behavior:**
| Scenario | What Happens |
|----------|-------------|
| Without sizeLimit | 5GB write succeeds, risks node disk pressure and pod eviction |
| With sizeLimit: 4Gi | Write fails at ~4Gi with "No space left on device", pod stays running |

### 6.2 Clean Up Test File

```bash
kubectl exec -n argocd $REPO_POD -- rm -f /tmp/testfile
```

### 6.3 Controller Disk Test

```bash
CTRL_POD=$(kubectl get pod -n argocd \
  -l app.kubernetes.io/name=argocd-application-controller \
  -o jsonpath='{.items[0].metadata.name}')

# Check /tmp usage
kubectl exec -n argocd $CTRL_POD -- df -h /tmp

# Small write test to confirm sizeLimit is enforced
kubectl exec -n argocd $CTRL_POD -- \
  dd if=/dev/zero of=/tmp/testfile bs=1M count=5000 2>&1 || true

echo "=== Pod status ==="
kubectl get pod -n argocd $CTRL_POD -o jsonpath='Status: {.status.phase}{"\n"}'

# Clean up
kubectl exec -n argocd $CTRL_POD -- rm -f /tmp/testfile
```

---

## Step 7: Verify No Pod Evictions or Restarts

```bash
# Check restart counts (should be 0)
echo "=== Pod Restarts ==="
kubectl get pods -n argocd \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATUS:.status.phase'

# Check for disk pressure events (should be empty)
echo "=== Disk/Eviction Events ==="
kubectl get events -n argocd --sort-by='.lastTimestamp' | grep -iE "evict|disk|pressure|oom" || echo "None found (good)"
```

---

## Step 8: Access Argo CD UI (Optional)

```bash
# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# UI: https://localhost:8080
# Username: admin
```

---

## Expected Results Summary

| Check | Expected |
|-------|----------|
| Chart version | 8.5.0 |
| Repo-server emptyDir sizeLimit | 4Gi |
| Controller emptyDir sizeLimit | 4Gi |
| 5GB write to repo-server /tmp | Fails at ~4Gi ("No space left") |
| Pod evicted after disk test | No |
| Pod restarts after disk test | 0 |
| Disk pressure events | None |

---

## Rollback

```bash
# Rollback to previous Helm release
helm rollback argocd -n argocd

# Or full uninstall
helm uninstall argocd -n argocd
kubectl delete namespace argocd
```

---

## Next Steps

Once disk pressure fix is validated:
1. Proceed to sync performance testing - see [03-load-testing-simulation.md](./03-load-testing-simulation.md)
2. Set up Prometheus monitoring - see [04-prometheus-monitoring-setup.md](./04-prometheus-monitoring-setup.md)
