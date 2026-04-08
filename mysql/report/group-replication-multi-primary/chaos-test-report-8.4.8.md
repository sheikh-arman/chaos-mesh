# KubeDB MySQL Chaos Engineering — Multi-Primary Mode Test Report (MySQL 8.4.8)

**Date:** 2026-04-08
**Cluster:** KubeDB MySQL 8.4.8 — 3-node Group Replication (Multi-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench oltp_write_only, 12 tables x 100k rows
**Coordinator Image:** `skaliarman/mysql-coordinator:23`

---

## Cluster Under Test

| Component | Details |
|---|---|
| MySQL Version | 8.4.8 |
| Topology | Group Replication — Multi-Primary |
| Replicas | 3 nodes (all primaries) |
| Storage | 2Gi PVC per node (Durable) |
| Memory Limit | 1.5Gi (1536Mi) per pod |
| CPU Request | 500m per pod |
| GR Mode | `group_replication_single_primary_mode=OFF` |
| Coordinator | `skaliarman/mysql-coordinator:23` |

---

## Experiments Summary

| # | Experiment | Chaos Type | Data Loss | GTIDs | Checksums | Errant GTIDs | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | Pod Kill (random pod) | PodChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 2 | OOMKill (Memory Stress 1200MB) | StressChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 3 | Network Partition (3 min) | NetworkChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 4 | CPU Stress (98%, 3 min) | StressChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 5 | IO Latency (100ms, 3 min) | IOChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 6 | Network Latency (1s, 3 min) | NetworkChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 7 | Packet Loss (30%, 3 min) | NetworkChaos | Zero | MATCH | MATCH | 0 | **PASS** |
| 8 | Combined Stress (mem+cpu+load) | StressChaos x2 | Zero | MATCH | MATCH | 0 | **PASS** |
| 9 | Full Cluster Kill | kubectl delete | Zero | MATCH | MATCH | 0 | **PASS** |
| 10 | OOMKill Natural (90 JOINs) | Load | Zero | MATCH | MATCH | 0 | **PASS** |
| 11 | Scheduled Pod Kill (every 1 min, 3 min) | Schedule | Zero | MATCH | MATCH | 0 | **PASS** |
| 12 | Degraded Failover (IO + Kill) | Workflow | Zero | MATCH | MATCH | 0 | **PASS** |

---

## Detailed Results

### Experiment 1 — Pod Kill (PASS)

**Chaos YAML:** `pod-kill.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: mysql-pod-kill-multi-primary
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  gracePeriod: 0
```

| Check | Result |
|---|---|
| Pod killed | mysql-ha-cluster-0 (randomly selected) |
| Recovery time | ~30 seconds |
| GR status after recovery | All 3 nodes ONLINE as PRIMARY |
| Sysbench | Error 3101 (GR rollback during member departure — expected) |
| GTIDs | MATCH |
| Checksums | MATCH (all 4 tables identical across 3 pods) |
| Errant GTIDs | 0 |

---

### Experiment 2 — OOMKill via Memory Stress (PASS)

**Chaos YAML:** `oomkill.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: mysql-oomkill-multi-primary
  namespace: chaos-mesh
spec:
  mode: one
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  stressors:
    memory:
      workers: 2
      size: "1200MB"
  duration: "10m"
```

| Check | Result |
|---|---|
| Pod affected | mysql-ha-cluster-2 (OOMKilled, restarted) |
| Recovery time | ~3 minutes |
| GR status after recovery | All 3 nodes ONLINE as PRIMARY |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

### Experiment 3 — Network Partition (PASS)

**Chaos YAML:** `network-partition.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: mysql-network-partition-multi-primary
  namespace: chaos-mesh
spec:
  action: partition
  mode: one
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  target:
    mode: all
    selector:
      namespaces: [demo]
      labelSelectors:
        "app.kubernetes.io/instance": "mysql-ha-cluster"
  direction: both
  duration: "3m"
```

**Load:** sysbench `oltp_write_only`, 8 threads, 120s

| Check | Result |
|---|---|
| GR status during chaos | Partitioned pod went ERROR |
| Sysbench | ~1446 TPS initially, then GR rollback at ~90s (error 3101) |
| Recovery | Automatic — coordinator restarted affected pod |
| Recovery time | ~3 minutes |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

### Experiment 4 — CPU Stress 98% (PASS)

**Chaos YAML:** `cpu-stress.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: mysql-cpu-stress-multi-primary
  namespace: chaos-mesh
spec:
  mode: all
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  stressors:
    cpu:
      workers: 2
      load: 98
  duration: "3m"
```

| Check | Result |
|---|---|
| GR status during chaos | All 3 ONLINE, but Paxos consensus severely delayed |
| Sysbench | Error 3101 immediately — GR could not certify transactions under 98% CPU |
| Writes after chaos removed | Resumed normally (~730 TPS) |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

**Note:** In multi-primary mode, 98% CPU stress on all pods prevents Paxos consensus from completing, causing all write transactions to be rolled back by the GR plugin. Writes resume immediately after stress is removed. No data loss or corruption.

---

### Experiment 5 — IO Latency 100ms (PASS)

**Chaos YAML:** `io-latency.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: IOChaos
metadata:
  name: mysql-io-latency-multi-primary
  namespace: chaos-mesh
spec:
  action: latency
  mode: one
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  volumePath: "/var/lib/mysql"
  path: "/**"
  delay: "100ms"
  percent: 100
  duration: "3m"
```

**Load:** sysbench `oltp_write_only`, 8 threads, 60s

| Check | Result |
|---|---|
| TPS during chaos | 272 avg (dropped from ~1000 to 0 when IO affected pod was routed to) |
| GR status | All 3 ONLINE as PRIMARY |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

### Experiment 6 — Network Latency 1s (PASS)

**Chaos YAML:** `network-latency.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: mysql-network-latency-multi-primary
  namespace: chaos-mesh
spec:
  action: delay
  mode: all
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  target:
    mode: all
    selector:
      namespaces: [demo]
      labelSelectors:
        "app.kubernetes.io/instance": "mysql-ha-cluster"
  delay:
    latency: "1s"
    jitter: "50ms"
  duration: "3m"
  direction: both
```

**Load:** sysbench `oltp_write_only`, 8 threads, 60s

| Check | Result |
|---|---|
| TPS during chaos | 1.57 (49 transactions in 64s) |
| TPS reduction | 99.9% from baseline |
| 95th latency | 15,371ms |
| GR status | All 3 ONLINE as PRIMARY |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

### Experiment 7 — Packet Loss 30% (PASS)

**Chaos YAML:** `packet-loss.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: mysql-packet-loss-multi-primary
  namespace: chaos-mesh
spec:
  action: loss
  mode: all
  selector:
    namespaces: [demo]
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
  loss:
    loss: "30"
    correlation: "25"
  duration: "3m"
```

**Load:** sysbench `oltp_write_only`, 8 threads, 60s

| Check | Result |
|---|---|
| TPS during chaos | 4.98 (324 transactions in 65s) |
| TPS reduction | ~99.6% |
| 95th latency | 5,124ms |
| GR status | All 3 stayed ONLINE (improved with coordinator :23) |
| Errors | 0 (no `before_commit` failures this time) |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

**Note:** With coordinator image `:23`, the cluster survived 30% packet loss without any pod going to ERROR state — an improvement over the previous coordinator where all pods went ERROR.

---

### Experiment 8 — Combined Stress: Memory + CPU + Load (PASS)

**Chaos YAMLs applied simultaneously:**
- `combined-stress-memory.yaml` — 1200MB memory stress on one pod (2 workers)
- `combined-stress-cpu.yaml` — 90% CPU on all 3 pods (4 workers)

**Method:** Started 8-thread sysbench first (~943 TPS baseline), then applied both stress experiments 15 seconds later while writes were in-flight.

**Load:** sysbench `oltp_write_only`, 8 threads, 120s

| Check | Result |
|---|---|
| Baseline TPS | ~943 |
| TPS during stress | ~530 avg (dropped to 303, recovered to ~570) |
| Duration | ~110s of sustained writes before a pod was OOMKilled |
| Sysbench error | Error 3101 at T+110s (pod OOMKilled) |
| Recovery | Automatic — cluster Ready after ~2 minutes |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

**Timeline:**
| Time | Event |
|---|---|
| T+0s | Sysbench started — 8 threads, ~943 TPS |
| T+15s | Memory + CPU stress applied |
| T+20s | TPS dropped to ~303 (initial stress impact) |
| T+30s-100s | TPS stabilized at ~500-580 |
| T+110s | Pod OOMKilled — sysbench FATAL error |
| T+230s | Cluster Ready — all 3 ONLINE |

---

### Experiment 9 — Full Cluster Kill (PASS)

**Method:** `kubectl delete pod --force --grace-period=0` on all 3 pods simultaneously

| Check | Result |
|---|---|
| Action | Force-deleted all 3 MySQL pods simultaneously |
| Cluster status | Critical for ~2 minutes, then Ready |
| Recovery time | ~2 minutes |
| GR status | All 3 nodes ONLINE as PRIMARY |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

### Experiment 10 — OOMKill via Natural Load (PASS)

**Method:** 90 concurrent large JOIN queries (5-table cross-join) across all 3 pods + 4-thread sysbench oltp_write_only for 180s

| Check | Result |
|---|---|
| OOMKill triggered | **No** — MySQL 8.4.8 survived (conservative memory management) |
| TPS during load | 372 avg (67,125 transactions in 180s) |
| Errors | 0 |
| GR status | All 3 ONLINE as PRIMARY throughout |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

**Note:** MySQL 8.4.8 does not OOMKill under heavy query load (same behavior as single-primary mode). The 1.5Gi memory limit provides sufficient headroom for 8.4.8's memory allocator.

---

### Experiment 11 — Scheduled Pod Kill (PASS)

**Chaos YAML:** `scheduled-pod-kill.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: Schedule
metadata:
  name: mysql-scheduled-pod-kill-multi-primary
  namespace: chaos-mesh
spec:
  schedule: "*/1 * * * *"
  historyLimit: 5
  concurrencyPolicy: "Allow"
  type: "PodChaos"
  podChaos:
    action: pod-kill
    mode: one
    selector:
      namespaces: [demo]
      labelSelectors:
        "app.kubernetes.io/instance": "mysql-ha-cluster"
```

**Duration:** 3 minutes of scheduled kills (every 1 minute)

| Check | Result |
|---|---|
| Pods killed | All 3 pods killed at different times (ages: 3m53s, 2m53s, 113s) |
| Recovery | Each pod auto-recovered and rejoined as PRIMARY |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

### Experiment 12 — Degraded Failover: IO Latency + Pod Kill (PASS)

**Chaos YAML:** `degraded-failover.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: Workflow
metadata:
  name: mysql-degraded-failover-multi-primary
  namespace: chaos-mesh
spec:
  entry: start-degradation-and-kill
  templates:
    - name: start-degradation-and-kill
      templateType: Parallel
      children: [inject-io-latency, delayed-kill-sequence]
    - name: inject-io-latency
      templateType: IOChaos
      deadline: "2m"
      ioChaos:
        action: latency
        mode: one
        selector:
          namespaces: ["demo"]
          labelSelectors:
            "app.kubernetes.io/instance": "mysql-ha-cluster"
        volumePath: "/var/lib/mysql"
        delay: "50ms"
        percent: 100
    - name: delayed-kill-sequence
      templateType: Serial
      children: [wait-30s, kill-pod]
    - name: wait-30s
      templateType: Suspend
      deadline: "30s"
    - name: kill-pod
      templateType: PodChaos
      deadline: "1m"
      podChaos:
        action: pod-kill
        mode: one
        selector:
          namespaces: ["demo"]
          labelSelectors:
            "app.kubernetes.io/instance": "mysql-ha-cluster"
```

**Load:** sysbench `oltp_write_only`, 4 threads, 120s

| Check | Result |
|---|---|
| TPS before kill | ~616 (normal, IO latency on different pod) |
| Sysbench error | Error 3100 (`before_commit` hook failure) at ~25s when pod was killed |
| Recovery | Automatic — killed pod rejoined as PRIMARY |
| Recovery time | ~90 seconds |
| GTIDs | MATCH |
| Checksums | MATCH |
| Errant GTIDs | 0 |

---

## Performance Impact

| Experiment | Baseline TPS | TPS During Chaos | Impact |
|---|---|---|---|
| Pod Kill | ~1150 | Connection lost (error 3101) | Transient — resumes after recovery |
| OOMKill (stress) | ~1150 | Connection lost (error 3101) | Transient — resumes after recovery |
| Network Partition | ~1450 | ~1000 → 0 (error 3101 at ~90s) | Partition causes quorum loss |
| CPU Stress (98%) | ~1150 | 0 (all writes rolled back) | Paxos cannot certify |
| IO Latency (100ms) | ~1000 | ~272 | ~73% drop |
| Network Latency (1s) | ~1150 | 1.57 | 99.9% drop |
| Packet Loss (30%) | ~1150 | 4.98 | 99.6% drop |
| Combined Stress | ~943 | ~530 → OOMKill at 110s | ~44% drop then pod killed |
| Full Cluster Kill | N/A | N/A | Cluster down ~2 min |
| OOMKill Natural | ~1150 | 372 (no OOMKill) | 68% drop from query load |
| Scheduled Kill | ~1150 | Multiple disconnections | Pods auto-recover |
| Degraded Failover | ~616 | Error at 25s (pod killed) | Resumes after recovery |

---

## Key Observations

### Multi-Primary Mode Behavior

1. **No Failover Election:** All nodes are primaries. When a node departs, the remaining two continue serving writes. No election delay.

2. **GR Certification Sensitivity:** Multi-primary mode uses Paxos consensus for every write. High CPU, high concurrency, or network issues cause `error 3101` (GR rollback) — more aggressive than single-primary mode.

3. **Automatic Recovery:** All killed/failed pods rejoin as PRIMARY automatically via the coordinator.

4. **Zero Data Loss:** All 12 experiments showed complete data consistency (GTID match + checksum match) across all 3 nodes.

5. **Network Partition — Severe:** Partitioned pods go ERROR and require coordinator restart to rejoin.

6. **CPU Stress — Blocks All Writes:** 98% CPU on all pods prevents Paxos consensus entirely. Writes resume instantly after stress removed.

7. **Packet Loss — Improved with coordinator :23:** 30% packet loss no longer causes ERROR state (previously all pods went ERROR with older coordinator).

### Comparison: Multi-Primary vs Single-Primary

| Aspect | Multi-Primary | Single-Primary |
|---|---|---|
| Failover needed | No (all primaries) | Yes (election ~2-3s) |
| Write availability | All nodes writable | Only primary writable |
| Pod kill impact | Other 2 nodes continue writes | Election needed, brief pause |
| CPU stress 98% | All writes blocked (Paxos fails) | ~46% TPS reduction |
| IO latency TPS | ~272 | ~3.5 |
| Network latency TPS | 1.57 | ~1.3 |
| Packet loss 30% | 4.98 TPS (stayed ONLINE) | Failover triggered |
| High concurrency | GR certification conflicts (3101) | No conflicts (single writer) |
| Recovery mechanism | Rejoin as PRIMARY | Election + rejoin |

---

## Summary

| Metric | Value |
|---|---|
| MySQL Version | 8.4.8 |
| Coordinator | `skaliarman/mysql-coordinator:23` |
| Experiments run | 12 |
| Data loss | **Zero** across all experiments |
| Checksum mismatches (after settling) | **Zero** |
| GTID mismatches (after settling) | **Zero** |
| Split-brain incidents | **Zero** |
| Errant GTIDs | **Zero** |
| Cluster auto-recovered | All 12 experiments |

**Verdict: All 12 experiments PASSED on MySQL 8.4.8 Multi-Primary mode with coordinator :23. Zero data loss, zero split-brain, zero errant GTIDs. The cluster auto-recovers from all tested failure scenarios.**
