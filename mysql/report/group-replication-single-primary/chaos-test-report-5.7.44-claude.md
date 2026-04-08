# KubeDB MySQL Chaos Engineering — Test Report (MySQL 5.7.44)

**Date:** 2026-04-07
**Cluster:** KubeDB MySQL 5.7.44 — 3-node Group Replication (Single-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench, 4 tables x 50k rows

---

## Cluster Under Test

| Component | Details |
|---|---|
| MySQL Version | 5.7.44 |
| Topology | Group Replication — Single-Primary |
| Replicas | 3 nodes (1 primary + 2 secondaries) |
| Memory Limit | 1.5Gi (1536Mi) per pod |
| CPU Request | 500m per pod |

---

## Experiments Summary

| # | Experiment | Failover | Data Loss | GTIDs | Checksums | Errant GTIDs | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | MATCH | MATCH | 0 | PASS |
| 2 | OOMKill Natural (128 threads) | Yes | Zero | MISMATCH | MISMATCH | **1** | **FAIL** |
| 3 | Network Partition | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 4 | IO Latency | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 5 | Network Latency | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 6 | CPU Stress | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 7 | Packet Loss | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 8 | Combined Stress | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 9 | Full Cluster Kill | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 10 | OOMKill Natural (retry) | Yes (OOMKilled) | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 11 | Scheduled Kill | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |
| 12 | Degraded Failover | N/A | N/A | MISMATCH | MISMATCH | 1 | **BLOCKED** |

---

## Critical Finding: Persistent Errant GTID from Exp 2

### What happened

Experiment 2 (OOMKill via natural load — 128 threads + large JOINs) caused a **persistent errant GTID** on pod-2 that **never recovered** for the remainder of all 12 experiments.

### Timeline

1. **Exp 1 (Pod Kill):** PASSED — all clean
2. **Exp 2 (OOMKill Natural):** Pod-2 (primary) OOMKilled under 128-thread load
   - Pod-1 elected as new PRIMARY
   - Pod-2 restarted with **1 errant GTID** (local server_uuid)
   - Pod-2 could not rejoin the GR group
   - Cluster went **Critical** — only 2 nodes in group
3. **Exp 3-12:** All ran against a **degraded 2-node cluster** with pod-2 stuck outside the group
   - Checksums consistently showed pod-0/pod-1 matching, pod-2 different (stale data from before OOMKill)
   - Tracking rows stopped incrementing at 12 (inserts failed on some experiments)
   - Cluster alternated between Critical and NotReady

### Root Cause

On MySQL 5.7.44, the `super_read_only=ON` fix may not have been applied (different init script branch), or MySQL 5.7 handles the errant GTID differently than 8.0+. The errant GTID on pod-2 prevented it from rejoining GR, and the coordinator's clone approval mechanism blocked automatic resolution (by design — to prevent data loss).

### Impact

- **Tracking table data preserved:** 12 rows on pod-0/pod-1 (inserts after Exp 7 failed due to cluster instability)
- **No split-brain:** Coordinator correctly prevented pod-2 from bootstrapping a separate cluster
- **No silent data loss:** The errant GTID was detected and blocked
- **Availability degraded:** Cluster ran on 2 nodes for Exp 3-12

---

## Detailed Results

### Experiment 1 — Pod Kill Primary (PASS)

| Check | Result |
|---|---|
| Failover | Pod-2 elected PRIMARY |
| Tracking rows | 6/6 |
| GTIDs | MATCH |
| Checksums | All 4 MATCH |
| Errant GTIDs | 0 |

### Experiment 2 — OOMKill via Natural Load (FAIL)

**Method:** 128-thread sysbench + 20 large JOIN queries

| Check | Result |
|---|---|
| OOMKill | Triggered on primary |
| Failover | Pod-1 elected PRIMARY |
| Cluster | **Critical** — pod-2 stuck with errant GTID |
| GTIDs | **MISMATCH** |
| Checksums | **MISMATCH** (pod-2 has stale data) |
| Errant GTIDs | **1** (pod-2 local server_uuid) |

### Experiments 3-12 — All BLOCKED

All subsequent experiments ran against a degraded cluster (2 healthy nodes + 1 stuck node). Results are not representative of normal 3-node behavior.

---

## Performance Under Chaos (on degraded 2-node cluster)

| Experiment | TPS During Chaos |
|---|---|
| IO Latency (100ms) | 0.41 |
| Network Latency (1s) | 6.46 |
| CPU Stress (98%) | 1,371 |

---

## Comparison with Other Versions

| Issue | MySQL 5.7.44 | MySQL 8.0.36 | MySQL 8.4.8 | MySQL 9.6.0 |
|---|---|---|---|---|
| Errant GTID after OOMKill | **Persistent (stuck)** | Transient (resolved) | Transient (resolved) | Transient (resolved) |
| Cluster recovery after OOMKill | **Failed** (Critical) | Ready | Ready | Ready |
| Clone plugin available | Yes (8.0.17+) but 5.7 is below | Yes | Yes | Yes |
| `super_read_only` fix applied | May not be on 5.7 branch | Yes | Yes | Yes |

### Key Difference

MySQL 5.7 does **not support the CLONE plugin** (requires 8.0.17+). When a node has errant GTIDs on MySQL 8.0+, the coordinator can request a clone to resync. On MySQL 5.7, there is no clone mechanism — the only options are manual intervention or full PVC deletion.

---

## Summary

| Metric | Value |
|---|---|
| MySQL Version | 5.7.44 |
| Experiments run | 12 |
| Experiments PASSED | **1** (Exp 1) |
| Experiments FAILED | **1** (Exp 2 — persistent errant GTID) |
| Experiments BLOCKED | **10** (Exp 3-12 — ran on degraded cluster) |
| Data loss | Zero (data preserved but cluster degraded) |
| Split-brain | None |
| Persistent errant GTIDs | **1** (on pod-2, never resolved) |

**Verdict: MySQL 5.7.44 has a critical issue — OOMKill under heavy load creates a persistent errant GTID that prevents node rejoin. The cluster degrades to 2 nodes and cannot self-heal without manual intervention (PVC deletion or manual GTID injection). This issue does NOT exist on MySQL 8.0.36, 8.4.8, or 9.6.0.**

**Recommendation:** MySQL 5.7 is EOL (end of life). Upgrade to MySQL 8.0+ for proper clone-based recovery and errant GTID handling.
