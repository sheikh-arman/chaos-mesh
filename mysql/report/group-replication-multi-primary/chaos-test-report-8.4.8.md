# KubeDB MySQL Chaos Engineering — Multi-Primary Mode Test Report (MySQL 8.4.8)

**Date:** 2026-04-08
**Cluster:** KubeDB MySQL 8.4.8 — 3-node Group Replication (Multi-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench, 12 tables x 100k rows

---

## Cluster Under Test

| Component | Details |
|---|---|
| MySQL Version | 8.4.8 |
| Topology | Group Replication — Multi-Primary |
| Replicas | 3 nodes (all primaries) |
| Memory Limit | 1.5Gi (1536Mi) per pod |
| GR Mode | `group_replication_single_primary_mode=OFF` |

---

## Experiments Summary

| # | Experiment | Status | Failover | Data Loss | GTIDs | Checksums | Errant GTIDs | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | Pod Kill (random pod) | DONE | No | Zero | MATCH | MATCH | 0 | PASS |
| 2 | OOMKill (Memory Stress 1200MB) | DONE | No | Zero | MATCH | MATCH | 0 | PASS |
| 3 | Network Partition (3 min) | DONE | No | Zero | MATCH | MATCH | 0 | PASS |
| 4 | CPU Stress (98%, 3 min) | DONE | No | Zero | MATCH | MATCH | 0 | PASS |
| 5 | IO Latency (100ms, 3 min) | DONE | No | Zero | MATCH | MATCH | 0 | PASS |
| 6 | Network Latency (1s, 3 min) | DONE | No | Zero | MATCH | MATCH | 0 | PASS |
| 7 | Packet Loss (30%, 3 min) | DONE | No (all ERROR, recovered) | Zero | MATCH | MATCH | 0 | PASS |
| 8 | Combined Stress (mem+cpu+load) | DONE | No (survived) | Zero | MATCH | MATCH | 0 | PASS |
| 9 | Full Cluster Kill | DONE | N/A | Zero | MATCH | MATCH | 0 | PASS |
| 10 | OOMKill Natural (128 threads) | PENDING | — | — | — | — | — | — |
| 11 | Scheduled Pod Kill (every 30s) | PENDING | — | — | — | — | — | — |
| 12 | Degraded Failover (IO + Kill) | PENDING | — | — | — | — | — | — |

---

## Detailed Results

### Experiment 1 — Pod Kill (PASS)

| Check | Result |
|---|---|
| Pod killed | mysql-ha-cluster-0 (randomly selected) |
| Recovery time | ~30 seconds |
| GR status | All 3 nodes ONLINE as PRIMARY |
| Tracking rows | 114,872 (all pods) |
| GTIDs | MATCH |
| Checksums | MATCH (2616143660) |
| Errant GTIDs | 0 |

**Load during test:** 229,212 transactions, ~764 TPS

### Experiment 2 — OOMKill via Memory Stress (PASS)

| Check | Result |
|---|---|
| Pod affected | mysql-ha-cluster-1 (restarted) |
| Recovery time | ~5 minutes |
| GR status | All 3 nodes ONLINE as PRIMARY |
| Tracking rows | 135,805 (all pods) |
| GTIDs | MATCH |
| Checksums | MATCH (3250931608) |
| Errant GTIDs | 0 |

**Load during test:** 412,959 transactions, ~688 TPS

### Experiment 3 — Network Partition (PASS)

| Check | Result |
|---|---|
| Action | All pods partitioned from each other for 3 minutes |
| GR status | All 3 nodes became ERROR during partition |
| Recovery | Automatic after chaos removed |
| Recovery time | ~2 minutes (coordinator restarted pod-0) |
| Tracking rows | 144,186 (all pods) |
| GTIDs | MATCH |
| Errant GTIDs | 0 |

**Load during test:** 222,442 transactions, ~370 TPS

**Note:** During network partition, all pods showed ERROR state ("Invalid Protocol"). After removing the partition, the coordinator automatically restarted the failed pod and restored the cluster.

### Experiment 4 — CPU Stress (PASS)

| Check | Result |
|---|---|
| Action | 98% CPU load on all 3 pods for 3 minutes |
| GR status | All 3 nodes remained ONLINE as PRIMARY |
| Tracking rows | 152,567 (all pods) |
| GTIDs | MATCH (23d4ccb6-6256-4f11-91f7-3126f6415798:1-1136332) |
| Errant GTIDs | 0 |

**Load during test:** 270,427 transactions, ~450 TPS

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
| TPS during chaos | 3.63 (225 transactions in 62s) |
| TPS reduction | 99.7% from baseline |
| 95th latency | 3,040ms |
| GR status | All 3 nodes ONLINE as PRIMARY |
| GTIDs | MATCH (23d4ccb6-...:1-1136705) |
| Checksums | MATCH (all 4 tables identical across 3 pods) |
| Errant GTIDs | 0 |

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
| TPS during chaos | 0.73 (49 transactions in 68s) |
| TPS reduction | 99.9% from baseline |
| 95th latency | 22,034ms |
| GR status | All 3 nodes ONLINE as PRIMARY |
| GTIDs | MATCH (23d4ccb6-...:1-1136776) |
| Checksums | MATCH (all 4 tables identical across 3 pods) |
| Errant GTIDs | 0 |

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
| GR status during chaos | All nodes went ERROR — `before_commit` hook failures |
| Sysbench error | FATAL: error 3100 "Error on observer while running replication hook 'before_commit'" |
| TPS during chaos | ~4.4 (44 transactions before failure) |
| Recovery | Automatic — coordinator restored cluster in ~2 minutes |
| GTIDs after recovery | MATCH (23d4ccb6-...:1-1136902) |
| Checksums after recovery | MATCH (all 4 tables identical across 3 pods) |
| Errant GTIDs | 0 |

**Note:** 30% packet loss caused all GR members to lose quorum and enter ERROR state with `before_commit` hook failures. This is more severe in multi-primary mode than single-primary because Paxos consensus requires majority acknowledgment from all writable nodes. The coordinator automatically recovered the cluster after chaos was removed.

### Experiment 8 — Combined Stress: Memory + CPU + Load (PASS)

**Chaos YAMLs applied simultaneously:**
- `combined-stress-memory.yaml` — 1200MB memory stress on one pod
- `combined-stress-cpu.yaml` — 90% CPU on all 3 pods

**Method:** Started 16-thread sysbench first (~1888 TPS baseline), then applied both stress experiments 15 seconds later while writes were in-flight.

**Load:** sysbench `oltp_write_only`, 16 threads, 120s

| Check | Result |
|---|---|
| OOMKill | No — cluster survived (no pod killed) |
| TPS during stress | 674 avg (dropped from 1888 to ~32 then recovered to ~735) |
| TPS reduction | ~64% from baseline |
| Total transactions | 80,984 in 120s |
| Errors | 0 |
| GR status | All 3 nodes ONLINE as PRIMARY throughout |
| GTIDs | MATCH (23d4ccb6-...:1-1217968) |
| Checksums | MATCH (all 4 tables identical across 3 pods) |
| Errant GTIDs | 0 |

**Timeline:**
| Time | Event |
|---|---|
| T+0s | Sysbench started — 16 threads, ~1888 TPS |
| T+15s | Memory + CPU stress applied |
| T+20s | TPS dropped to ~32 (initial stress impact) |
| T+30s | TPS recovered to ~215 |
| T+60s | TPS stabilized at ~673-899 |
| T+120s | Test completed, 0 errors |

### Experiment 9 — Full Cluster Kill (PASS)

**Method:** `kubectl delete pod --force --grace-period=0` on all 3 pods simultaneously

| Check | Result |
|---|---|
| Action | Force-deleted all 3 MySQL pods simultaneously |
| Cluster status | Critical for ~2 minutes, then Ready |
| Recovery time | ~2 minutes |
| GR status | All 3 nodes ONLINE as PRIMARY |
| GTIDs | MATCH (23d4ccb6-...:1-1218094) |
| Checksums | MATCH (all 4 tables identical across 3 pods) |
| Errant GTIDs | 0 |

---

## Experiments Pending (awaiting coordinator image update)

| # | Experiment | Description |
|---|---|---|
| 10 | OOMKill Natural (128 threads + JOINs) | Exhaust memory naturally with heavy queries |
| 11 | Scheduled Pod Kill (every 30s, 3 min) | Repeated pod kills under sustained load |
| 12 | Degraded Failover (IO Latency + Pod Kill) | IO latency then kill a pod while degraded |

---

## Key Observations

### Multi-Primary Mode Behavior

1. **No Failover Required:** In multi-primary mode, all nodes are primaries. When a node is killed, the other two continue serving writes. No failover election needed.

2. **Automatic Recovery:** Killed/failed pods restart and rejoin the group automatically via the coordinator.

3. **Zero Data Loss:** All 9 completed tests showed complete data consistency across all 3 nodes.

4. **GTID Synchronization:** All pods show identical GTIDs after recovery in every experiment.

5. **Network Partition — More Severe:** All nodes become ERROR in multi-primary mode (loss of Paxos quorum). Requires coordinator intervention to recover.

6. **Packet Loss — GR Hook Failures:** 30% packet loss triggers `before_commit` hook errors (error 3100), causing all writes to fail until quorum is restored.

7. **Combined Stress — Resilient:** Cluster survived memory + CPU stress under 16-thread write load without OOMKill.

### Performance Impact

| Experiment | TPS Before | TPS During | Impact |
|---|---|---|---|
| Pod Kill | ~1125 | ~1000 | ~11% drop (transient) |
| OOMKill | ~1500 | ~700 | ~53% drop (during memory pressure) |
| Network Partition | ~1490 | ~370 | ~75% drop (complete isolation) |
| CPU Stress | ~1400 | ~450 | ~68% drop (during stress) |
| IO Latency (100ms) | ~1400 | 3.63 | ~99.7% drop |
| Network Latency (1s) | ~1400 | 0.73 | ~99.9% drop |
| Packet Loss (30%) | ~1400 | ~4.4 | ~99.7% drop + ERROR state |
| Combined Stress | ~1888 | ~674 | ~64% drop |
| Full Cluster Kill | N/A | N/A | Cluster down ~2 min |

---

## Comparison: Multi-Primary vs Single-Primary

| Aspect | Multi-Primary | Single-Primary |
|---|---|---|
| Failover | Not needed (all primaries) | Election required (~2-3s) |
| Write availability | All nodes can write | Only primary can write |
| Pod Kill recovery | ~30s (rejoin only) | ~30s (election + rejoin) |
| Network partition | All nodes ERROR (no quorum) | Primary election happens |
| Packet loss 30% | All ERROR + before_commit failures | Failover triggered |
| IO Latency TPS | 3.63 | 2-3.5 |
| Network Latency TPS | 0.73 | 1.2-1.4 |
| Combined stress | Survived (674 TPS) | OOMKill triggered |

---

## Verdict

**9/9 completed experiments PASSED** with zero data loss, zero errant GTIDs, and full data consistency across all nodes.

The Multi-Primary mode shows resilience to pod kills, OOMKill, CPU stress, IO/network latency, packet loss, combined stress, and full cluster kill. The cluster recovers automatically via coordinator intervention in all scenarios.

**Remaining:** Experiments 10-12 pending coordinator image update.
