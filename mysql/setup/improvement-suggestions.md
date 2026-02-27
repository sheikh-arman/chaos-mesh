# KubeDB MySQL — Improvement Suggestions

Based on chaos test results and cluster configuration review (2026-02-27).

---

## 1. Memory Limits Are Too Tight

**Problem:** The memory stress retest with 1.5GB confirmed this risk — `mysql-ha-cluster-0` was **OOMKilled (Exit Code 137)** within ~1 second of the stressor allocating memory, exceeding the 2Gi pod limit. The initial 1GB test left only 55Mi of headroom.

**Fix:** Increase memory limit and explicitly size the InnoDB buffer pool.

```yaml
# kubedb-mysql.yaml
podTemplate:
  spec:
    containers:
      - name: mysql
        resources:
          limits:
            memory: 4Gi
            cpu: 2
          requests:
            cpu: 500m
            memory: 2Gi
```

Create a MySQL config secret and reference it:

```ini
# my-mysql-config.cnf
[mysqld]
innodb_buffer_pool_size     = 2G   # ~50–70% of memory limit
innodb_buffer_pool_instances = 2
```

```yaml
spec:
  configSecret:
    name: my-mysql-config
```

---

## 2. Failover Time is 30–38s — Can Be Reduced

**Problem:** Both pod-kill and network partition tests showed 30–38 seconds before a new primary was elected. This is the default Group Replication failure detector behavior.

**Fix:** Tune GR timeouts in the MySQL config:

```ini
[mysqld]
# How long before an unreachable member is expelled (default 5s)
group_replication_member_expel_timeout = 5

# How long before a partitioned primary stops accepting writes
group_replication_unreachable_majority_timeout = 10

# Number of auto-rejoin attempts after expulsion
group_replication_autorejoin_tries = 3
```

**Expected result:** Failover time reduced from ~30–38s to ~10–15s.

---

## 3. Write Latency Explodes Under Network Delay

**Problem:** A 1s network delay between primary and replicas caused a **41x write latency increase** (100ms → 4133ms). This is inherent to Group Replication's Paxos consensus — every write needs a majority round-trip ack before commit.

**Fix:** Tune flow control to throttle the primary before queues overflow, and ensure low inter-pod network latency in production:

```ini
[mysqld]
group_replication_flow_control_mode                = QUOTA
group_replication_flow_control_applier_threshold   = 25000
group_replication_flow_control_certifier_threshold = 25000
```

**Operational fix:** In production, ensure MySQL pods are on nodes with < 1ms inter-node latency. Use pod affinity to place MySQL pods in the same availability zone.

---

## 4. Storage is Too Small

**Problem:** 2Gi storage per node is only suitable for testing. Any real dataset will exhaust this quickly.

**Fix:** Size storage based on expected dataset + 2–3x growth headroom. Enable `StorageClass` with `allowVolumeExpansion: true`:

```yaml
spec:
  storage:
    storageClassName: standard   # ensure this SC supports expansion
    resources:
      requests:
        storage: 20Gi            # adjust to actual dataset size
```

---

## 5. Deletion Policy is `Delete` — Dangerous

**Problem:** The current config uses `deletionPolicy: Delete`, which means a `kubectl delete mysql mysql-ha-cluster` will permanently destroy all PVCs and data.

**Fix:** Change to `DoNotTerminate` to block accidental deletion, or `WipeOut` to make the destructive intent explicit:

```yaml
spec:
  deletionPolicy: DoNotTerminate   # prevents accidental kubectl delete
```

| Policy | Behavior |
|---|---|
| `Delete` | Deletes pods and PVCs — **data is lost** |
| `Halt` | Deletes pods, keeps PVCs — data preserved |
| `WipeOut` | Explicitly deletes everything including secrets |
| `DoNotTerminate` | Blocks deletion entirely until policy is changed |

---

## 6. All Pods on One Node — Defeats HA

**Problem:** In the test cluster all pods run on `kind-control-plane`. A real node failure would take down all 3 MySQL pods simultaneously. True HA requires pods spread across nodes.

**Fix:** Add pod anti-affinity to the MySQL spec:

```yaml
podTemplate:
  spec:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/instance: mysql-ha-cluster
            topologyKey: kubernetes.io/hostname
```

This forces the scheduler to place each MySQL pod on a different Kubernetes node, ensuring a node failure only takes down 1 of 3 members.

---

## 7. Enable Monitoring (Already in Config, Just Commented Out)

**Problem:** The Prometheus monitoring config exists in `kubedb-mysql.yaml` but is commented out. Without metrics, there is no visibility into GR lag, query throughput, or InnoDB health.

**Fix:** Uncomment and enable:

```yaml
spec:
  monitor:
    agent: prometheus.io/operator
    prometheus:
      exporter:
        port: 56790
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
      serviceMonitor:
        interval: 30s
        labels:
          release: prometheus
```

**Key metrics to alert on:**

| Metric | Alert Condition |
|---|---|
| `mysql_global_status_innodb_row_lock_waits` | > threshold |
| `performance_schema.replication_group_members` | any `MEMBER_STATE != 'ONLINE'` |
| `COUNT_TRANSACTIONS_REMOTE_IN_APPLIER_QUEUE` | growing queue = replica falling behind |
| Pod memory usage | > 80% of limit |
| PVC usage | > 80% of capacity |

---

## 8. Add ProxySQL for Transparent Failover

**Problem:** Applications must reconnect after a primary failover (30–38s downtime gap). There is no stable write endpoint that survives a primary change.

**Fix:** Deploy KubeDB-managed ProxySQL as a connection proxy in front of the MySQL cluster:

```yaml
apiVersion: kubedb.com/v1
kind: ProxySQL
metadata:
  name: mysql-proxysql
  namespace: demo
spec:
  version: "2.3.2"
  replicas: 1
  backend:
    name: mysql-ha-cluster
```

**Benefits:**
- Provides a single stable write endpoint — applications do not need reconnect logic
- Automatically routes writes to the current primary
- Provides connection pooling, reducing connection overhead on the MySQL pods
- Reduces application-visible failover downtime from ~30s to near-zero

---

## Priority Summary

| Priority | Change | Why |
|---|---|---|
| **High** | Increase memory limit to 4Gi | Chaos test showed only 55Mi headroom — OOM risk |
| **High** | Set `deletionPolicy: DoNotTerminate` | Prevent accidental permanent data loss |
| **High** | Add pod anti-affinity rules | True HA requires pods on different nodes |
| **Medium** | Tune GR expel/unreachable timeout | Reduce failover 30–38s → 10–15s |
| **Medium** | Enable Prometheus monitoring | Production observability |
| **Medium** | Tune InnoDB buffer pool explicitly | Better memory utilization and query performance |
| **Low** | Add ProxySQL | Transparent failover; no app reconnect needed |
| **Low** | Increase storage beyond 2Gi | 2Gi is testing-only capacity |

---

*Based on chaos test run: `setup/chaos-test-report.md`*
