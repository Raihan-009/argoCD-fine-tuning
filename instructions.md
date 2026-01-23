## Title
Improve Argo CD performance, sync reliability, and resource efficiency

## Type
Platform / Infrastructure Improvement


📌 Background

Argo CD currently manages deployments across dev, QA, and prod clusters.
We’ve experienced:

- Repo-server instability due to disk pressure

- Slower syncs during peak deployment windows

- Risk of failed syncs under load

This ticket focuses on performance tuning and stability, not HA topology.

🎯 Objectives

- Reduce sync latency (p95)

- Eliminate repo-server disk exhaustion issues

- Improve reliability during deployment bursts

- Ensure predictable resource behavior under load

🛠 Scope of Work

1. Repo-server tuning

- Mount /tmp using emptyDir with explicit sizeLimit

- Evaluate PVC vs emptyDir tradeoffs (document decision)

- Ensure repo-server cache isolation per pod

2. Resource optimization

- Set explicit CPU/memory requests & limits for:

  - repo-server

  - application-controller

  - argocd-server

- Validate no throttling under expected load

3. Sync performance

- Tune application-controller parallelism

- Validate impact on:

  - p50 / p95 sync duration

  - failed sync rate

4. Git & chart fetch reliability

- Review Git timeout & retry settings

- Validate behavior during Git provider latency or rate limits

📊 Success Metrics (Must Be Measured)

Baseline vs post-change comparison over 7–14 days:

- ⬇️ p95 argocd_app_sync_duration_seconds

- ⬇️ Failed sync rate

- ⬇️ Repo-server restarts/week → target: 0

- ⬇️ Manual intervention required during deployments

🔍 Validation Checklist

- No repo-server crashes due to disk pressure

- Sync latency stable under load

- No increase in controller reconciliation backlog

- Metrics visible in Prometheus/Grafana

📄 Deliverables

- Helm values.yaml changes

- Performance benchmark (before vs after)

- Short design note explaining tuning choices

- Rollback plan

🚫 Out of Scope

- HA topology

- Multi-cluster Argo CD architecture

- Disaster recovery
