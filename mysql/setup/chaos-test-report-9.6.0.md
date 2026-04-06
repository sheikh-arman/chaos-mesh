# KubeDB MySQL Chaos Engineering — Test Report (MySQL 9.6.0)

**Date:** 2026-04-06
**Cluster:** KubeDB MySQL 9.6.0 — 3-node Group Replication (Single-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Coordinator Image:** `skaliarman/mysql-coordinator:15`
**Load Generator:** sysbench `oltp_write_only`, 8 threads, 4 tables x 50k rows

---

## Cluster Under Test

| Component | Details |
|---|---|
| MySQL Version | 9.6.0 |
| Topology | Group Replication — Single-Primary |
| Replicas | 3 nodes (1 primary + 2 secondaries) |
| Storage | 2Gi PVC per node (Durable) |
| Memory Limit | 1536Mi per pod |
| CPU Request | 500m per pod |
| Managed By | KubeDB Operator |
| Coordinator | `skaliarman/mysql-coordinator:15` (with data safety fixes) |

### Pod Layout (Before Tests)

```
Pod                   Role       Status
mysql-ha-cluster-0    PRIMARY    ONLINE
mysql-ha-cluster-1    SECONDARY  ONLINE
mysql-ha-cluster-2    SECONDARY  ONLINE
```

---

## Experiments Summary

| # | Experiment | Chaos Type | Duration | Failover | Data Loss | Checksum Match | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | Pod Kill Primary | PodChaos | Instant | ~30s | Zero (tracking table) | **MISMATCH on pod-0** | **INVESTIGATE** |
| 2 | OOMKill Primary | StressChaos (Memory) | 30s | ~3s | Zero | Match | PASS |
| 3 | Network Partition | NetworkChaos | 2 min | Yes (~60s) | Zero | N/A | PASS |
| 4 | IO Latency | IOChaos | 60s | No | Zero | N/A | PASS |
| 5 | Network Latency (1s) | NetworkChaos | 60s | No | Zero | N/A | PASS |
| 6 | CPU Stress | StressChaos | 60s | No | Zero | N/A | PASS |
| 7 | Packet Loss (30%) | NetworkChaos | 2 min | No | Zero | N/A | PASS |

---

## Detailed Experiment Results

---

### Experiment 1 — Pod Kill Primary (Force Delete)

**Chaos Type:** `kubectl delete pod --force --grace-period=0`
**Target:** Primary pod (mysql-ha-cluster-0)
**Shutdown Type:** Ungraceful (SIGKILL — `--force --grace-period=0`)
**Load:** sysbench `oltp_write_only`, 8 threads, running during kill

#### Timeline

| Time (UTC) | Event |
|---|---|
| 07:48:13 | Sysbench started — ~1800 TPS baseline |
| 07:48:28 | Primary (pod-0) force-killed |
| 07:48:28 | Sysbench: `FATAL: Lost connection to MySQL server` |
| 07:48:58 | Pod-2 elected new PRIMARY, pod-0 rejoined as SECONDARY |
| 07:48:58 | All 3 members ONLINE, cluster Ready |

#### TPS Impact

| Phase | TPS | Errors |
|---|---|---|
| Before kill | ~1800 | 0 |
| During failover | **0** | FATAL (Lost connection) |
| After recovery | N/A (sysbench exited) | — |

#### Data Integrity After Recovery

| Check | Result |
|---|---|
| Tracking table (testdb.important_data) | All rows present (no loss) |
| Row counts (sbtest1, 3 nodes) | All 50,000 rows |
| GTID positions | Identical across all 3 nodes |
| **CHECKSUM sbtest1** | **MISMATCH: pod-0 = `2480293525`, pod-1/pod-2 = `312898322`** |
| CHECKSUM sbtest2 | Match: `1109412795` (all 3) |
| SUM(k) sbtest1 | **MISMATCH: pod-0 = `1248468735`, pod-1/pod-2 = `1248495257`** |

#### Key Finding: Checksum Mismatch After Force Kill

**This is a significant finding.** After force-killing the primary during active write workload:

- **GTIDs are identical** across all 3 nodes
- **Row counts are identical** (50,000 rows)
- **Actual data values differ** — `SUM(k)` on pod-0 is `26,522` less than on pod-1/pod-2

**Root cause analysis:** When pod-0 was force-killed (`SIGKILL`), some transactions were in-flight:
1. The transactions had been **certified by GR consensus** (GTIDs assigned and replicated)
2. The transactions were **applied on secondaries** (pod-1, pod-2)
3. But on pod-0, the **InnoDB apply was interrupted** by SIGKILL
4. On restart, InnoDB crash recovery **rolled back** the uncommitted portions
5. Result: pod-0 has the same GTIDs but different data values for some rows

**Impact:** This is a **data inconsistency** between nodes. The data on pod-1/pod-2 (which applied the transactions fully) is the correct data. Pod-0 has stale values for some rows.

**Severity:** Medium — the inconsistency exists but does not cause functional issues because:
- Pod-0 is a SECONDARY (reads are served from primary or through GR)
- The GTID positions match, so GR considers the nodes in sync
- Over time, new writes to the affected rows will overwrite the stale values

**Note:** This issue was **not observed in MySQL 8.0.36** testing with the same experiment. It may be specific to MySQL 9.6.0's handling of in-flight transactions during SIGKILL.

#### Verdict

- **Failover time:** ~30 seconds
- **Tracking table data loss:** Zero
- **Checksum consistency:** **FAILED on pod-0 sbtest1**
- **Result:** **INVESTIGATE** — data inconsistency detected after force-kill under load

---

### Experiment 2 — OOMKill Primary (Memory Stress)

**Chaos Type:** StressChaos (Memory)
**Target:** Primary pod (mysql-ha-cluster-2)
**Stressor:** 1600MB memory allocation (limit: 1536Mi)
**Duration:** 30s

#### Timeline

| Time (UTC) | Event |
|---|---|
| 07:51:06 | Memory chaos applied on primary (pod-2) |
| ~07:51:07 | **OOMKilled** — pod-2 container killed (Exit Code 137) |
| ~07:51:10 | Pod-1 elected new PRIMARY |
| ~07:51:40 | Pod-2 restarted, rejoined as SECONDARY |
| ~07:51:46 | All 3 members ONLINE, cluster Ready |

#### OOMKill Confirmation

```
Last State:   Terminated
  Reason:     OOMKilled
  Exit Code:  137
```

#### Data Integrity

| Check | Result |
|---|---|
| Tracking table rows | 11 (all present) |
| GTID positions | Identical (within 2 transactions — settling) |

#### Verdict

- **Failover time:** ~3 seconds
- **Full recovery:** ~40 seconds
- **Data loss:** Zero
- **Result:** PASS

---

### Experiment 3 — Network Partition (Split-Brain Prevention)

**File:** `1-single-experiments/network-partition-primary.yaml`
**Chaos Type:** NetworkChaos (`partition`)
**Target:** Primary (pod-1) isolated from secondaries
**Direction:** Bidirectional
**Duration:** 2 minutes

#### Timeline

| Time (UTC) | Event |
|---|---|
| 07:58:57 | Partition applied — primary (pod-1) isolated |
| ~07:59:30 | Pod-1 expelled from group (lost quorum) |
| ~07:59:30 | Pod-2 elected new PRIMARY by surviving majority |
| ~08:00:57 | Partition healed (2m duration) |
| ~08:01:30 | Pod-1 MySQL restarted by coordinator |
| ~08:03:30 | Pod-1 rejoined as SECONDARY |
| ~08:05:00 | All 3 members ONLINE, cluster Ready |

#### Split-Brain Prevention

| Side | Status | Writes |
|---|---|---|
| Isolated primary (pod-1) | Expelled from group | **BLOCKED** (no quorum) |
| Majority (pod-0 + pod-2) | New PRIMARY elected | **ACCEPTED** |

#### Data Integrity

| Check | Result |
|---|---|
| Tracking table rows | 12 (all present) |
| Coordinator warnings | 0 extra GTID warnings |

#### Key Finding

Pod-1 was expelled from the group during the partition. The coordinator on pod-1 restarted MySQL and successfully rejoined the cluster after the partition healed. No extra transaction warnings were triggered in this run.

#### Verdict

- **Split-brain:** PREVENTED — isolated node lost quorum, writes blocked
- **Failover time:** ~30 seconds
- **Recovery time:** ~6 minutes (partition duration + rejoin)
- **Data loss:** Zero
- **Result:** PASS

---

### Experiment 4 — IO Latency (Slow Disk)

**File:** `1-single-experiments/io-latency-primary.yaml`
**Chaos Type:** IOChaos (`latency`)
**Target:** Primary pod's `/var/lib/mysql`
**Delay:** 100ms per IO operation
**Duration:** 60s (with load)

#### TPS Impact

| Phase | TPS | 95th Percentile Latency | Errors |
|---|---|---|---|
| During IO chaos | 0.5-8.0 | 2,449-20,503 ms | 0 |
| Average | **1.97** | **17,125 ms** | **0** |

#### Cluster Behavior

| Metric | Value |
|---|---|
| Failover triggered | **No** |
| Cluster status | Ready throughout |
| GR members | All 3 remained ONLINE |

#### Data Integrity

| Check | Result |
|---|---|
| Tracking table rows | 13 (all present) |

#### Verdict

- **TPS reduction:** ~99.9% (1800 → 2)
- **Failover:** None (IO issues don't trigger GR failover)
- **Data loss:** Zero
- **Result:** PASS

---

### Experiment 5 — Network Latency (Replication Lag)

**File:** `1-single-experiments/network-latency-primary-to-replicas.yaml`
**Chaos Type:** NetworkChaos (`delay`)
**Target:** Primary to replicas traffic
**Delay:** 1s latency + 50ms jitter
**Direction:** Bidirectional
**Duration:** 60s

#### TPS Impact

| Phase | TPS | 95th Percentile Latency | Errors |
|---|---|---|---|
| During chaos | 0.3-3.3 | 6,026-11,116 ms | 0 |
| Average | **1.35** | **10,159 ms** | **0** |

#### Why TPS Crashed to ~1

Group Replication uses **Paxos-based consensus** — every write must be acknowledged by a majority before commit. With 1s one-way latency:
- Round-trip time = 2-4 seconds per consensus round
- Maximum TPS ~ 1 transaction per 2-4 seconds

#### Cluster Behavior

| Metric | Value |
|---|---|
| Failover triggered | **No** |
| Cluster status | Ready throughout |
| GR members | All 3 remained ONLINE |

#### Data Integrity

| Check | Result |
|---|---|
| Tracking table rows | 14 (all present) |

#### Verdict

- **TPS reduction:** ~99.9% (1800 → 1.35)
- **Failover:** None (latency ≠ disconnection)
- **Data loss:** Zero
- **Result:** PASS

---

### Experiment 6 — CPU Stress (Resource Saturation)

**File:** `1-single-experiments/stress-cpu-primary.yaml`
**Chaos Type:** StressChaos (`cpu`)
**Target:** Primary pod
**Stressor:** 2 workers, 98% CPU load
**Duration:** 60s

#### TPS Impact

| Phase | TPS | 95th Percentile Latency | Errors |
|---|---|---|---|
| During stress (early) | 1567-1596 | 8.28-8.43 ms | 0 |
| During stress (late) | 979-1383 | 12.52-24.38 ms | 0 |
| Average | **1320** | **11.65 ms** | **0** |

#### Cluster Behavior

| Metric | Value |
|---|---|
| Failover triggered | **No** |
| Cluster status | Ready throughout |
| GR members | All 3 remained ONLINE |

#### Data Integrity

| Check | Result |
|---|---|
| Tracking table rows | 15 (all present) |

#### Verdict

- **TPS reduction:** ~27% (1800 → 1320) — mildest of all chaos types
- **Failover:** None
- **Data loss:** Zero
- **Result:** PASS

---

### Experiment 7 — Packet Loss (30% All Nodes)

**File:** `1-single-experiments/packet-loss.yaml`
**Chaos Type:** NetworkChaos (`loss`)
**Target:** All MySQL pods
**Loss:** 30% packet loss, 25% correlation
**Duration:** 2 minutes

#### TPS Impact

| Phase | TPS | 95th Percentile Latency | Errors |
|---|---|---|---|
| During chaos (early) | 0-3.6 | 4,055-22,035 ms | 0 |
| During chaos (sustained) | 0-8.0 | 2,320-14,827 ms | 0 |
| Average | **2.47** | **11,733 ms** | **0** |

#### Cluster Behavior

| Metric | Value |
|---|---|
| Failover triggered | **No** |
| Cluster status | Ready |
| GR members | All 3 remained ONLINE |
| Write stall | TPS hit 0 for ~10s stretches |

#### Data Integrity

| Check | Result |
|---|---|
| Tracking table rows | 16 (all present) |

#### Verdict

- **TPS reduction:** ~99.9% (1800 → 2.47)
- **Failover:** None (GR tolerated 30% packet loss without expelling members)
- **Data loss:** Zero
- **Result:** PASS

---

## Issues Found

### Issue 1 (CRITICAL): Checksum Mismatch After Force Kill Under Load

**Experiment:** 1 (Pod Kill Primary)
**Severity:** Critical — silent data inconsistency

After force-killing the primary during active sysbench load:
- GTIDs identical across all 3 nodes
- Row counts identical (50,000)
- **SUM(k) differs:** pod-0 = `1248468735` vs pod-1/pod-2 = `1248495257`
- **CHECKSUM TABLE differs:** pod-0 = `2480293525` vs pod-1/pod-2 = `312898322`

**Root cause:** SIGKILL during active writes causes InnoDB crash recovery to roll back in-flight transactions on the killed node, but secondaries have already applied them. GTID records show the transaction as "executed" on all nodes, but the actual data state differs.

**Note:** This was NOT observed in MySQL 8.0.36 with the same test. May be specific to MySQL 9.6.0's crash recovery behavior.

**Recommendation:** Investigate whether this is a MySQL 9.6.0 regression or a timing issue. Consider using graceful pod deletion (without `--force --grace-period=0`) in production.

### Issue 2 (INFO): Transient Extra-GTID Warning During Network Partition Recovery

**Experiment:** 3 (observed in earlier run with same setup)
**Severity:** Low — cosmetic

During GR role transition after partition heals, `findPrimaryPod()` can briefly return the wrong pod as primary. The coordinator logs "extra GTIDs" warning that resolves on the next loop (10s). No clone triggered, no data impact.

---

## Comparison: MySQL 8.0.36 vs 9.6.0

| Metric | MySQL 8.0.36 | MySQL 9.6.0 |
|---|---|---|
| Pod Kill Failover | ~3s | ~30s |
| OOMKill Failover | ~2s | ~3s |
| Network Partition Recovery | ~90s | ~6 min |
| IO Latency TPS (100ms delay) | 3-362 TPS | 0.5-8 TPS |
| Network Latency TPS (1s delay) | ~1 TPS | ~1.35 TPS |
| CPU Stress TPS | ~530 TPS | ~1320 TPS |
| Packet Loss (30%) Failover | Yes (~30s) | No (cluster survived) |
| Checksum After Force Kill | **Match** | **MISMATCH (pod-0)** |
| Coordinator Crash (Fatalln) | Present | Fixed |
| Clone Approval Required | No (auto-clone) | Yes (`/scripts/approve-clone`) |

### Notable Differences

1. **Pod Kill Failover is slower on 9.6.0** (~30s vs ~3s) — may be due to different GR timeout defaults
2. **IO Latency more severe on 9.6.0** — TPS dropped to ~2 vs ~77-362 on 8.0.36
3. **CPU Stress less impactful on 9.6.0** — ~1320 TPS vs ~530 TPS (9.6.0 handles CPU pressure better)
4. **Packet Loss 30% survived on 9.6.0** without failover — 8.0.36 had a failover
5. **Checksum mismatch on 9.6.0 after force kill** — not seen on 8.0.36 (potential regression)

---

## Final Data State

| Check | Result |
|---|---|
| Tracking table rows | 16/16 (all experiments tracked) |
| GTID positions | Identical across all 3 nodes |
| CHECKSUM sbtest1 | **pod-0 differs from pod-1/pod-2** (from Experiment 1) |
| CHECKSUM sbtest2 | Match across all nodes |
| Cluster status | Ready |

---

## Summary

| Category | Count |
|---|---|
| Experiments run | 7 |
| Data loss (tracking table) | 0 |
| Checksum mismatches | 1 (Experiment 1 — force kill under load) |
| Failovers triggered | 3 (Exp 1, 2, 3) |
| Total sysbench errors | 0 (all FATAL errors were connection losses during failover, not data errors) |

**Key takeaway:** All 7 experiments preserved tracking table data with zero loss. However, Experiment 1 revealed a **checksum inconsistency** on the force-killed node after rejoin — GTIDs match but actual column values differ. This appears to be specific to MySQL 9.6.0 and warrants further investigation.
