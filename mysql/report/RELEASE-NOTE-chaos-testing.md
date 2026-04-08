# KubeDB MySQL — Chaos Engineering Test Results

**Release Date:** April 2026
**Scope:** MySQL Group Replication (Single-Primary) — Data Safety & Resilience Validation
**Test Framework:** Chaos Mesh on Kubernetes
**Load Generator:** sysbench (oltp_write_only / oltp_read_write)
**Managed By:** KubeDB Operator with hardened MySQL Coordinator

---

## Executive Summary

We conducted **48 chaos experiments** across **4 MySQL versions** (5.7.44, 8.0.36, 8.4.8, 9.6.0) on KubeDB-managed 3-node Group Replication clusters in Single-Primary mode. The goal was to validate **zero data loss**, **automatic failover**, and **self-healing recovery** under realistic failure conditions with production-level write loads.

### Key Results

| Metric | Result |
|---|---|
| Total experiments | 48 (12 per version) |
| MySQL versions tested | 5.7.44, 8.0.36, 8.4.8, 9.6.0 |
| Data loss incidents | **Zero** (across all versions 8.0+) |
| Split-brain incidents | **Zero** |
| Persistent errant GTIDs | **Zero** (8.0+) |
| Automatic failover success rate | **100%** (8.0+) |
| Cluster self-recovery rate | **100%** (8.0+) |
| Critical coordinator bugs found & fixed | **15** |

**Verdict:** KubeDB MySQL 8.0.36, 8.4.8, and 9.6.0 pass all chaos experiments with zero data loss. MySQL 5.7.44 has a known limitation (no CLONE plugin) that prevents automatic recovery from OOMKill — upgrade to 8.0+ is recommended.

---

## Test Environment

| Component | Details |
|---|---|
| Cluster Topology | 3-node Group Replication (Single-Primary) |
| Storage | 2Gi PVC per node (Durable, ReadWriteOnce) |
| Memory Limit | 1.5Gi per MySQL pod |
| CPU Request | 500m per pod |
| Load Generator | sysbench oltp_write_only, 4 tables x 50k rows, 4-16 threads |
| Baseline TPS | ~2,400-2,500 transactions/sec |

---

## Load Generation — sysbench

All chaos experiments were run under **sustained write load** using [sysbench](https://github.com/akopytov/sysbench) to simulate production traffic during failures. The load generator ran as a Kubernetes Deployment (`perconalab/sysbench:latest`) inside the same namespace as the MySQL cluster.

### Configuration

| Parameter | Value |
|---|---|
| Image | `perconalab/sysbench:latest` |
| Workload | `oltp_write_only` (primary), `oltp_read_write` (OOMKill tests) |
| Tables | 4 (standard tests), 12 (high-load tests) |
| Table Size | 50,000 rows per table (standard), up to 2,000,000 (high-load) |
| Threads | 8 (standard), 16 (combined stress), 128 (OOMKill) |
| Duration | 60-180 seconds per run |
| Report Interval | 10 seconds |
| Target Host | `mysql-ha-cluster.demo.svc.cluster.local:3306` |
| Baseline TPS | ~2,400-2,500 transactions/sec |

### sysbench Commands Used

```bash
# Prepare (create tables and populate data)
sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster --mysql-port=3306 \
  --mysql-user=root --mysql-password="${MYSQL_PASSWORD}" \
  --mysql-db=sbtest --tables=12 --table-size=500000 \
  --threads=8 prepare

# Run during chaos tests
sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster --mysql-port=3306 \
  --mysql-user=root --mysql-password="${MYSQL_PASSWORD}" \
  --mysql-db=sbtest --tables=12 --table-size=2000000 \
  --threads=16 --time=180 --report-interval=10 run

# Cleanup
sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster --mysql-port=3306 \
  --mysql-user=root --mysql-password="${MYSQL_PASSWORD}" \
  --mysql-db=sbtest --tables=12 cleanup
```

### Why sysbench?

- Generates **realistic OLTP write traffic** with INSERT, UPDATE, DELETE operations
- Measures **TPS, latency (p95/p99), and error counts** during chaos
- Detects **connection failures** immediately when a primary goes down (FATAL: lost connection)
- Validates that the cluster can **resume accepting writes** after failover without manual intervention

---

## Chaos Experiment Matrix

12 experiments were executed per MySQL version, covering single-node failures, resource exhaustion, network degradation, and complex multi-fault scenarios:

| # | Experiment | Chaos Type | Description |
|---|---|---|---|
| 1 | Pod Kill Primary | PodChaos | Immediate ungraceful termination (grace-period=0) |
| 2 | OOMKill Primary | StressChaos / Load | Memory exhaustion beyond 1.5Gi limit |
| 3 | Network Partition | NetworkChaos | Isolate primary from replicas for 2 min |
| 4 | IO Latency (100ms) | IOChaos | 100ms delay on all disk I/O operations |
| 5 | Network Latency (1s) | NetworkChaos | 1s delay + 50ms jitter on replication traffic |
| 6 | CPU Stress (98%) | StressChaos | 98% CPU load on primary |
| 7 | Packet Loss (30%) | NetworkChaos | 30% packet drop across all nodes |
| 8 | Combined Stress | StressChaos x3 | Memory + CPU + load on all nodes simultaneously |
| 9 | Full Cluster Kill | kubectl delete | Force-delete all 3 pods simultaneously |
| 10 | OOMKill Retry | Load | 128-thread sysbench + large JOIN queries |
| 11 | Scheduled Replica Kill | Schedule | Kill random replica every 30s for 3 min |
| 12 | Degraded Failover | Workflow | IO latency + pod kill in sequence |

---

## Results by MySQL Version

### MySQL 9.6.0 — All 12 PASSED

| # | Experiment | Failover | Data Loss | Errant GTIDs | Verdict |
|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | 0 | **PASS** |
| 2 | OOMKill Natural | Yes | Zero | 0 | **PASS** |
| 3 | Network Partition | Yes | Zero | 0 | **PASS** |
| 4 | IO Latency (100ms) | No | Zero | 0 | **PASS** |
| 5 | Network Latency (1s) | No | Zero | 0 | **PASS** |
| 6 | CPU Stress (98%) | No | Zero | 0 | **PASS** |
| 7 | Packet Loss (30%) | Yes | Zero | 0 | **PASS** |
| 8 | Combined Stress | Yes (OOMKill) | Zero | 0 | **PASS** |
| 9 | Full Cluster Kill | Yes | Zero | 0 | **PASS** |
| 10 | OOMKill Retry | No (survived) | Zero | 0 | **PASS** |
| 11 | Scheduled Replica Kill | Multiple | Zero | 0 | **PASS** |
| 12 | Degraded Failover | Yes | Zero | 0 | **PASS** |

### MySQL 8.4.8 — All 12 PASSED

| # | Experiment | Failover | Data Loss | Errant GTIDs | Verdict |
|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | 0 | **PASS** |
| 2 | OOMKill Stress | No (survived) | Zero | 0 | **PASS** |
| 3 | Network Partition | Yes | Zero | 0 | **PASS** |
| 4 | IO Latency (100ms) | No | Zero | 0 | **PASS** |
| 5 | Network Latency (1s) | No | Zero | 0 | **PASS** |
| 6 | CPU Stress (98%) | No | Zero | 0 | **PASS** |
| 7 | Packet Loss (30%) | Yes | Zero | 0 | **PASS** |
| 8 | Combined Stress | Yes (OOMKill) | Zero | 0 | **PASS** |
| 9 | Full Cluster Kill | Yes | Zero | 0 | **PASS** |
| 10 | OOMKill Natural | No (survived) | Zero | 0 | **PASS** |
| 11 | Scheduled Replica Kill | Multiple | Zero | 0 | **PASS** |
| 12 | Degraded Failover | Yes | Zero | 0 | **PASS** |

### MySQL 8.0.36 — All 12 PASSED

| # | Experiment | Failover | Data Loss | Errant GTIDs | Verdict |
|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | 0 | **PASS** |
| 2 | OOMKill Natural | No (survived) | Zero | 0 | **PASS** |
| 3 | Network Partition | Yes | Zero | 0 | **PASS** |
| 4 | IO Latency (100ms) | No | Zero | 0 | **PASS** |
| 5 | Network Latency (1s) | No | Zero | 0 | **PASS** |
| 6 | CPU Stress (98%) | No | Zero | 0 | **PASS** |
| 7 | Packet Loss (30%) | Yes | Zero | 0 | **PASS** |
| 8 | Combined Stress | Yes (OOMKill) | Zero | 0 | **PASS** |
| 9 | Full Cluster Kill | Yes | Zero | 0 | **PASS** |
| 10 | OOMKill Natural (retry) | Yes | Zero | 0 | **PASS** |
| 11 | Scheduled Replica Kill | Multiple | Zero | 0 | **PASS** |
| 12 | Degraded Failover | Yes | Zero | 0 | **PASS** |

### MySQL 5.7.44 — 1 PASSED, 1 FAILED, 10 BLOCKED

| # | Experiment | Failover | Data Loss | Errant GTIDs | Verdict |
|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | 0 | **PASS** |
| 2 | OOMKill Natural | Yes | Zero | **1 (persistent)** | **FAIL** |
| 3-12 | All remaining | — | — | — | **BLOCKED** |

**Root cause:** MySQL 5.7 does not support the CLONE plugin (requires 8.0.17+). After OOMKill, a persistent errant GTID prevented the node from rejoining GR. The cluster degraded to 2 nodes with no automatic recovery path.

**Recommendation:** MySQL 5.7 is EOL. Upgrade to MySQL 8.0+ for clone-based recovery and proper errant GTID handling.

---

## Failover Performance

| Scenario | Failover Time | Full Recovery Time |
|---|---|---|
| Pod Kill Primary | ~2-3 seconds | ~30-33 seconds |
| OOMKill Primary | ~2-3 seconds | ~30 seconds |
| Network Partition | ~3 seconds | ~3 minutes |
| Packet Loss (30%) | ~30 seconds | ~2 minutes |
| Full Cluster Kill | ~10 seconds | ~1-2 minutes |
| Combined Stress (OOMKill) | ~3 seconds | ~4 minutes |

---

## Performance Impact Under Chaos

| Chaos Type | TPS During Chaos | Reduction from Baseline (~2,400) | Failover Triggered |
|---|---|---|---|
| IO Latency (100ms) | 2-3.5 | 99.9% | No |
| Network Latency (1s) | 1.2-1.4 | 99.9% | No |
| CPU Stress (98%) | 1,300-1,370 | ~46% | No |
| Packet Loss (30%) | Variable | Triggers failover | Yes |
| Combined Stress | OOMKill | Cluster NotReady, then auto-recovery | Yes |

---

## Data Integrity Validation Methodology

Every experiment verified data integrity through 4 checks across all 3 nodes:

1. **GTID Consistency** — `SELECT @@gtid_executed` must match on all nodes after recovery
2. **Checksum Verification** — `CHECKSUM TABLE` on all sysbench tables must match across nodes
3. **Row Count Validation** — Cumulative tracking table row counts must be preserved
4. **Errant GTID Detection** — No local `server_uuid` GTIDs outside the group UUID

Transient mismatches during active recovery (nodes still catching up) were observed in some experiments but always resolved within 15-30 seconds without intervention.

---

## Coordinator Hardening — 15 Critical Fixes

During chaos testing, we identified and fixed **6 critical**, **6 high**, and **3 medium** severity issues in the MySQL coordinator and init scripts.

### Critical Fixes

| # | Issue | Risk | Fix |
|---|---|---|---|
| C1 | `findMaxTransactedPod()` silently skips unreachable pods | Wrong pod elected, transaction loss | Two-phase election with timeout + GTID subtract verification |
| C2 | No distributed lock for GR full recovery | Split-brain, dual bootstrap | Added locking mechanism before full recovery |
| C3 | `checkPrimaryOnline()` skips self-check | Unnecessary full recovery triggered | Added self-check before peer scan |
| C4 | Infinite loop in `findMaxTransactedPod()` | Coordinator hangs forever | Added 2-minute `podReadyTimeout` |
| C5 | Inverted version check in `LabelPods()` | Writes misdirected to replicas | Swapped query constants |
| C6 | `RESET MASTER` before clone start | GTID history destroyed if clone fails | Moved reset after clone success |

### High-Priority Fixes

| # | Issue | Risk | Fix |
|---|---|---|---|
| H1 | `restartMySQLProcess()` no graceful shutdown | In-flight transaction loss | Added `super_read_only=ON` before shutdown |
| H2 | `SQL_LOG_BIN=0` on separate connections | Errant GTIDs from user creation | Combined into single session |
| H3 | Signal file race condition | Lost clone/join signals | Atomic mv-based file operations |
| H4 | Fire-and-forget cluster operations | No verification of join completion | Added acknowledgment checks |
| H5 | `reboot_from_completeOutage` pipes `yes` | Premature member removal | Removed auto-confirm |
| H6 | Nil pointer in `waitForPreviousToJoin()` | Coordinator panic/crash | Added nil check |

### Additional Fixes

| # | Issue | Fix |
|---|---|---|
| M1 | `partialRecovery()` joins before MySQL ready | Added startup wait |
| M2 | `holdsExtraTransactions()` triggers unnecessary clone on transient errors | Improved error handling |
| M3 | `joined_in_cluster` variable typo in `run_innodb.sh` | Fixed variable name |

---

## Version Compatibility

| Capability | 5.7.44 | 8.0.36 | 8.4.8 | 9.6.0 |
|---|---|---|---|---|
| Pod Kill Recovery | Yes | Yes | Yes | Yes |
| OOMKill Recovery | **No** | Yes | Yes | Yes |
| Network Partition Recovery | Blocked | Yes | Yes | Yes |
| CLONE Plugin | **No** (requires 8.0.17+) | Yes | Yes | Yes |
| Errant GTID Auto-Resolution | **No** | Yes | Yes | Yes |
| All 12 Experiments Pass | **No** (1/12) | **Yes** (12/12) | **Yes** (12/12) | **Yes** (12/12) |

---

## Recommendations

1. **Use MySQL 8.0.36 or later** for production Group Replication deployments. All 36 experiments across 8.0.36, 8.4.8, and 9.6.0 passed with zero data loss.

2. **Upgrade from MySQL 5.7** — 5.7 is EOL and lacks the CLONE plugin needed for automatic recovery from OOMKill and errant GTID scenarios.

3. **Deploy with the hardened coordinator** (image `:19` or later) that includes all 15 critical and high-priority fixes identified during chaos testing.

4. **Set appropriate resource limits** — The 1.5Gi memory limit used in testing is sufficient for moderate workloads. For production, size according to working set.

5. **Monitor transient GTID mismatches** — Brief GTID mismatches (15-30 seconds) are normal during recovery after heavy write loads. These resolve automatically via GR distributed recovery.

---

## What's Next

- **Multi-Primary Mode Testing** — The same 12-experiment matrix will be executed on Multi-Primary Group Replication topology, where all nodes accept writes and conflict detection is the primary concern.
- **Long-duration soak testing** — Extended chaos runs (hours/days) to validate stability under sustained failure injection.
- **Coordinator atomic signal file operations** — Replace file-based signaling with atomic mv-based operations for additional robustness.
