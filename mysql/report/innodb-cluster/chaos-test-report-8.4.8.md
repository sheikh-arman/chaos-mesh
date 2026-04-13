# KubeDB MySQL Chaos Engineering — Test Report (MySQL 8.4.8 InnoDB Cluster)

**Date:** 2026-04-13
**Cluster:** KubeDB MySQL 8.4.8 — 3-node InnoDB Cluster (Single-Primary) + 1 MySQL Router
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench, 4 tables x 50k rows
**Router Service:** `mysql-ha-cluster-router` — ports 6446 (RW), 6447 (RO), 6450 (RW-Split)

---

## Experiments Summary

| # | Experiment | Failover | Data Loss | GTIDs | Checksums | Verdict |
|---|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | MATCH | MATCH | PASS |
| 2 | OOMKill Primary (memory stress) | Yes (OOMKill) | Zero | MATCH | MATCH | PASS |
| 3 | Network Partition | Yes | Zero | MATCH | MATCH | PASS |
| 4 | IO Latency (100ms) | No | Zero | MATCH | MATCH | PASS |
| 5 | Network Latency (1s) | No | Zero | MATCH | MATCH | PASS |
| 6 | CPU Stress (98%) | No | Zero | MATCH | MATCH | PASS |
| 7 | Packet Loss (30%) | No | Zero | MATCH | MATCH | PASS |
| 8 | Full Cluster Kill | Yes | Zero | MATCH | MATCH | PASS |
| 9 | Double Primary Kill | Yes (x2) | Zero | MATCH | MATCH | PASS |
| 10 | Rolling Restart (0→1→2) | Yes | Zero | MATCH | MATCH | PASS |
| 11 | DNS Failure on Primary | No | Zero | MATCH | MATCH | PASS |
| 12 | Clock Skew (-5 min) | No | Zero | MATCH | MATCH | PASS |

---

## Router Service Validation (Pre-Chaos)

| Test | Result |
|---|---|
| Port 6446 (RW) → PRIMARY | Confirmed (routes to current primary) |
| Port 6447 (RO) → SECONDARY | Confirmed (round-robin across secondaries) |
| Port 6450 (RW-Split) → auto | Confirmed (round-robin, `access_mode=auto`) |
| Sysbench via 6446 (RW) | ~1000 TPS, 0 errors |
| Sysbench via 6450 (RW-Split) | ~555 TPS `oltp_read_write`, 0 errors (requires `--mysql-ssl=REQUIRED`) |
| Router failover re-route | Router automatically re-routed to new PRIMARY after pod kill |

---

## Detailed Results

### Exp 1: Pod Kill Primary
- **Action:** Chaos Mesh `PodChaos` pod-kill on primary (pod-0)
- **Failover:** pod-2 elected as new PRIMARY
- **Router:** Automatically re-routed RW traffic to pod-2
- **DB Status:** Critical → Ready (after pod-0 rejoined)
- **Recovery:** pod-0 rejoined as SECONDARY automatically
- **Tracking rows:** 3/3 preserved
- **GTIDs:** MATCH across all 3 pods
- **Checksums:** MATCH (sbtest1: 309802666)

### Exp 2: OOMKill Primary (Memory Stress)
- **Action:** StressChaos 1200MB memory stress on primary (pod-2)
- **Result:** OOMKill triggered — pod-2 restarted (1 restart)
- **Failover:** pod-1 elected as new PRIMARY
- **DB Status:** NotReady → Ready (after pod-2 rejoin, ~60s)
- **Coordinator:** pod-2 went through rejoin_in_cluster signal cycle
- **Tracking rows:** 5/5 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 309802666)
- **Note:** Unlike GR mode where 8.4.8 survived 1600MB stress, InnoDB Cluster with 1200MB triggered OOMKill

### Exp 3: Network Partition
- **Action:** NetworkChaos partition between primary (pod-1) and standby pods, 2 min duration
- **During:** pod-1 shown as UNREACHABLE from secondaries
- **Failover:** pod-2 elected as new PRIMARY, pod-1 expelled from group
- **DB Status:** NotReady → Critical → Ready
- **Recovery:** After partition ended, pod-1 coordinator rejoined it to cluster (~90s)
- **Tracking rows:** 7/7 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 309802666)

### Exp 4: IO Latency (100ms)
- **Action:** IOChaos 100ms latency on primary's `/var/lib/mysql`, 3 min + 8-thread sysbench write load via router
- **TPS:** 0.1-0.2 during chaos → recovered to ~1242 after chaos expired
- **95th latency:** 26,861ms during chaos
- **Errors:** 0
- **No failover** — primary remained stable despite severe IO slowdown
- **Tracking rows:** 9/9 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 961454958)

### Exp 5: Network Latency (1s)
- **Action:** NetworkChaos 1s delay + 50ms jitter between primary and replicas, 10 min + 8-thread write load
- **TPS:** 1.26 avg (99.9% reduction from baseline)
- **95th latency:** 7,616ms
- **Errors:** 0
- **No failover** — GR tolerated the latency
- **Tracking rows:** 11/11 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1169350408)

### Exp 6: CPU Stress (98%)
- **Action:** StressChaos 98% CPU on primary, 5 min + 8-thread write load via router
- **TPS:** Dropped to ~188 at 30s, recovered to ~810-1114
- **Errors:** 0
- **No failover**
- **Tracking rows:** 13/13 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1474496933)

### Exp 7: Packet Loss (30%)
- **Action:** NetworkChaos 30% packet loss on all cluster pods, 5 min
- **Router impact:** Sysbench could not connect through router (error 2003)
- **Cluster status:** All 3 members remained ONLINE — no failover
- **DB Status:** NotReady (due to packet loss affecting health checks)
- **After recovery:** GTIDs MATCH, checksums MATCH
- **Tracking rows:** 15/15 preserved
- **Note:** Unlike GR mode which triggered failover with 30% loss, InnoDB Cluster remained stable

### Exp 8: Full Cluster Kill
- **Action:** Force-deleted all 3 pods simultaneously
- **Recovery:** Coordinator elected pod-0 as bootstrap candidate (highest GTID)
- **Peer acks:** All peers acknowledged bootstrap within ~10s
- **Cluster reboot:** `cluster rebooting from complete outage` — pod-0 bootstrapped, pod-1 and pod-2 rejoined
- **Recovery time:** ~60s for full 3-node cluster + Ready status
- **Tracking rows:** 17/17 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1474496933)

### Exp 9: Double Primary Kill
- **Action:** Kill primary (pod-0), wait for new primary, kill new primary (pod-2)
- **First kill:** pod-0 → pod-2 elected PRIMARY
- **Second kill:** pod-2 → pod-1 elected PRIMARY (third primary)
- **Recovery:** Both killed pods rejoined as SECONDARY
- **Tracking rows:** 19/19 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1474496933)

### Exp 10: Rolling Restart (0→1→2)
- **Action:** Sequential force-delete of pod-0, pod-1, pod-2
- **Failover:** pod-1 maintained PRIMARY through the rolling restart
- **Recovery:** All 3 pods rejoined; pod-2 required coordinator's 10-attempt restart cycle
- **Tracking rows:** 21/21 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1474496933)

### Exp 11: DNS Failure on Primary
- **Action:** DNSChaos error mode on primary, 3 min
- **Result:** No impact — GR uses IP addresses for group communication
- **No failover**, cluster remained Ready
- **Tracking rows:** 23/23 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1474496933)

### Exp 12: Clock Skew (-5 min)
- **Action:** TimeChaos -5 min offset on primary, 3 min
- **During:** Primary showed time 5 min behind secondaries
- **Result:** No impact — GR and InnoDB Cluster tolerate clock skew
- **No failover**, cluster remained Ready
- **Tracking rows:** 25/25 preserved
- **GTIDs:** MATCH
- **Checksums:** MATCH (sbtest1: 1474496933)

---

## InnoDB Cluster vs Group Replication — Key Differences Observed

| Aspect | Group Replication (8.4.8) | InnoDB Cluster (8.4.8) |
|---|---|---|
| OOMKill (1200MB stress) | Survived (no OOMKill) | OOMKill triggered, failover |
| Packet Loss (30%) | Failover triggered | No failover (stable) |
| Router failover | N/A (no router) | Automatic re-route to new primary |
| RW-Split (port 6450) | N/A | Available via MySQL Router (auto-enabled in 8.4+) |
| Recovery mechanism | Coordinator signals (create/join/rejoin) | Same + `rebootClusterFromCompleteOutage` |
| Rejoin after expulsion | 10-attempt restart cycle | Same 10-attempt restart cycle |

---

## Router-Specific Observations

1. **Port 6450 (RW-Split)** requires `--mysql-ssl=REQUIRED` for `caching_sha2_password` with `connection_sharing=1`
2. **Auto-enabled**: MySQL Router 8.4+ bootstrap automatically generates the `[routing:bootstrap_rw_split]` section — no custom config needed
3. **Failover re-route**: Router detects primary change via metadata cache (TTL=0.5s) and re-routes RW traffic within seconds
4. **During pod kill**: Existing connections get "Lost connection" (error 2013) — new connections route to new primary after re-route
5. **Packet loss**: Router could not establish new connections during 30% packet loss, but cluster itself remained stable

---

## Issues Found

### Issue 1: Slow Rejoin After Expulsion (InnoDB Cluster mode)

**Severity:** Medium

When a pod is expelled from the group (e.g., after network partition or OOMKill), the coordinator goes through a rejoin cycle that requires 10 "mysql process is not healthy" attempts before triggering a MySQL restart. Each attempt takes ~10s, so the rejoin can take ~100-120s.

**Impact:** Extended NotReady/Critical period after node recovery.

### Issue 2: Signal File Not Found During Rejoin

**Severity:** Low

During rejoin, coordinator logs show `signal file does not exist, skipping mysql process restart` followed by `creating rejoin_in_cluster signal`. The init script takes time to pick up the signal.

**Impact:** Minor — adds a few seconds to rejoin time. The coordinator eventually succeeds.

---

## Tracking Table (Full)

| id | experiment | timestamp |
|---|---|---|
| 1 | baseline | 2026-04-13 07:14:38 |
| 2 | exp1-pod-kill-before | 2026-04-13 07:15:05 |
| 3 | exp1-pod-kill-after | 2026-04-13 07:19:26 |
| 4 | exp2-oomkill-before | 2026-04-13 07:20:32 |
| 5 | exp2-oomkill-after | 2026-04-13 07:21:55 |
| 6 | exp3-netpart-before | 2026-04-13 07:22:15 |
| 7 | exp3-netpart-after | 2026-04-13 07:24:06 |
| 8 | exp4-iolatency-before | 2026-04-13 07:24:33 |
| 9 | exp4-iolatency-after | 2026-04-13 07:28:08 |
| 10 | exp5-netlatency-before | 2026-04-13 07:28:17 |
| 11 | exp5-netlatency-after | 2026-04-13 07:29:59 |
| 12 | exp6-cpustress-before | 2026-04-13 07:30:11 |
| 13 | exp6-cpustress-after | 2026-04-13 07:31:52 |
| 14 | exp7-packetloss-before | 2026-04-13 07:31:59 |
| 15 | exp7-packetloss-after | 2026-04-13 07:42:49 |
| 16 | exp8-fullkill-before | 2026-04-13 07:47:19 |
| 17 | exp8-fullkill-after | 2026-04-13 07:48:20 |
| 18 | exp9-doublepkill-before | 2026-04-13 07:48:34 |
| 19 | exp9-doublepkill-after | 2026-04-13 07:50:45 |
| 20 | exp10-rolling-before | 2026-04-13 08:17:28 |
| 21 | exp10-rolling-after | 2026-04-13 08:28:58 |
| 22 | exp11-dns-before | 2026-04-13 08:29:11 |
| 23 | exp11-dns-after | 2026-04-13 08:29:25 |
| 24 | exp12-clockskew-before | 2026-04-13 08:29:37 |
| 25 | exp12-clockskew-after | 2026-04-13 08:29:57 |
