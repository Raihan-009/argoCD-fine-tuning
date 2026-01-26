# Prometheus Monitoring Setup for Argo CD

This guide walks through setting up Prometheus and Grafana to monitor Argo CD performance metrics, specifically:
- **p50/p95 sync duration** - How long syncs take
- **Failed sync rate** - Percentage of failed syncs
- **Workqueue depth** - Queue backlog indicator

---

## Why Prometheus?

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      WITHOUT PROMETHEUS                                  │
│                                                                          │
│   You: "Is Argo CD performing well?"                                    │
│   Answer: "I don't know... apps seem to sync... sometimes slow?"        │
│                                                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                       WITH PROMETHEUS                                    │
│                                                                          │
│   You: "Is Argo CD performing well?"                                    │
│   Answer: "Yes! p95 sync duration is 2.3s, fail rate is 0.5%,          │
│            workqueue depth averages 3. Here's the graph."               │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**Prometheus gives you:**
- Actual numbers instead of guesses
- Historical data to compare before/after tuning
- Alerts when things go wrong
- Pretty graphs in Grafana

---

## Prerequisites

- Kind cluster running
- Argo CD installed
- Helm installed

```bash
# Verify everything is ready
kubectl get nodes
kubectl get pods -n argocd
helm version
```

---

## Step 1: Install Prometheus Stack

### 1.1 Add Helm Repository

```bash
# Add the prometheus-community Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# Update repo cache
helm repo update
```

**Why?** The `kube-prometheus-stack` chart includes:
- Prometheus (metrics collection)
- Grafana (visualization)
- AlertManager (alerts)
- Pre-configured dashboards

### 1.2 Create Monitoring Namespace

```bash
kubectl create namespace monitoring
```

**Why?** Keep monitoring components separate from application workloads.

### 1.3 Install Prometheus Stack

```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
```

**Why the flag?**
- `serviceMonitorSelectorNilUsesHelmValues=false` tells Prometheus to discover ALL ServiceMonitors, not just ones with specific labels. This ensures it finds our Argo CD ServiceMonitors.

### 1.4 Verify Installation

```bash
# Check all pods are running
kubectl get pods -n monitoring

# Expected output (all should be Running):
# NAME                                                     READY   STATUS
# prometheus-grafana-xxx                                   3/3     Running
# prometheus-kube-prometheus-operator-xxx                  1/1     Running
# prometheus-kube-state-metrics-xxx                        1/1     Running
# prometheus-prometheus-kube-prometheus-prometheus-0       2/2     Running
# alertmanager-prometheus-kube-prometheus-alertmanager-0   2/2     Running
```

**Wait until all pods are Running before proceeding.**

---

## Step 2: Create Argo CD Metrics Services

Argo CD exposes metrics, but we need Services to expose them for Prometheus to scrape.

### 2.1 Create Metrics Services

```bash
kubectl apply -f - <<EOF
---
# Service for Application Controller metrics (port 8082)
apiVersion: v1
kind: Service
metadata:
  name: argocd-metrics
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-metrics
    app.kubernetes.io/part-of: argocd
spec:
  ports:
    - name: metrics
      port: 8082
      targetPort: 8082
      protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-application-controller
---
# Service for Argo CD Server metrics (port 8083)
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-metrics
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-server-metrics
    app.kubernetes.io/part-of: argocd
spec:
  ports:
    - name: metrics
      port: 8083
      targetPort: 8083
      protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-server
---
# Service for Repo Server metrics (port 8084)
apiVersion: v1
kind: Service
metadata:
  name: argocd-repo-server-metrics
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-repo-server-metrics
    app.kubernetes.io/part-of: argocd
spec:
  ports:
    - name: metrics
      port: 8084
      targetPort: 8084
      protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-repo-server
EOF
```

**Why?**
- Argo CD components expose metrics on specific ports
- Prometheus needs a Kubernetes Service to discover and scrape them
- Each component has different metrics (controller has sync metrics, repo-server has git metrics)

### 2.2 Verify Services Created

```bash
kubectl get svc -n argocd | grep metrics
```

**Expected output:**
```
argocd-metrics              ClusterIP   10.96.x.x    <none>   8082/TCP
argocd-repo-server-metrics  ClusterIP   10.96.x.x    <none>   8084/TCP
argocd-server-metrics       ClusterIP   10.96.x.x    <none>   8083/TCP
```

---

## Step 3: Create ServiceMonitors

ServiceMonitors tell Prometheus which services to scrape.

### 3.1 Create ServiceMonitors for Argo CD

```bash
kubectl apply -f - <<EOF
---
# Monitor Application Controller (sync metrics, reconcile duration)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: argocd
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
      interval: 15s
---
# Monitor Argo CD Server (API metrics)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-server-metrics
  namespace: argocd
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server-metrics
  endpoints:
    - port: metrics
      interval: 15s
---
# Monitor Repo Server (git clone metrics)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-repo-server-metrics
  namespace: argocd
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server-metrics
  endpoints:
    - port: metrics
      interval: 15s
EOF
```

**Why?**
- `interval: 15s` - Scrape metrics every 15 seconds
- `release: prometheus` label - Ensures Prometheus discovers these monitors
- Separate monitors for each component to track different metrics

### 3.2 Verify ServiceMonitors Created

```bash
kubectl get servicemonitor -n argocd
```

**Expected output:**
```
NAME                         AGE
argocd-metrics               10s
argocd-repo-server-metrics   10s
argocd-server-metrics        10s
```

---

## Step 4: Verify Prometheus is Scraping Argo CD

### 4.1 Access Prometheus UI

```bash
# Port-forward Prometheus (keep this running)
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

Open browser: http://localhost:9090

### 4.2 Check Targets

1. Go to: **Status** → **Targets**
2. Look for `serviceMonitor/argocd/argocd-metrics`
3. Status should be **UP** (green)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Prometheus Targets                                                      │
│                                                                          │
│  serviceMonitor/argocd/argocd-metrics (1/1 up)                          │
│    └─ http://10.244.0.15:8082/metrics    State: UP    Last Scrape: 5s  │
│                                                                          │
│  serviceMonitor/argocd/argocd-server-metrics (1/1 up)                   │
│    └─ http://10.244.0.16:8083/metrics    State: UP    Last Scrape: 8s  │
│                                                                          │
│  serviceMonitor/argocd/argocd-repo-server-metrics (2/2 up)              │
│    └─ http://10.244.0.17:8084/metrics    State: UP    Last Scrape: 3s  │
│    └─ http://10.244.0.18:8084/metrics    State: UP    Last Scrape: 3s  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**If targets show DOWN:** Wait 1-2 minutes for Prometheus to discover the new ServiceMonitors.

### 4.3 Test a Query

In Prometheus UI, go to **Graph** and run:

```promql
argocd_app_info
```

You should see results if any Argo CD applications exist.

---

## Step 5: Access Grafana

### 5.1 Port-Forward Grafana

```bash
# In a new terminal
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open browser: http://localhost:3000

### 5.2 Login

- **Username:** `admin`
- **Password:** `prom-operator`

### 5.3 Import Argo CD Dashboard

1. Click **Dashboards** (left sidebar) → **Import**
2. Enter Dashboard ID: **14584**
3. Click **Load**
4. Select **Prometheus** as data source
5. Click **Import**

This gives you a pre-built Argo CD dashboard.

---

## Step 6: Key Metrics to Monitor

### 6.1 Sync Duration (p50/p95)

**What it measures:** How long sync operations take

**Query for p50 (median):**
```promql
histogram_quantile(0.50, sum(rate(argocd_app_reconcile_bucket[5m])) by (le))
```

**Query for p95 (95th percentile):**
```promql
histogram_quantile(0.95, sum(rate(argocd_app_reconcile_bucket[5m])) by (le))
```

**What to look for:**

| Value | Meaning |
|-------|---------|
| p50 < 2s | Good - most syncs are fast |
| p95 < 10s | Good - even slow syncs aren't too bad |
| p95 > 30s | Bad - some syncs are very slow |

### 6.2 Failed Sync Rate

**What it measures:** Percentage of syncs that failed

**Query:**
```promql
(
  sum(rate(argocd_app_sync_total{phase=~"Failed|Error"}[5m]))
  /
  sum(rate(argocd_app_sync_total[5m]))
) * 100
```

**What to look for:**

| Value | Meaning |
|-------|---------|
| < 1% | Excellent |
| 1-5% | Acceptable |
| > 5% | Problem - investigate failures |

### 6.3 Workqueue Depth

**What it measures:** Number of items waiting to be processed

**Query:**
```promql
workqueue_depth{namespace="argocd"}
```

**What to look for:**

| Value | Meaning |
|-------|---------|
| 0-5 | Healthy - queue is being processed |
| 5-15 | Moderate load |
| 15+ | Bottleneck - increase parallelism |

### 6.4 Sync Total by Phase

**What it measures:** Count of syncs by outcome

**Query:**
```promql
sum(argocd_app_sync_total) by (phase)
```

**Phases:**
- `Succeeded` - Sync completed successfully
- `Failed` - Sync failed
- `Error` - Sync encountered an error
- `Running` - Sync in progress

---

## Step 7: Run Load Test and Observe

Now the interesting part - observe metrics during a load test!

### 7.1 Setup: Open Multiple Terminals

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Terminal 1: Prometheus UI                                               │
│  kubectl port-forward svc/prometheus-kube-prometheus-prometheus \       │
│    -n monitoring 9090:9090                                               │
├─────────────────────────────────────────────────────────────────────────┤
│  Terminal 2: Grafana UI                                                  │
│  kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80      │
├─────────────────────────────────────────────────────────────────────────┤
│  Terminal 3: Load test commands                                          │
│  (where you'll run kubectl commands)                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Before Load Test: Record Baseline Metrics

In Prometheus UI (http://localhost:9090), run each query and note the values:

```bash
# Record these values BEFORE load test
echo "=== BEFORE LOAD TEST ==="
echo "Time: $(date)"
echo "p50 sync duration: ____"
echo "p95 sync duration: ____"
echo "Failed sync rate: ____"
echo "Workqueue depth: ____"
```

### 7.3 Start Load Test

**In Terminal 3, create 30 applications:**

```bash
echo "Starting load test at $(date)"

for i in $(seq 1 30); do
  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: prom-test-$i
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: prom-test-ns-$i
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
done

echo "Load test started at $(date)"
```

### 7.4 During Load Test: What to Observe

**In Prometheus UI, watch these queries in real-time:**

| Query | What You'll See |
|-------|-----------------|
| `workqueue_depth{namespace="argocd"}` | Spike up, then gradually decrease |
| `sum(rate(argocd_app_sync_total[1m])) by (phase)` | Succeeded count increasing |
| `histogram_quantile(0.95, sum(rate(argocd_app_reconcile_bucket[1m])) by (le))` | p95 latency during load |

**In Grafana (Argo CD Dashboard):**
- Watch the "Application Sync Stats" panel
- Watch the "Reconciliation Performance" panel

### 7.5 What Good Results Look Like

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DURING LOAD TEST (Tuned Config)                       │
│                                                                          │
│  Workqueue Depth:                                                        │
│  ────────────────                                                        │
│    Start:    0                                                           │
│    Peak:     8  (spike when apps created)                               │
│    After 1m: 2  (queue draining fast)                                   │
│    After 2m: 0  (all processed)                                         │
│                                                                          │
│  p95 Sync Duration:                                                      │
│  ──────────────────                                                      │
│    During load: 3-5 seconds                                             │
│    After load:  1-2 seconds                                             │
│                                                                          │
│  Sync Results:                                                           │
│  ─────────────                                                           │
│    Succeeded: 30                                                         │
│    Failed: 0                                                             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.6 After Load Test: Record Final Metrics

Wait for all apps to sync (2-3 minutes), then record:

```bash
# Record these values AFTER load test
echo "=== AFTER LOAD TEST ==="
echo "Time: $(date)"
echo "p50 sync duration: ____"
echo "p95 sync duration: ____"
echo "Failed sync rate: ____"
echo "Total syncs succeeded: ____"
echo "Total syncs failed: ____"
```

---

## Step 8: Compare Baseline vs Tuned

Run the same load test twice:
1. First with **default** Argo CD config
2. Then with **tuned** config

### Comparison Table

| Metric | Baseline (Default) | Tuned | Improvement |
|--------|-------------------|-------|-------------|
| p50 sync duration | ___ s | ___ s | ___% faster |
| p95 sync duration | ___ s | ___ s | ___% faster |
| Peak workqueue depth | ___ | ___ | ___% lower |
| Time to clear queue | ___ s | ___ s | ___% faster |
| Failed syncs | ___ | ___ | ___% fewer |
| Pod restarts | ___ | ___ | Should be 0 |

### Expected Improvements

| Metric | Expected Baseline | Expected Tuned |
|--------|------------------|----------------|
| p95 sync duration | 15-30s | 3-8s |
| Peak workqueue | 20-30 | 5-10 |
| Failed sync rate | 2-10% | <1% |

---

## Step 9: Cleanup

### Delete Test Applications

```bash
for i in $(seq 1 30); do
  kubectl delete application prom-test-$i -n argocd --ignore-not-found=true &
  kubectl delete namespace prom-test-ns-$i --ignore-not-found=true &
done
wait
```

### (Optional) Remove Prometheus Stack

```bash
helm uninstall prometheus -n monitoring
kubectl delete namespace monitoring
```

---

## Quick Reference: Prometheus Queries

| Metric | Query |
|--------|-------|
| **p50 Sync Duration** | `histogram_quantile(0.50, sum(rate(argocd_app_reconcile_bucket[5m])) by (le))` |
| **p95 Sync Duration** | `histogram_quantile(0.95, sum(rate(argocd_app_reconcile_bucket[5m])) by (le))` |
| **Failed Sync Rate %** | `(sum(rate(argocd_app_sync_total{phase=~"Failed\|Error"}[5m])) / sum(rate(argocd_app_sync_total[5m]))) * 100` |
| **Total Syncs by Phase** | `sum(argocd_app_sync_total) by (phase)` |
| **Workqueue Depth** | `workqueue_depth{namespace="argocd"}` |
| **Sync Rate (per second)** | `sum(rate(argocd_app_sync_total[5m]))` |
| **Controller Memory** | `container_memory_usage_bytes{namespace="argocd",container="application-controller"}` |
| **Repo-Server Memory** | `container_memory_usage_bytes{namespace="argocd",container="repo-server"}` |
| **Active Apps** | `count(argocd_app_info)` |

---

## Troubleshooting

### Prometheus Not Scraping Argo CD

**Check 1:** ServiceMonitors exist
```bash
kubectl get servicemonitor -n argocd
```

**Check 2:** Services exist and have endpoints
```bash
kubectl get endpoints -n argocd | grep metrics
```

**Check 3:** Prometheus targets (in UI)
- Go to http://localhost:9090/targets
- Look for argocd targets
- Check error messages if DOWN

### No Data in Grafana

**Check 1:** Prometheus has data
```bash
# In Prometheus UI, try:
argocd_app_info
```

**Check 2:** Correct data source selected in Grafana
- Go to dashboard settings
- Verify Prometheus is selected

### Metrics Return Empty

**Possible cause:** No applications exist or no syncs have happened

**Solution:** Create some test applications first
```bash
kubectl get applications -n argocd
# If empty, create test apps
```
