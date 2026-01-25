# Kind Cluster Setup Guide

This guide walks through setting up a multi-node Kind (Kubernetes in Docker) cluster on macOS for testing Argo CD performance tuning.

## Prerequisites

### 1. Install Docker Desktop

Kind requires Docker to run. If you don't have Docker installed:

```bash
# Install via Homebrew
brew install --cask docker

# Start Docker Desktop from Applications
# Ensure Docker is running before proceeding
```

**Recommended Docker Settings:**
- Memory: 8GB minimum (16GB recommended for 4-node cluster)
- CPUs: 4 minimum (6+ recommended)
- Disk: 60GB+

To adjust: Docker Desktop → Settings → Resources

### 2. Install Kind

```bash
# Install kind via Homebrew
brew install kind

# Verify installation
kind version
```

### 3. Install kubectl

```bash
# Install kubectl via Homebrew
brew install kubectl

# Verify installation
kubectl version --client
```

### 4. Install Helm

```bash
# Install Helm via Homebrew
brew install helm

# Verify installation
helm version
```

---

## Cluster Configuration

### Multi-Node Cluster Configuration

Create the cluster configuration file:

```bash
# Create directory for kind configs
mkdir -p ~/.kind
```

Create `~/.kind/argocd-cluster.yaml`:

```yaml
# Kind cluster configuration for Argo CD performance testing
# 4 nodes: 1 control-plane + 3 workers
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: argocd-perf-test
nodes:
  # Control plane node
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # HTTP - for Argo CD UI access
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      # HTTPS - for Argo CD UI access
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      # NodePort range for services
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP

  # Worker nodes for workload distribution
  - role: worker
    labels:
      node-type: workload
  - role: worker
    labels:
      node-type: workload
  - role: worker
    labels:
      node-type: workload

# Networking configuration
networking:
  # Use default CNI (kindnet)
  disableDefaultCNI: false
  # Pod subnet
  podSubnet: "10.244.0.0/16"
  # Service subnet
  serviceSubnet: "10.96.0.0/12"
```

---

## Create the Cluster

### Step 1: Create the Kind Cluster

```bash
# Create cluster using the configuration
kind create cluster --config ~/.kind/argocd-cluster.yaml

# Expected output:
# Creating cluster "argocd-perf-test" ...
#  ✓ Ensuring node image (kindest/node:v1.31.0)
#  ✓ Preparing nodes
#  ✓ Writing configuration
#  ✓ Starting control-plane
#  ✓ Installing CNI
#  ✓ Installing StorageClass
#  ✓ Joining worker nodes
# Set kubectl context to "kind-argocd-perf-test"
```

### Step 2: Verify Cluster Status

```bash
# Check cluster info
kubectl cluster-info --context kind-argocd-perf-test

# List all nodes
kubectl get nodes -o wide

# Expected output:
# NAME                             STATUS   ROLES           AGE   VERSION
# argocd-perf-test-control-plane   Ready    control-plane   1m    v1.31.0
# argocd-perf-test-worker          Ready    <none>          1m    v1.31.0
# argocd-perf-test-worker2         Ready    <none>          1m    v1.31.0
# argocd-perf-test-worker3         Ready    <none>          1m    v1.31.0
```

### Step 3: Verify Node Resources

```bash
# Check node capacity and allocatable resources
kubectl describe nodes | grep -A 5 "Capacity:\|Allocatable:"
```

---

## Install Metrics Server (Optional but Recommended)

Metrics server enables `kubectl top` commands for monitoring:

```bash
# Install metrics server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch for Kind (disable TLS verification for kubelet)
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Wait for metrics server to be ready
kubectl wait --for=condition=available deployment/metrics-server -n kube-system --timeout=120s

# Verify (wait ~60s after deployment)
kubectl top nodes
```

---

## Install NGINX Ingress Controller (Optional)

For accessing Argo CD via ingress:

```bash
# Install NGINX ingress controller for Kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for ingress controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s
```

---

## Cluster Management Commands

### View Cluster Status

```bash
# List all kind clusters
kind get clusters

# Get cluster kubeconfig
kind get kubeconfig --name argocd-perf-test

# View all pods across namespaces
kubectl get pods -A
```

### Switch kubectl Context

```bash
# Switch to kind cluster context
kubectl config use-context kind-argocd-perf-test

# Verify current context
kubectl config current-context
```

### Delete Cluster

```bash
# Delete the cluster when done
kind delete cluster --name argocd-perf-test
```

### Restart Cluster

Kind clusters persist across Docker restarts. If Docker was restarted:

```bash
# Check if cluster containers are running
docker ps -a | grep argocd-perf-test

# If containers are stopped, start Docker Desktop
# The cluster should automatically recover
```

---

## Troubleshooting

### Issue: Cluster Creation Fails

```bash
# Check Docker is running
docker info

# Check available disk space
df -h

# Delete any existing cluster with same name
kind delete cluster --name argocd-perf-test

# Retry creation
kind create cluster --config ~/.kind/argocd-cluster.yaml
```

### Issue: Nodes Not Ready

```bash
# Check node conditions
kubectl describe nodes | grep -A 10 "Conditions:"

# Check system pods
kubectl get pods -n kube-system

# View logs from a specific node
docker logs argocd-perf-test-control-plane
```

### Issue: Insufficient Resources

If you see resource-related errors:

1. Increase Docker Desktop resources (Memory/CPU)
2. Reduce to 3 nodes (1 control-plane + 2 workers)
3. Close other resource-intensive applications

```yaml
# Minimal 3-node configuration
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

### Issue: Port Already in Use

```bash
# Check what's using port 80/443
lsof -i :80
lsof -i :443

# Modify extraPortMappings in cluster config to use different ports
extraPortMappings:
  - containerPort: 80
    hostPort: 8080  # Changed
  - containerPort: 443
    hostPort: 8443  # Changed
```

---

## Resource Requirements Summary

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| Docker Memory | 8GB | 16GB |
| Docker CPUs | 4 | 6+ |
| Docker Disk | 40GB | 60GB+ |
| Nodes | 3 | 4 |

---

## Next Steps

Once your Kind cluster is running:

1. Proceed to [02-argocd-helm-installation.md](./02-argocd-helm-installation.md) to install Argo CD
2. The Helm values will include all performance tuning configurations

---

## Quick Reference

```bash
# One-liner to create cluster
kind create cluster --config ~/.kind/argocd-cluster.yaml

# Verify everything is ready
kubectl get nodes && kubectl get pods -A

# Clean up when done
kind delete cluster --name argocd-perf-test
```
