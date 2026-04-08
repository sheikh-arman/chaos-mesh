# KubeDB MySQL — Chaos Engineering Test Results

**Release Date:** April 2026
**Scope:** MySQL Group Replication (Single-Primary & Multi-Primary) — Data Safety & Resilience Validation
**Test Framework:** Chaos Mesh on Kubernetes
**Load Generator:** sysbench (oltp_write_only / oltp_read_write)
**Managed By:** KubeDB Operator with hardened MySQL Coordinator

---

## Executive Summary

We conducted **60 chaos experiments** across **4 MySQL versions** (5.7.44, 8.0.36, 8.4.8, 9.6.0) and **2 GR topologies** (Single-Primary and Multi-Primary) on KubeDB-managed 3-node Group Replication clusters. The goal was to validate **zero data loss**, **automatic failover/recovery**, and **self-healing** under realistic failure conditions with production-level write loads.

### Key Results

| Metric | Result |
|---|---|
| Total experiments | 60 (48 Single-Primary + 12 Multi-Primary) |
| MySQL versions tested | 5.7.44, 8.0.36, 8.4.8, 9.6.0 |
| GR topologies tested | Single-Primary, Multi-Primary |
| Data loss incidents | **Zero** (across all versions 8.0+, both topologies) |
| Split-brain incidents | **Zero** |
| Persistent errant GTIDs | **Zero** (8.0+) |
| Automatic failover success rate | **100%** (8.0+) |
| Cluster self-recovery rate | **100%** (8.0+, both topologies) |

**Verdict:** KubeDB MySQL 8.0.36, 8.4.8, and 9.6.0 pass all chaos experiments with zero data loss in both Single-Primary and Multi-Primary modes. MySQL 5.7.44 has a known limitation (no CLONE plugin) that prevents automatic recovery from OOMKill — upgrade to 8.0+ is recommended.

---

## Test Environment

| Component | Details |
|---|---|
| Cluster Topology | 3-node Group Replication (Single-Primary & Multi-Primary) |
| Storage | 2Gi PVC per node (Durable, ReadWriteOnce) |
| Memory Limit | 1.5Gi per MySQL pod |
| CPU Request | 500m per pod |
| Load Generator | sysbench oltp_write_only, 4-12 tables x 50k-100k rows, 4-16 threads |
| Baseline TPS | ~1,150 (Multi-Primary) / ~2,400 (Single-Primary) |
| Coordinator (Multi-Primary) | `skaliarman/mysql-coordinator:23` |

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

## Results — Single-Primary Mode

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

## Results — Multi-Primary Mode (MySQL 8.4.8)

**Coordinator:** `skaliarman/mysql-coordinator:23`
**GR Mode:** `group_replication_single_primary_mode=OFF` (all nodes writable)

| # | Experiment | Chaos Type | Data Loss | GTIDs | Checksums | Verdict |
|---|---|---|---|---|---|---|
| 1 | Pod Kill (random) | PodChaos | Zero | MATCH | MATCH | **PASS** |
| 2 | OOMKill (1200MB stress) | StressChaos | Zero | MATCH | MATCH | **PASS** |
| 3 | Network Partition (3 min) | NetworkChaos | Zero | MATCH | MATCH | **PASS** |
| 4 | CPU Stress (98%, 3 min) | StressChaos | Zero | MATCH | MATCH | **PASS** |
| 5 | IO Latency (100ms, 3 min) | IOChaos | Zero | MATCH | MATCH | **PASS** |
| 6 | Network Latency (1s, 3 min) | NetworkChaos | Zero | MATCH | MATCH | **PASS** |
| 7 | Packet Loss (30%, 3 min) | NetworkChaos | Zero | MATCH | MATCH | **PASS** |
| 8 | Combined Stress (mem+cpu+load) | StressChaos x2 | Zero | MATCH | MATCH | **PASS** |
| 9 | Full Cluster Kill | kubectl delete | Zero | MATCH | MATCH | **PASS** |
| 10 | OOMKill Natural (90 JOINs) | Load | Zero | MATCH | MATCH | **PASS** |
| 11 | Scheduled Pod Kill (every 1 min) | Schedule | Zero | MATCH | MATCH | **PASS** |
| 12 | Degraded Failover (IO + Kill) | Workflow | Zero | MATCH | MATCH | **PASS** |

### Multi-Primary Key Findings

- **No failover election needed** — all nodes are primaries; when one goes down, the other two continue writes
- **GR certification sensitivity** — 98% CPU stress on all pods blocks all writes (Paxos consensus fails); writes resume instantly after stress removed
- **Packet loss improved with coordinator :23** — 30% packet loss no longer causes ERROR state (all pods stayed ONLINE)
- **Zero data loss** across all 12 experiments with full GTID and checksum consistency

### Multi-Primary Performance Under Chaos

| Chaos Type | TPS During Chaos | Impact |
|---|---|---|
| IO Latency (100ms) | 272 | ~73% drop |
| Network Latency (1s) | 1.57 | 99.9% drop |
| CPU Stress (98%) | 0 (writes blocked) | Paxos consensus fails |
| Packet Loss (30%) | 4.98 | 99.6% drop |
| Combined Stress | ~530 → OOMKill at 110s | ~44% drop then pod killed |
| OOMKill Natural | 372 (no OOMKill) | ~68% drop from query load |

### Multi-Primary vs Single-Primary Comparison

| Aspect | Multi-Primary | Single-Primary |
|---|---|---|
| Failover needed | No (all primaries) | Yes (election ~2-3s) |
| Write availability | All nodes writable | Only primary writable |
| CPU stress 98% | All writes blocked (Paxos fails) | ~46% TPS reduction |
| IO latency TPS | ~272 | ~3.5 |
| Packet loss 30% | 4.98 TPS (stayed ONLINE) | Triggers failover |
| High concurrency | GR certification conflicts possible | No conflicts (single writer) |
| Recovery mechanism | Rejoin as PRIMARY | Election + rejoin |

---

## Failover Performance (Single-Primary)

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

## Version Compatibility

| Capability | 5.7.44 | 8.0.36 | 8.4.8 | 9.6.0 |
|---|---|---|---|---|
| Pod Kill Recovery | Yes | Yes | Yes | Yes |
| OOMKill Recovery | **No** | Yes | Yes | Yes |
| Network Partition Recovery | Blocked | Yes | Yes | Yes |
| CLONE Plugin | **No** (requires 8.0.17+) | Yes | Yes | Yes |
| Errant GTID Auto-Resolution | **No** | Yes | Yes | Yes |
| Single-Primary (12 experiments) | **No** (1/12) | **Yes** (12/12) | **Yes** (12/12) | **Yes** (12/12) |
| Multi-Primary (12 experiments) | Not tested | Not tested | **Yes** (12/12) | Not tested |

---

## Recommendations

1. **Use MySQL 8.0.36 or later** for production Group Replication deployments. All 48 experiments across 8.0.36, 8.4.8, and 9.6.0 (both topologies) passed with zero data loss.

2. **Upgrade from MySQL 5.7** — 5.7 is EOL and lacks the CLONE plugin needed for automatic recovery from OOMKill and errant GTID scenarios.

3. **Multi-Primary mode is production-ready** — All 12 chaos experiments passed on MySQL 8.4.8 with coordinator `:23`. Be aware that multi-primary has higher sensitivity to CPU stress and network issues due to Paxos consensus requirements on all writable nodes.

4. **Set appropriate resource limits** — The 1.5Gi memory limit used in testing is sufficient for moderate workloads. For production, size according to working set.

5. **Monitor transient GTID mismatches** — Brief GTID mismatches (15-30 seconds) are normal during recovery after heavy write loads. These resolve automatically via GR distributed recovery.

---

## What's Next

- **Multi-Primary testing on additional MySQL versions** — Extend Multi-Primary chaos testing to MySQL 8.0.36 and 9.6.0.
- **Long-duration soak testing** — Extended chaos runs (hours/days) to validate stability under sustained failure injection.
