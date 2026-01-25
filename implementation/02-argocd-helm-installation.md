# Argo CD Helm Installation Guide

This guide covers installing Argo CD using Helm with performance-tuned configurations to address:

1. Repo-server disk pressure
2. Slow syncs during peak windows
3. Failed syncs under load
4. Git fetch reliability

## Prerequisites

- Kind cluster running (see [01-kind-cluster-setup.md](./01-kind-cluster-setup.md))
- Helm 3.x installed
- kubectl configured to use the Kind cluster

```bash
# Verify prerequisites
kubectl config current-context  # Should show: kind-argocd-perf-test
helm version
```

---

## Step 1: Add Argo CD Helm Repository

```bash
# Add the Argo CD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm

# Update repository cache
helm repo update

# Search for available versions
helm search repo argo/argo-cd --versions | head -10
```

---

## Step 2: Create the Namespace

```bash
# Create argocd namespace
kubectl create namespace argocd

# Verify namespace
kubectl get namespace argocd
```

---

## Step 3: Create Performance-Tuned Values File

Create the file `implementation/helm/values-performance.yaml`:

```bash
mkdir -p implementation/helm
```

The values file is located at `implementation/helm/values-performance.yaml` in this repository.

### Key Configurations Explained

#### 1. Repo-Server Disk Pressure Fix

```yaml
repoServer:
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 4Gi  # Prevents disk exhaustion
  volumeMounts:
    - name: tmp
      mountPath: /tmp
```

**Why:** Default `/tmp` has no size limit, causing disk pressure and pod evictions.

#### 2. Increased Parallelism for Sync Performance

```yaml
controller:
  args:
    statusProcessors: "50"      # Up from default 20
    operationProcessors: "30"   # Up from default 10
    appResyncPeriod: "180"      # 3 minutes
```

**Why:** Default parallelism (10 workers) creates bottlenecks during deployment bursts.

#### 3. Resource Allocation for Stability

```yaml
# Repo-server (CPU/memory intensive for manifest generation)
repoServer:
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2000m
      memory: 2Gi

# Application Controller (memory intensive for state tracking)
controller:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
```

**Why:** Prevents OOM kills and CPU throttling under load.

#### 4. Git Fetch Reliability

```yaml
repoServer:
  env:
    - name: ARGOCD_GIT_ATTEMPTS_COUNT
      value: "3"
    - name: ARGOCD_EXEC_TIMEOUT
      value: "180s"
```

**Why:** Handles rate limiting and network issues with automatic retries.

---

## Step 4: Install Argo CD

### Option A: Install with Default Values (Baseline)

For establishing a baseline before performance tuning:

```bash
# Install with defaults
helm install argocd argo/argo-cd \
  --namespace argocd \
  --wait

# Note: Use this for baseline metrics collection
```

### Option B: Install with Performance-Tuned Values (Recommended)

```bash
# Install with performance tuning
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values implementation/helm/values-performance.yaml \
  --wait
```

### Verify Installation

```bash
# Check all pods are running
kubectl get pods -n argocd

# Expected output (all should be Running/1/1):
# NAME                                               READY   STATUS    RESTARTS   AGE
# argocd-application-controller-0                    1/1     Running   0          2m
# argocd-applicationset-controller-xxx               1/1     Running   0          2m
# argocd-dex-server-xxx                              1/1     Running   0          2m
# argocd-notifications-controller-xxx                1/1     Running   0          2m
# argocd-redis-xxx                                   1/1     Running   0          2m
# argocd-repo-server-xxx                             1/1     Running   0          2m
# argocd-server-xxx                                  1/1     Running   0          2m

# Check services
kubectl get svc -n argocd
```

---

## Step 5: Access Argo CD UI

### Option A: Port Forward (Simple)

```bash
# Port forward the Argo CD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access UI at: https://localhost:8080
# Accept the self-signed certificate warning
```

### Option B: NodePort Service

```bash
# Patch service to NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "nodePort": 30443}]}}'

# Access UI at: https://localhost:30443
```

### Get Admin Password

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Login credentials:
# Username: admin
# Password: <output from above command>
```

---

## Step 6: Install Argo CD CLI (Optional)

```bash
# Install CLI via Homebrew
brew install argocd

# Login to Argo CD
argocd login localhost:8080 --username admin --password <password> --insecure

# Verify connection
argocd version
```

---

## Step 7: Verify Performance Configurations

### Check Repo-Server Volume Mount

```bash
# Verify emptyDir is mounted with sizeLimit
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o yaml | grep -A 5 "emptyDir"

# Check actual disk usage in repo-server
kubectl exec -n argocd -it $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}') -- df -h /tmp
```

### Check Controller Settings

```bash
# Verify controller arguments
kubectl get statefulset argocd-application-controller -n argocd -o yaml | grep -A 20 "args:"

# Should show:
# --status-processors=50
# --operation-processors=30
# --app-resync=180
```

### Check Resource Allocations

```bash
# View resource requests and limits
kubectl get pods -n argocd -o custom-columns='NAME:.metadata.name,CPU_REQ:.spec.containers[0].resources.requests.cpu,MEM_REQ:.spec.containers[0].resources.requests.memory,CPU_LIM:.spec.containers[0].resources.limits.cpu,MEM_LIM:.spec.containers[0].resources.limits.memory'
```

### Check Git Environment Variables

```bash
# Check repo-server environment
kubectl get deployment argocd-repo-server -n argocd -o yaml | grep -A 2 "ARGOCD_GIT"
```

---

## Step 8: Upgrade Existing Installation

If you installed with defaults and want to apply performance tuning:

```bash
# Upgrade with new values
helm upgrade argocd argo/argo-cd \
  --namespace argocd \
  --values implementation/helm/values-performance.yaml \
  --wait

# Verify pods restart with new configuration
kubectl rollout status deployment/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd
```

---

## Step 9: Rollback Plan

If issues occur after applying performance tuning:

```bash
# Option 1: Rollback to previous Helm release
helm rollback argocd -n argocd

# Option 2: Reinstall with defaults
helm uninstall argocd -n argocd
helm install argocd argo/argo-cd --namespace argocd --wait

# Option 3: Scale down problematic component
kubectl scale deployment argocd-repo-server -n argocd --replicas=0
# Investigate, then scale back up
kubectl scale deployment argocd-repo-server -n argocd --replicas=1
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod -n argocd <pod-name>

# Check logs
kubectl logs -n argocd <pod-name>

# Common issues:
# - Insufficient node resources → reduce resource requests
# - Image pull issues → check network/registry access
```

### Repo-Server OOMKilled

```bash
# Check if OOM occurred
kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].status.containerStatuses[0].lastState}'

# Solution: Increase memory limit
# Edit values-performance.yaml:
# repoServer.resources.limits.memory: 4Gi
```

### Slow Sync Performance

```bash
# Check controller queue depth
kubectl exec -n argocd argocd-application-controller-0 -- sh -c 'curl -s localhost:8082/metrics | grep workqueue_depth'

# If queue depth is consistently high, increase processors
```

### Git Clone Failures

```bash
# Check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100

# Look for:
# - "rate limit" → ARGOCD_GIT_ATTEMPTS_COUNT helps
# - "timeout" → ARGOCD_EXEC_TIMEOUT helps
# - "authentication" → check credentials/SSH keys
```

---

## Cleanup

```bash
# Uninstall Argo CD
helm uninstall argocd -n argocd

# Delete namespace
kubectl delete namespace argocd

# Delete Kind cluster (if done testing)
kind delete cluster --name argocd-perf-test
```

---

## Quick Reference

```bash
# Install with performance tuning
helm install argocd argo/argo-cd -n argocd --values implementation/helm/values-performance.yaml --wait

# Access UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Upgrade configuration
helm upgrade argocd argo/argo-cd -n argocd --values implementation/helm/values-performance.yaml

# Rollback
helm rollback argocd -n argocd
```

---

## Next Steps

1. Create sample applications to test sync performance
2. Set up monitoring (Prometheus/Grafana) - see `03-monitoring-setup.md`
3. Run load tests to simulate issues
4. Compare baseline vs tuned metrics
