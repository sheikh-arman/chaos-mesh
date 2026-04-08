# KubeDB MySQL Chaos Engineering — Test Report (MySQL 8.4.8)

**Date:** 2026-04-07
**Cluster:** KubeDB MySQL 8.4.8 — 3-node Group Replication (Single-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench, 4 tables x 50k rows

---

## Experiments Summary

| # | Experiment | Failover | Data Loss | GTIDs | Checksums | Verdict |
|---|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | MATCH | MATCH | PASS |
| 2 | OOMKill Primary (stress) | No (survived) | Zero | MATCH | MATCH | PASS |
| 3 | Network Partition | Yes | Zero | MATCH | MATCH | PASS |
| 4 | IO Latency (100ms) | No | Zero | MATCH | MATCH | PASS |
| 5 | Network Latency (1s) | No | Zero | MATCH | MATCH | PASS |
| 6 | CPU Stress (98%) | No | Zero | MATCH | MATCH | PASS |
| 7 | Packet Loss (30%) | Yes | Zero | MATCH | MATCH | PASS |
| 8 | Combined Stress (mem+cpu+load) | Yes (OOMKill) | Zero | MATCH (after settling) | MATCH (after settling) | PASS |
| 9 | Full Cluster Kill | Yes | Zero | MATCH (after settling) | MATCH (after settling) | PASS |
| 10 | OOMKill Natural Load (128 threads) | No (survived) | Zero | MATCH | MATCH | PASS |
| 11 | Scheduled Replica Kill (every 30s) | Multiple | Zero | MATCH | MATCH | PASS |
| 12 | Degraded Failover (IO + Kill) | Yes | Zero | MATCH | MATCH | PASS |

---

## Detailed Results

### Exp 1: Pod Kill Primary
- **Action:** Force-deleted primary pod (pod-0)
- **Failover:** Pod-2 elected as new PRIMARY
- **Tracking rows:** 6/6 preserved
- **Split-brain:** None
- **Extra GTID warnings:** 0

### Exp 2: OOMKill Primary (Memory Stress)
- **Action:** Applied 1600MB memory stress on primary
- **Result:** Primary survived — stress did not trigger OOMKill on 8.4.8
- **Tracking rows:** 7/7 preserved

### Exp 3: Network Partition
- **Action:** Isolated primary from replicas for 2 minutes
- **Failover:** Pod-1 elected as new PRIMARY
- **Cluster status:** Critical at check time (pod-2 still recovering)
- **Tracking rows:** 8/8 preserved
- **Note:** Cluster recovered to Ready after settling

### Exp 4: IO Latency (100ms)
- **Action:** IO latency on primary + 8-thread write load
- **TPS:** 3.55 avg (99.8% reduction)
- **95th latency:** 3,640ms
- **Errors:** 0
- **Tracking rows:** 9/9 preserved

### Exp 5: Network Latency (1s)
- **Action:** 1s latency between primary and replicas + 8-thread write load
- **TPS:** 1.22 avg (99.9% reduction)
- **95th latency:** 8,956ms
- **Errors:** 0
- **Tracking rows:** 10/10 preserved

### Exp 6: CPU Stress (98%)
- **Action:** 98% CPU stress on primary + 8-thread write load
- **Tracking rows:** 11/11 preserved
- **No failover**

### Exp 7: Packet Loss (30%)
- **Action:** 30% packet loss on all nodes + 8-thread write load for 2 min
- **Failover:** Yes — primary changed from pod-1 to pod-2
- **Tracking rows:** 12/12 preserved

### Exp 8: Combined Stress (Memory + CPU + Load)
- **Action:** 1200MB memory stress on primary, 800MB on replica, 90% CPU on all + 16-thread write load
- **Result:** Pods OOMKilled, cluster went NotReady during recovery
- **At check time:** GTIDs MISMATCH, checksums MISMATCH (replication lag)
- **After settling (3 min):** GTIDs MATCH, all checksums MATCH
- **Tracking rows:** 12/12 preserved (no new row — insert happened before chaos took effect)

### Exp 9: Full Cluster Kill
- **Action:** Force-deleted all 3 pods simultaneously
- **At check time:** NotReady, GTIDs/checksums MISMATCH (still recovering)
- **After settling:** GTIDs MATCH, all checksums MATCH, cluster Ready
- **Election:** Pod-2 elected as PRIMARY
- **Tracking rows:** 12/12 preserved

### Exp 10: OOMKill via Natural Load (128 threads + JOINs)
- **Action:** 128-thread sysbench + large JOIN queries to exhaust memory naturally
- **Result:** Primary survived — 8.4.8 did not OOMKill under this load
- **Tracking rows:** 13/13 preserved

### Exp 11: Scheduled Replica Kill (every 30s)
- **Action:** Kill random standby pod every 30s for 3 minutes
- **Multiple failovers:** Replicas killed and recovered repeatedly
- **Tracking rows:** 14/14 preserved

### Exp 12: Degraded Failover Workflow (IO Latency + Pod Kill)
- **Action:** IO latency on primary + pod kill workflow
- **Failover:** Pod-1 elected as new PRIMARY
- **Tracking rows:** 15/15 preserved

---

## Issues Found

### Issue 1: Transient Checksum/GTID Mismatch During Recovery (Exp 8, 9)

**Severity:** Low (cosmetic)

During combined stress (Exp 8) and full cluster kill (Exp 9), the verification check ran while the cluster was still recovering (NotReady state). GTIDs and checksums showed MISMATCH at that point. After waiting 3 minutes for replication to settle, all GTIDs matched and all checksums matched.

**Root cause:** Replication applier threads need time to catch up after heavy write load + node restarts. The check ran too early.

**Impact:** None — data was consistent after recovery completed.

### Issue 2: OOMKill Did Not Trigger on 8.4.8 (Exp 2, 10)

**Severity:** Info

Neither the StressChaos memory stressor (1600MB) nor the natural load (128 threads + large JOINs) triggered OOMKill on MySQL 8.4.8. The same tests successfully OOMKilled MySQL 9.6.0.

**Possible reason:** MySQL 8.4.8 may handle memory allocation differently (more conservative buffer management), or the 1536Mi limit provides more headroom on this version.

---

## Summary

| Metric | Value |
|---|---|
| Experiments run | 12 |
| Data loss | **Zero** across all experiments |
| Tracking rows preserved | 15/15 (all) |
| Checksum mismatches (after settling) | **Zero** |
| GTID mismatches (after settling) | **Zero** |
| Split-brain incidents | **Zero** |
| Extra GTID warnings | **Zero** |
| Failovers triggered | 6 (Exp 1, 3, 7, 8, 9, 12) |
| Cluster auto-recovered | All experiments |

**Verdict: All 12 experiments PASSED on MySQL 8.4.8. Zero data loss, zero split-brain, zero errant GTIDs.**
