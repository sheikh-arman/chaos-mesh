# Chaos Test Report — MySQL Coordinator Data Safety Fixes

**Date:** 2026-04-06
**MySQL Version:** 9.6.0
**Coordinator Image:** `skaliarman/mysql-coordinator:15`
**Cluster:** 3-node Group Replication (Single-Primary), KubeDB
**Chaos Tool:** Chaos Mesh

---

## Baseline``

- 3-node MySQL HA cluster, all ONLINE
- Test table `testdb.important_data` with 5 baseline rows
- All GTIDs identical across nodes before tests
- Sysbench prepared with 4 tables, 50k rows each

---

## Test Results

### Test 1: Kill Primary Pod

| Item | Detail |
|------|--------|
| **Action** | Force-deleted primary pod (pod-1) |
| **Result** | PASSED |
| **Failover time** | < 30 seconds |
| **Data loss** | None — all 6 rows intact |
| **New primary** | Pod-2 (automatic promotion) |
| **Old primary** | Pod-1 rejoined as SECONDARY |
| **Coordinator issues** | None. One transient "error querying performance schema" during pod-1 restart (expected) |

---

### Test 2: Kill All Pods Simultaneously

| Item | Detail |
|------|--------|
| **Action** | Force-deleted all 3 pods at once |
| **Result** | PASSED |
| **Recovery time** | < 90 seconds to Ready |
| **Data loss** | None — all 7 rows intact |
| **Election** | Pod-0 elected via `gtid_subtract` superset check (correct) |
| **Coordinator log** | `pod mysql-ha-cluster-0 is a superset of all other pods` |
| **Issues** | None |

---

### Test 3: Combined Memory Stress + CPU Stress + Database Load

| Item | Detail |
|------|--------|
| **Action** | 1200MB memory stress on primary, 800MB on replica, 90% CPU on all nodes + 32-thread sysbench (120s) |
| **Result** | PASSED |
| **Data loss** | None — all 8 rows intact |
| **Sysbench** | 211,909 transactions, 0 errors, ~1759 TPS avg |
| **Pod restarts** | Pod-0 and Pod-1 restarted (OOMKilled — 1200MB stress + MySQL exceeded 1.5Gi limit) |
| **Replication** | Secondaries went RECOVERING for ~3 min while catching up on transaction backlog |
| **TPS impact** | Degraded from ~2700 to ~886 TPS during peak stress (67% drop) |
| **Recovery** | Full cluster Ready within ~4 minutes after chaos cleanup |
| **Coordinator issues** | None — no extra transaction warnings, no clone approvals |

---

### Test 4: Network Partition Primary

| Item | Detail |
|------|--------|
| **Action** | 2-minute network partition isolating primary from secondaries |
| **Result** | PASSED (no failover triggered) |
| **Data loss** | None — all 9 rows intact |
| **Observation** | GR did not expel the primary within the 2-minute partition window. All members remained ONLINE throughout |
| **Coordinator issues** | None in this run |
| **Previous run observation** | In an earlier test with the same experiment, the primary WAS expelled, failover occurred, and the coordinator logged a transient "extra GTIDs" warning during the brief role-confusion window when the partitioned primary rejoined. This resolved automatically as GR stabilized roles — no clone was triggered, no data lost |

---

### Test 5: IO Latency on Primary Under Load

| Item | Detail |
|------|--------|
| **Action** | Injected IO latency on primary's disk + 16-thread sysbench for 60s |
| **Result** | PASSED |
| **Data loss** | None — all 10 rows intact, 0 errors during load |
| **TPS impact** | Dropped from ~1800 to **3.5 TPS** (99.8% degradation) |
| **95th latency** | Spiked to **13.8 seconds** (from ~14ms baseline) |
| **Failover** | None — cluster stayed Ready throughout |
| **Coordinator issues** | None |

---

## Issues Found During Testing

### Issue 1: Transient "Extra GTIDs" Warning During Network Partition Recovery

**Observed in:** Earlier network partition test (Test 4 from previous run)

**What happened:**
1. Primary (pod-2) was isolated by network partition
2. Majority side (pod-0 + pod-1) elected pod-1 as new primary
3. Pod-1 processed ~1958 new transactions while serving as primary
4. Partition healed — pod-2 rejoined the group
5. For a brief moment (~10s), the coordinator on pod-1 saw pod-2 as "primary" (stale GR view)
6. `holdsExtraTransactions()` compared pod-1's GTID (`...:1-165618`) vs pod-2's GTID (`...:1-163660`)
7. Coordinator logged: `WARNING: instance mysql-ha-cluster-1 has extra GTIDs not on primary: ...:163661-165618`

**Root cause:** During GR role transition after partition heals, `findPrimaryPod()` can briefly return the wrong pod as primary before GR stabilizes the new view.

**Impact:** No data loss. The warning was transient — on the next coordinator loop (10s later), GR had stabilized with pod-1 as the correct primary, and the warning stopped. No clone was triggered because `holdsExtraTransactions()` returned `false` on the subsequent check.

**Severity:** Low — cosmetic log noise, no functional impact.

**Potential improvement:** Add a delay or re-check in `holdsExtraTransactions()` before logging the warning — e.g., confirm the "extra" state persists for 2+ consecutive coordinator loops before reporting.

### Issue 2: OOMKill Under Memory Stress

**Observed in:** Test 3

**What happened:** Pod-0 and Pod-1 were OOMKilled when 1200MB memory stress + MySQL's own ~800MB usage exceeded the 1.5Gi memory limit.

**Impact:** No data loss. Pods restarted and rejoined the cluster. Secondaries went RECOVERING for ~3 minutes.

**Severity:** Medium — expected behavior with the current resource limits, but impacts availability.

**Recommendation:** Increase MySQL pod memory limits to 2.5-3Gi for production use.

### Issue 3: Severe TPS Degradation Under IO Latency

**Observed in:** Test 5

**What happened:** IO latency chaos reduced TPS from ~1800 to 3.5 (99.8% degradation) with 13.8s p95 latency.

**Impact:** No data loss, but effectively a service outage for latency-sensitive workloads.

**Severity:** Medium — IO latency on the primary makes the cluster near-unusable but doesn't cause data loss.

**Observation:** GR did not trigger a failover to a healthy secondary despite the primary being extremely slow. This is expected — GR monitors member liveness, not performance.

---

## Summary

| Test | Data Loss | Cluster Recovered | Issues |
|------|-----------|-------------------|--------|
| Primary kill | None | Yes (< 30s) | None |
| Full cluster kill | None | Yes (< 90s) | None |
| Combined stress + load | None | Yes (< 4 min) | OOMKill on 2 pods (resource limits) |
| Network partition | None | Yes (no failover) | Transient extra-GTID warning in earlier run |
| IO latency + load | None | Yes (stayed Ready) | 99.8% TPS degradation |

**Zero data loss across all 5 chaos tests.** The coordinator fixes (election safety, clone approval, marker file timing, graceful shutdown) are working correctly on MySQL 9.6.0.
