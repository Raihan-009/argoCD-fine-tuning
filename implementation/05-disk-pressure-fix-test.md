# Disk Pressure Fix - Installation & Testing Guide

Test the native `emptyDir.sizeLimit` fix for repo-server and application-controller using argo-cd Helm chart **v8.5.0+** ([PR #3281](https://github.com/argoproj/argo-helm/pull/3281)).

---

## What is the Disk Pressure Problem?

When Argo CD runs in Kubernetes, both the **repo-server** and **application-controller** use `/tmp` for scratch work (git clones, Helm renders, manifest diffs). By default, `/tmp` inside a container is backed by the **node's root filesystem** - the same disk that the kubelet, other pods, and the OS itself use.

If `/tmp` grows unchecked (e.g. cloning large repos, rendering big Helm charts, concurrent deployments), it fills up the **node disk**. When node disk usage crosses ~85%, the kubelet triggers **DiskPressure** and starts **evicting pods** across the entire node - not just the offending pod. This is the root cause of the repo-server crashes and instability the team has been experiencing.

### How emptyDir.sizeLimit Fixes This

Setting `emptyDir.sizeLimit: "4Gi"` tells Kubernetes to:

1. **Track disk usage per-volume** - The kubelet monitors each emptyDir volume independently
2. **Enforce the cap** - When the volume reaches 4Gi, any further write returns `ENOSPC` ("No space left on device")
3. **Evict only the offending pod** - If the limit is breached, kubelet evicts only that specific pod, not everything on the node
4. **Auto-cleanup on restart** - emptyDir is wiped when the pod restarts, so it self-heals

The key difference: **without** sizeLimit, disk pressure is a node-level problem that takes down everything. **With** sizeLimit, it's an isolated pod-level problem that self-recovers.

---

## Why Both Repo-Server AND Controller?

### Repo-Server (Primary Fix)

The repo-server does the heavy disk I/O:
- **Git clones** - Every repo gets cloned into `/tmp`
- **Helm template rendering** - Large charts produce big intermediate files
- **Plugin cache** - Custom plugins write to `/tmp`
- **Kustomize/Jsonnet builds** - Manifest generation scratch space

This is the component that was crashing. Chart v8.5.0 applies sizeLimit to **four** emptyDir volumes: `tmp`, `plugins`, `var-files`, `helm-working-dir`.

### Application Controller (Preventative Fix)

The controller uses a tmp emptyDir (`argocd-application-controller-tmp`) for:
- **Manifest diffing** - Comparing desired vs live state
- **Concurrent sync operations** - With `--operation-processors=30`, it processes 30 syncs simultaneously
- **Large CRD handling** - Big Custom Resources get written to temp storage

Under the high parallelism settings in our values file (50 status + 30 operation processors), the controller can generate significant temp disk usage. Without a cap, it has the same node-level disk pressure risk. This fix was specifically added in PR #3281 to address [issue #19201](https://github.com/argoproj/argo-cd/issues/19201).

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

Before running any tests, confirm that Helm actually rendered the sizeLimit into the Kubernetes resources.

### 5.1 Repo-Server

```bash
echo "=== Repo-Server emptyDir volumes ==="
kubectl get deployment argocd-repo-server -n argocd \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}: {.emptyDir}{"\n"}{end}' | grep -v "^$"
```

**Expected output:**
```
tmp: {"sizeLimit":"4Gi"}
plugins: {"sizeLimit":"4Gi"}
var-files: {"sizeLimit":"4Gi"}
helm-working-dir: {"sizeLimit":"4Gi"}
```

**Why 4 volumes?** The repo-server uses separate emptyDir volumes for different workloads. Each one is independently capped at 4Gi, preventing any single workload type from consuming unbounded disk.

### 5.2 Application Controller

```bash
echo "=== Controller emptyDir volumes ==="
kubectl get statefulset argocd-application-controller -n argocd \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}: {.emptyDir}{"\n"}{end}' | grep -v "^$"
```

**Expected output:**
```
argocd-application-controller-tmp: {"sizeLimit":"4Gi"}
```

**Why only 1 volume?** The controller has a simpler disk profile - it only needs temp space for manifest processing, not git clones or plugin caches.

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

This is where we prove the fix works by deliberately trying to exceed the limit.

### Understanding What Will Happen

When we write a 5GB file to a 4Gi-limited emptyDir:

```
Timeline:
─────────────────────────────────────────────────────────────────
 0GB        1GB        2GB        3GB        4Gi     5GB
  |──────────|──────────|──────────|──────────|────X
  Writing... Writing... Writing... Writing..  STOP
                                               │
                                    "No space left on device"
                                               │
                                     dd command exits with error
                                     Pod keeps running normally
─────────────────────────────────────────────────────────────────
```

The `dd` command fails. The pod does NOT get evicted or restarted. This is the critical difference from having no sizeLimit, where the write would succeed, fill the node disk, and kubelet would evict pods.

### 6.1 Repo-Server Disk Test

#### Record Pod Name and Status Before Test

```bash
# Get repo-server pod
REPO_POD=$(kubectl get pod -n argocd \
  -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{.items[0].metadata.name}')

echo "Pod name: $REPO_POD"

# Check pod status BEFORE test
echo "=== Pod status BEFORE test ==="
kubectl get pod -n argocd $REPO_POD \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'
```

**Expected output:**
```
NAME                                  STATUS    RESTARTS
argocd-repo-server-xxxxxxxxxx-xxxxx   Running   0
```

**Why "Running"?** The pod is healthy, all containers are up and serving. This is the normal steady state.

#### Check Disk Before Test

```bash
echo "=== Disk usage BEFORE test ==="
kubectl exec -n argocd $REPO_POD -- df -h /tmp
```

**Expected output:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdX        4.0G   0   4.0G   0% /tmp
```

**Why 4.0G?** The `sizeLimit: 4Gi` is reflected here. Kubernetes has allocated a tracked emptyDir volume with a 4Gi cap. `Used` is near 0 because nothing has written to `/tmp` yet (or very little from normal operations).

#### Write 5GB to /tmp (Exceeds 4Gi Limit)

```bash
echo "=== Writing 5GB to /tmp (should fail at ~4Gi) ==="
kubectl exec -n argocd $REPO_POD -- \
  dd if=/dev/zero of=/tmp/testfile bs=1M count=5000 2>&1 || true
```

**Expected output:**
```
dd: error writing '/tmp/testfile': No space left on device
XXXX+0 records in
XXXX+0 records out
XXXXXXXXX bytes (X.X GB) copied, X.X s, XXX MB/s
```

**What happened and why:**
1. `dd` started writing zeroes to `/tmp/testfile` at 1MB per block
2. After writing ~4Gi, the kubelet's ephemeral storage tracking detected the emptyDir reached its sizeLimit
3. The Linux kernel returned `ENOSPC` (No Space Left On Device) to the `dd` process
4. `dd` exited with an error - this is **expected and correct behavior**
5. The pod itself is **unaffected** - only the write operation failed, not the container

#### Check Disk After Test

```bash
echo "=== Disk usage AFTER test ==="
kubectl exec -n argocd $REPO_POD -- df -h /tmp
```

**Expected output:**
```
Filesystem      Size  Used Avail Use% Mounted on
/dev/sdX        4.0G  4.0G    0 100% /tmp
```

**Why 100% used?** The partial 5GB write filled the volume up to its 4Gi cap and stopped. The volume is full but **bounded** - it cannot grow beyond 4Gi regardless of what runs inside the container.

#### Verify Pod Status After Test

```bash
echo "=== Pod status AFTER test ==="
kubectl get pod -n argocd $REPO_POD \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'

echo ""
echo "=== All repo-server pods ==="
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'
```

#### Two Possible Outcomes (Both Are Correct)

There is a race condition between the `dd` write and the kubelet's periodic ephemeral storage check (~10-15 second interval). Depending on timing, you will see one of two outcomes:

**Outcome A: Pod Stays Running**

```
NAME                                  STATUS    RESTARTS
argocd-repo-server-xxxxxxxxxx-abc12   Running   0
```

This happens when `dd` hits the `ENOSPC` error and stops writing **before** the kubelet's next periodic check. The kubelet never sees a breach, so the pod stays alive. The volume is full but the pod is healthy.

**Outcome B: Pod Gets Evicted and Replaced (This Is Also Normal)**

```
NAME                                  STATUS    RESTARTS
argocd-repo-server-xxxxxxxxxx-abc12   <not found or Evicted>
argocd-repo-server-xxxxxxxxxx-xyz78   Running   0        ← new pod
```

This happens when the kubelet's periodic check runs **while** `dd` is still writing or right after the volume hits 100%. The kubelet detects the emptyDir breached its sizeLimit and evicts the pod. The Deployment controller immediately creates a replacement pod with a fresh, empty `/tmp`.

**Why Outcome B is still the fix working correctly:**

```
                    What gets evicted?
                    ┌──────────────────────────────────────────────┐
                    │                                              │
  WITH sizeLimit:   │  Only the 1 pod that breached its limit     │
                    │  → Other repo-server replica keeps serving  │
                    │  → New pod starts in seconds, clean /tmp    │
                    │  → Zero downtime (replicas: 2)              │
                    │                                              │
                    ├──────────────────────────────────────────────┤
                    │                                              │
  WITHOUT           │  ALL pods on the node get evicted            │
  sizeLimit:        │  → repo-server, controller, redis, server   │
                    │  → Node marked DiskPressure=True             │
                    │  → Potential cascade across workloads        │
                    │  → Full outage until node recovers           │
                    │                                              │
                    └──────────────────────────────────────────────┘
```

The critical difference is **blast radius**: with sizeLimit, eviction is scoped to one pod that self-heals. Without it, the entire node is affected.

If you see Outcome B, you can verify by checking events:

```bash
kubectl get events -n argocd --sort-by='.lastTimestamp' | grep -i "ephemeral\|evict"
```

You should see something like:
```
The node was low on resource: ephemeral-storage. Evicted pod argocd-repo-server-xxx.
```

This confirms the eviction was triggered by the **pod-level emptyDir limit**, NOT by node-level disk pressure.

### 6.2 Clean Up Test File

If your pod survived (Outcome A), clean up the test file:

```bash
kubectl exec -n argocd $REPO_POD -- rm -f /tmp/testfile
```

**Why clean up?** The volume is at 100% capacity. If we leave it full, the repo-server can't do its actual work (git clones, Helm renders) because `/tmp` has no free space. Deleting the test file frees the space immediately.

```bash
# Verify space is freed
kubectl exec -n argocd $REPO_POD -- df -h /tmp
```

**Expected:** Back to ~0% used.

If your pod was replaced (Outcome B), no cleanup is needed - the new pod started with a fresh, empty `/tmp`. This is the self-healing behavior of emptyDir.

### 6.3 Controller Disk Test

Same test on the application controller to verify its emptyDir is also protected.

```bash
CTRL_POD=$(kubectl get pod -n argocd \
  -l app.kubernetes.io/name=argocd-application-controller \
  -o jsonpath='{.items[0].metadata.name}')

echo "Pod name: $CTRL_POD"

# Status before
echo "=== Pod status BEFORE test ==="
kubectl get pod -n argocd $CTRL_POD \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'

# Disk before
echo "=== Disk usage BEFORE test ==="
kubectl exec -n argocd $CTRL_POD -- df -h /tmp

# Write 5GB (should fail at 4Gi)
echo "=== Writing 5GB to /tmp ==="
kubectl exec -n argocd $CTRL_POD -- \
  dd if=/dev/zero of=/tmp/testfile bs=1M count=5000 2>&1 || true

# Disk after
echo "=== Disk usage AFTER test ==="
kubectl exec -n argocd $CTRL_POD -- df -h /tmp

# Status after
echo "=== Pod status AFTER test ==="
kubectl get pod -n argocd $CTRL_POD \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount'
```

**Expected:** Same two possible outcomes as repo-server - either pod stays Running or gets evicted and replaced. Both are correct. The key is that only the controller pod is affected, not the entire node.

```bash
# Clean up
kubectl exec -n argocd $CTRL_POD -- rm -f /tmp/testfile
```

---

## Step 7: Verify No Pod Evictions or Restarts

After both tests, confirm nothing was disrupted at the cluster level.

```bash
# Check restart counts for ALL Argo CD pods (should all be 0)
echo "=== Pod Restarts ==="
kubectl get pods -n argocd \
  -o custom-columns='NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATUS:.status.phase'
```

**Expected output:**
```
NAME                                               RESTARTS   STATUS
argocd-application-controller-0                    0          Running
argocd-applicationset-controller-xxxxxxxxx-xxxxx   0          Running
argocd-dex-server-xxxxxxxxx-xxxxx                  0          Running
argocd-notifications-controller-xxxxxxxxx-xxxxx    0          Running
argocd-redis-xxxxxxxxx-xxxxx                       0          Running
argocd-repo-server-xxxxxxxxx-xxxxx                 0          Running
argocd-repo-server-xxxxxxxxx-xxxxx                 0          Running
argocd-server-xxxxxxxxx-xxxxx                      0          Running
argocd-server-xxxxxxxxx-xxxxx                      0          Running
```

**Why all 0 restarts?** The sizeLimit contained the disk usage within each pod's emptyDir volume. No node-level disk pressure occurred, so kubelet had no reason to evict or restart any pods.

```bash
# Check for disk pressure events (should be empty)
echo "=== Disk/Eviction Events ==="
kubectl get events -n argocd --sort-by='.lastTimestamp' \
  | grep -iE "evict|disk|pressure|oom|ephemeral" || echo "None found (good)"
```

**Expected:** "None found (good)"

**Why no events?** Kubernetes events for disk pressure (`Evicted`, `DiskPressure`, `EphemeralStorageExceeded`) only fire when node-level thresholds are breached or when kubelet acts on a pod. Since our sizeLimit prevented node-level impact, no events were generated.

---

## What Happens WITHOUT sizeLimit (Default Behavior)

For comparison, here's what would happen if you ran the same test without `emptyDir.sizeLimit`:

```
Timeline WITHOUT sizeLimit:
─────────────────────────────────────────────────────────────────
 0GB    1GB    2GB    3GB    4GB    5GB
  |──────|──────|──────|──────|──────|
  Writing to /tmp (backed by NODE disk)...
                                      │
                              Node disk hits 85% usage
                                      │
                          kubelet sets DiskPressure=True
                                      │
                    ┌─────────────────┴──────────────────┐
                    │  kubelet starts evicting pods:      │
                    │  - repo-server      → Evicted       │
                    │  - other pods       → Evicted       │
                    │  - maybe controller → Evicted       │
                    └────────────────────────────────────┘
                                      │
                    Deployment/StatefulSet creates NEW pods
                    (old pod name is gone, new pod name appears)
                                      │
                    New pods start, but if the problem repeats
                    → crash loop / instability
─────────────────────────────────────────────────────────────────
```

You would see:
1. `kubectl get pod $REPO_POD` returns `NotFound` or shows `STATUS: Evicted`
2. A new pod with a **different name** appears (the Deployment created a replacement)
3. `kubectl get events` shows `Evicted: The node was low on resource: ephemeral-storage`
4. Restart count may or may not increment (eviction replaces the pod entirely)

This is exactly the instability the team was experiencing before this fix.

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

| Check | Expected | Why |
|-------|----------|-----|
| Chart version | 8.5.0 | First version with native emptyDir.sizeLimit support |
| Repo-server emptyDir sizeLimit | 4Gi | Caps `/tmp`, `plugins`, `var-files`, `helm-working-dir` |
| Controller emptyDir sizeLimit | 4Gi | Caps `argocd-application-controller-tmp` |
| 5GB write to repo-server /tmp | Fails at ~4Gi ("No space left") | sizeLimit enforced by kubelet |
| 5GB write to controller /tmp | Fails at ~4Gi ("No space left") | Same enforcement mechanism |
| Pod after disk test | Either stays Running OR gets evicted and replaced | Both are correct - see "Two Possible Outcomes" section |
| Blast radius of eviction | Only the single pod that breached the limit | Other replicas + other components unaffected |
| New pod /tmp after eviction | Clean, empty, 0% used | emptyDir is wiped on pod replacement (self-healing) |
| Node-level DiskPressure | Not triggered | Write was contained within the emptyDir volume |
| Other Argo CD pods affected | No | sizeLimit isolates disk usage per-pod |

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
