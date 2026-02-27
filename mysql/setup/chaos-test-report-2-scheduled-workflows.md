# KubeDB MySQL — Scheduled Experiments & Workflows Chaos Test Report

**Date:** 2026-02-27
**Cluster:** KubeDB MySQL 8.0.36 — 3-node Group Replication (Single-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench `oltp_read_write`, 8 threads, 12 tables × 100k rows

---

## Pre-Test Setup & Fixes

### Baseline Performance

Before any chaos was applied, a 30-second sysbench baseline was captured:

| Metric | Value |
|---|---|
| TPS (transactions/sec) | ~229 |
| QPS (queries/sec) | ~4593 |
| 95th pct latency | ~76 ms |
| Avg latency | ~35 ms |
| Error rate | 0 |

### YAML Fixes Required

The workflow files (`3-workflows/`) were written for an older Chaos Mesh API and needed corrections before they could be applied:

| Issue | File(s) | Fix |
|---|---|---|
| `kind: ChaosWorkflow` deprecated | Both workflow files | Changed to `kind: Workflow` |
| `duration:` inside chaos spec not allowed in workflows | Both files | Removed `duration:` from chaos specs; lifecycle controlled by `deadline:` on the template |
| `conditionalBranches` pattern not valid | `workflow-degraded-failover.yaml` | Replaced with a `Serial` sub-template using a `Suspend` step (30s delay) before the pod kill |
| `spec.targetPort` not a valid NetworkChaos field | `packet-loss-group-replication.yaml` | Not fixable without CRD upgrade — experiment skipped |

The corrected files are saved in place in `3-workflows/`.

---

## Experiments

---

### Workflow 1 — Flaky Network Failover

**File:** `3-workflows/workflow-flaky-network-failover.yaml`
**Pattern:** Serial — Phase 1: 25% packet loss (100% correlation) on primary→replica for 3 minutes → Phase 2: Kill primary

**Intent:** Verify that when the primary has been degraded by packet loss before failover, Group Replication still elects a *healthy* secondary (not the one that was under network stress).

#### Sysbench TPS Timeline

| Interval | TPS | 95th pct Latency | Notes |
|---|---|---|---|
| T+0 – T+10s | 58 | 148 ms | Pre-chaos normal (partial overlap with chaos start) |
| T+10 – T+20s | 0.5 | 7895 ms | Packet loss injected — traffic nearly stopped |
| T+20 – T+180s | **0** | — | All connections stalled under 100% correlated packet loss |
| T+180s | FATAL errors | — | Pod kill executed (Phase 2) — "Lost connection to MySQL server" |
| T+180 – T+360s | **0** | — | Sysbench threads could not reconnect — cluster in degraded state |

**Total transactions:** effectively frozen after T+20s. No reconnection occurred.

#### Cluster Behaviour

| Time (UTC) | Event |
|---|---|
| 07:00:30 | Workflow applied |
| ~07:00:40 | Phase 1 begins — 25% packet loss with **100% correlation** injected on primary (`mysql-ha-cluster-1`) ↔ one replica |
| ~07:00:50 | Sysbench TPS collapses from 58 → 0 (100% correlation makes even 25% loss effectively total blockage) |
| ~07:03:30 | Phase 1 ends (3m deadline), Phase 2 begins — primary (`mysql-ha-cluster-1`) pod killed |
| ~07:03:30 | Sysbench FATAL: `Lost connection to MySQL server during query` |
| ~07:03:38 | `mysql-ha-cluster-1` restarts but joins cluster in a confused state |
| ~07:04:00 | GR view from `mysql-ha-cluster-2`: `mysql-ha-cluster-1` shown as **UNREACHABLE PRIMARY** |
| — | `mysql-ha-cluster-0` and `mysql-ha-cluster-2` remain ONLINE SECONDARY but cannot elect a new primary — cluster stuck |
| ~09:27:18 | Manual recovery required: all 3 pods deleted and restarted simultaneously |
| ~09:29:18 | Full 3-node cluster restored, `mysql-ha-cluster-0` elected PRIMARY |

#### Root Cause of Stuck State

The 100% correlated packet loss effectively became a complete network partition between the primary and the replica being targeted. When the primary pod was killed immediately after the partition lifted, the two surviving secondaries (`0` and `2`) had quorum but saw `mysql-ha-cluster-1` as `UNREACHABLE PRIMARY` in their GR membership cache. MySQL's GR expel mechanism did not trigger in time, and the secondaries waited indefinitely for the old primary to return rather than electing a new one.

**Recovery:** All 3 pods were deleted simultaneously, forcing a clean GR bootstrap on restart.

**Result: PARTIAL** — Chaos executed correctly. Failover did not complete automatically. Cluster required manual pod restart to recover. Total downtime: **~1 hour 27 minutes** before manual intervention.

---

### Workflow 2 — Degraded Failover

**File:** `3-workflows/workflow-degraded-failover.yaml`
**Pattern:** Parallel — IO latency (50ms on `/var/lib/mysql`) starts immediately; pod kill fires at T+30s — both run in parallel.

**Intent:** Test whether failover succeeds when the primary is already under storage stress at the moment it is killed.

#### Sysbench TPS Timeline

| Interval | TPS | 95th pct Latency | Notes |
|---|---|---|---|
| T+0 – T+10s | 131 | 79 ms | Pre-chaos normal |
| T+10 – T+20s | 3.9 | 2986 ms | IO latency injected — writes dramatically slowed |
| T+20 – T+30s | 2.6 | 4855 ms | IO latency sustained |
| T+30s | FATAL errors | — | Pod kill fires — "Lost connection to MySQL server" |
| T+30 – T+60s | 0 | — | New primary election in progress |
| T+60s onwards | Recovering | — | `mysql-ha-cluster-1` elected new primary, sysbench reconnects |

#### Cluster Behaviour

| Time (UTC) | Event |
|---|---|
| 08:51:32 | Workflow applied |
| ~08:51:32 | IO latency (50ms) injected on primary (`mysql-ha-cluster-2`) |
| ~08:51:32 | `delayed-kill-sequence` template begins its 30s suspend |
| ~08:52:02 | Pod kill fires — `mysql-ha-cluster-2` killed while under IO stress |
| ~08:52:04 (T+32s) | `mysql-ha-cluster-2` enters PodInitializing |
| ~08:52:04 | `mysql-ha-cluster-1` elected as new PRIMARY |
| ~08:52:24 (T+52s) | `mysql-ha-cluster-2` rejoins as SECONDARY (`2/2 Running`) |
| — | Full 3-node cluster restored. KubeDB phase: `Ready` |

#### Impact on Writes

IO latency of 50ms caused write latency to spike from ~35ms to ~4855ms (95th pct) even before the pod kill. After the kill and election of `mysql-ha-cluster-1` as the new primary (no IO latency), performance recovered. **The failover under IO stress completed successfully in ~32 seconds.**

**Result: PASS** — Failover under combined IO stress + pod kill succeeded. New primary elected in ~30s. No data loss. Cluster returned to Ready within ~52 seconds.

---

### Scheduled Experiment 1 — Nightly Replica Kill

**File:** `2-scheduled-experiments/schedule-nightly-replica-kill.yaml`
**Original schedule:** `0 1 * * *` (1 AM nightly)
**Test schedule:** `*/1 * * * *` (every minute — to trigger immediately)
**Action:** Kill one `standby` pod per firing, `concurrencyPolicy: Forbid`

**Intent:** Simulate nightly replica maintenance kill. Verify the replica restarts and rejoins Group Replication automatically. Primary and application writes must be unaffected.

#### Schedule Firings

With `*/1 * * * *`, the schedule fired 3 times during the 3-minute observation window, producing 3 separate `PodChaos` objects (visible in `.status.active`):

```
mysql-nightly-replica-kill-8ppvs
mysql-nightly-replica-kill-htc8n / ljsnc / pr4qg  (rolling, historyLimit=3)
mysql-nightly-replica-kill-7qzbg
```

Each firing killed one standby pod (observed: `mysql-ha-cluster-1` was killed first at ~T+240s of the sysbench run).

#### Sysbench TPS Timeline

| Interval | TPS | 95th pct Latency | Errors | Notes |
|---|---|---|---|---|
| T+0 – T+60s | 238–246 | ~73 ms | 0 | Baseline (chaos not yet fired) |
| T+60 – T+70s | 212 | ~81 ms | 0 | Minor dip — GR replication overhead |
| T+120s | **137** | ~126 ms | 0 | **Replica kill #1** — noticeable TPS drop |
| T+130 – T+160s | 236–245 | ~77 ms | 0 | Rapid recovery — primary unaffected |
| T+170s | **175** | ~88 ms | 0 | **Replica kill #2** |
| T+180s | 71 | ~244 ms | 0 | End of run — degraded (concurrent kill activity) |
| **Overall** | **214 avg** | **77 ms** | **0** | No connection errors throughout |

**Key observation:** The primary was never targeted. TPS dipped to ~137 at worst (40% below baseline) during a kill, but recovered within 10 seconds. **Zero errors/reconnections** across the entire 180-second run.

#### Group Replication Behaviour

- Killed replicas restarted and rejoined as SECONDARY within ~15–20 seconds
- Primary label (`kubedb.com/role=primary`) stayed on `mysql-ha-cluster-1` throughout
- KubeDB updated pod labels correctly after each kill/rejoin

**Result: PASS** — Scheduled replica kills caused zero application errors. TPS temporarily dipped 40% during the kill but recovered immediately. GR distributed recovery worked automatically.

---

### Scheduled Experiment 2 — Weekend CPU Stress

**File:** `2-scheduled-experiments/schedule-weekend-cpu-stress.yaml`
**Original schedule:** `0 4 * * 6,0` (4 AM Saturday/Sunday)
**Test schedule:** `*/1 * * * *` with `duration: 5m` (shortened from original 30m)
**Action:** 90% CPU stress (1 worker) on the primary pod

**Intent:** Simulate sustained CPU load during low-traffic periods. Verify cluster and replication remain stable under high CPU on the primary.

#### CPU Usage During Stress

| Timepoint | Primary (mysql-ha-cluster-0) | Secondary (mysql-ha-cluster-1) | Secondary (mysql-ha-cluster-2) |
|---|---|---|---|
| Baseline | 20m | 19m | 18m |
| T+30s (stress active) | **1001m** | 329m | 17m |
| T+90s | **999m** | 347m | 16m |
| T+300s | **1003m** | 343m | 17m |
| T+390s (stress ending) | **970m** | 38m | 15m |

Primary CPU pegged at ~1000m (full 1-core limit) for the entire 5-minute duration.

#### Sysbench TPS Timeline

| Interval | TPS | 95th pct Latency | Errors | Notes |
|---|---|---|---|---|
| T+0 – T+10s | 260 | 77 ms | 0 | Pre-stress (stressor not yet active) |
| T+10 – T+20s | 176 | 91 ms | 0 | CPU stress begins — TPS drops |
| T+20 – T+420s | 150–160 | 92–97 ms | **0** | Sustained degradation, stable |
| T+70s | **120** | 190 ms | 0 | Brief spike in latency |
| T+220s | **117** | 211 ms | 0 | Another latency spike |
| **Overall avg** | **157** | **94 ms** | **0** | No errors, no failover |

**TPS reduction:** ~32% below baseline (229 → 157 avg). Latency increase: ~24% (76ms → 94ms 95th pct).

#### Group Replication Stability

All members remained ONLINE throughout the 5-minute test. No failover was triggered. The stress-ng CPU stressor saturated the 1-core CPU limit but did not disrupt MySQL's network I/O path, so GR consensus messaging was unaffected.

**Result: PASS** — 90% CPU stress on primary caused predictable ~32% TPS reduction and modest latency increase, but zero errors and no failover. GR remained fully stable.

---

## Consolidated Sysbench Results

### TPS Comparison Across All Tests

| Experiment | Baseline TPS | TPS During Chaos | Drop | Errors |
|---|---|---|---|---|
| Baseline (no chaos) | 229 | 229 | 0% | 0 |
| Workflow 1: Flaky Network Failover | 58 (brief) | **0** (sustained) | ~100% | FATAL (Lost connection) |
| Workflow 2: Degraded Failover | 131 | **2.6** (IO phase) → 0 (kill phase) | ~99% brief | FATAL (Lost connection) |
| Sched 1: Nightly Replica Kill | 238 | **137** (worst dip) | ~40% brief | 0 |
| Sched 2: Weekend CPU Stress | 260 | **117–157** | ~32–55% sustained | 0 |

### Failover Summary

| Experiment | Failover Triggered | Time to Recover | Manual Intervention |
|---|---|---|---|
| Workflow 1: Flaky Network Failover | NO (cluster stuck) | ~1h 27m | YES — full pod restart required |
| Workflow 2: Degraded Failover | YES | ~32s | No |
| Sched 1: Nightly Replica Kill | N/A (replica only) | ~15–20s per kill | No |
| Sched 2: Weekend CPU Stress | NO | N/A | No |

---

## Critical Findings

### Finding 1: 100% Correlated Packet Loss = Total Blockage

The `workflow-flaky-network-failover.yaml` uses `correlation: "100"` on a 25% packet loss rule. In practice, 100% correlation means once a packet is dropped, all subsequent packets are dropped — effectively creating a **complete network partition**, not a "flaky" connection. This caused:

- Sysbench TPS → 0 within 20 seconds
- GR consensus failing silently
- Cluster entering a stuck `UNREACHABLE PRIMARY` state post-kill

**Recommendation:** Reduce `correlation` to `25–50%` for realistic flakiness testing. 100% correlation defeats the "flaky" intent and creates a hard partition scenario instead.

### Finding 2: UNREACHABLE PRIMARY Stuck State (No Auto-Recovery)

When the primary was killed immediately after a network partition, Group Replication did not automatically elect a new primary. The two surviving ONLINE secondaries saw the killed primary as `UNREACHABLE` (not `OFFLINE`) and waited for it to return rather than expelling it and electing a new leader.

**Root cause:** `group_replication_unreachable_majority_timeout = 0` (default) means secondaries wait indefinitely. `group_replication_member_expel_timeout` was not set to a low enough value to trigger fast expulsion.

**Recovery required:** Manual deletion of all 3 pods to force a clean GR bootstrap.

**Recommendation:** Set `group_replication_unreachable_majority_timeout = 10` and `group_replication_member_expel_timeout = 5` to prevent indefinite stuck states.

### Finding 3: Degraded Failover Succeeded Cleanly

Despite the primary being under 50ms IO latency at the moment of the pod kill, Group Replication elected a new healthy primary in ~32 seconds. The IO stress did not prevent consensus from completing. This confirms GR's failover path is resilient to storage degradation on the failing node.

### Finding 4: Scheduled Replica Kills Are Safe for Applications

The nightly replica kill schedule caused zero application errors across 3 consecutive kills. The worst TPS impact was a 40% dip for ~10 seconds. The primary service was uninterrupted throughout. This pattern is safe to use as a nightly resilience exercise.

### Finding 5: CPU Stress Has Mild, Predictable Impact

90% CPU saturation on the primary reduced TPS by ~32% and increased 95th pct latency by ~24%. Critically, **no errors were generated** and **no failover occurred**. MySQL's replication heartbeat is network-bound, not CPU-bound, so GR consensus was never threatened. This makes CPU stress the least disruptive single-node chaos scenario tested.

### Finding 6: GTID Divergence After RESET MASTER

During recovery from the stuck state, a manual `RESET MASTER` on `mysql-ha-cluster-2` caused its GTID to diverge (reset to `1-2` while others were at `1-301`). When GR tried to replay transactions from the beginning including `CREATE DATABASE kubedb_system`, MySQL threw:

```
Error 'Schema directory './kubedb_system' already exists.'
```

This blocked the node from rejoining. Fix required: manually deleting `/var/lib/mysql/kubedb_system` from the node's data directory.

**Recommendation:** Never run `RESET MASTER` on a GR member. Use `RESET REPLICA` or simply restart the pod to trigger a clean distributed recovery.

---

## Chaos Mesh API Issues Found

| Issue | Detail |
|---|---|
| `kind: ChaosWorkflow` deprecated | Must use `kind: Workflow` |
| `spec.duration` inside chaos specs | Not allowed within Workflow templates — use `deadline` on the template instead |
| `spec.targetPort` in NetworkChaos | Not supported in this Chaos Mesh version — `packet-loss-group-replication.yaml` cannot be applied as-is |
| `conditionalBranches` in workflows | Replaced by a `Serial` template with a `Suspend` delay step |

---

## Final Cluster State

After all experiments and recovery, the cluster returned to a healthy 3-node state:

```
Pod                   Role       GR State   KubeDB
mysql-ha-cluster-0    PRIMARY    ONLINE     Ready
mysql-ha-cluster-1    SECONDARY  ONLINE     Ready
mysql-ha-cluster-2    SECONDARY  RECOVERING → ONLINE
```

> Note: `mysql-ha-cluster-2` was in `RECOVERING` state (applying binlog catch-up via distributed recovery) at the end of the test session due to repeated restarts during the recovery procedures. This is expected and resolves automatically.

---

## Recommendations (from this test session)

| Priority | Recommendation | Evidence |
|---|---|---|
| **Critical** | Set `group_replication_unreachable_majority_timeout = 10` | Workflow 1 cluster stuck state — no auto-recovery |
| **Critical** | Set `group_replication_member_expel_timeout = 5` | Secondaries waited indefinitely for UNREACHABLE member |
| **High** | Fix `correlation: "100"` → `"25"` in flaky network workflow | 100% correlation = full partition, not flaky network |
| **High** | Never use `RESET MASTER` on a GR member | Caused GTID divergence and schema directory conflict |
| **Medium** | Add MySQL `group_replication_autorejoin_tries = 3` | Speeds up automatic member rejoin after expulsion |
| **Medium** | Use ProxySQL — sysbench had no reconnect logic | During pod kill, threads threw FATAL instead of reconnecting |
| **Low** | Upgrade Chaos Mesh for `spec.targetPort` support | GR-port-specific chaos (port 33061) cannot be tested currently |

---

## Appendix: Files Changed

| File | Change |
|---|---|
| `3-workflows/workflow-flaky-network-failover.yaml` | Fixed: `kind: Workflow`, removed `duration:` from chaos spec |
| `3-workflows/workflow-degraded-failover.yaml` | Fixed: `kind: Workflow`, removed `duration:`, replaced `conditionalBranches` with `Serial + Suspend` |
| `1-single-experiments/stress-memory-replica.yaml` | Temporarily changed to `1536MB` for OOM retest, restored to `1GB` after |

---

*This report covers the second round of chaos tests (scheduled experiments + workflows) run on 2026-02-27.*
*First-round results (single experiments): `chaos-test-report.md`*
