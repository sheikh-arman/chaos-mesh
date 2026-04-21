# KubeDB MariaDB 11.8.5 — Defect Hunt (MariaDBReplication)

**Started:** 2026-04-21
**Target:** `kubedb.com/v1/MariaDB` in `MariaDBReplication` topology (1 Master + 2 Slaves + MaxScale x3)
**Version under test:** MariaDB 11.8.5, KubeDB v2026.2.26
**Focus:** *Find* issues with KubeDB MariaDB — no fixes applied during the hunt.

---

## Cluster Info

| Component | Value |
|---|---|
| MariaDB CR | `md` in namespace `demo` |
| Topology | MariaDBReplication (1 Master + 2 Slaves) |
| Pods | `md-0` Slave, `md-1` Slave, `md-2` Master, `md-mx-0/1/2` MaxScale |
| Proxy | MaxScale, service `md-mx:3306` |
| Storage | 2Gi PVC per node (`data-md-0/1/2`) |
| Sysbench | `sysbench-load-*` pod |
| Auth secret | `md-auth` |

---

## Defects Found

_Table updated as defects are discovered._

| # | Test | Defect | Severity | Reproducer |
|---|---|---|---|---|
| — | — | none yet | — | — |

---

## Test Plan (revised — pure chaos only)

OpsRequest tests deferred. This pass focuses on Chaos-Mesh-style fault injection only.

### Pod / container chaos
1. Pod Kill — Master (`md-2`)
2. Pod Kill — Slave (`md-1`)
3. Pod Kill — MaxScale (`md-mx-0`)
4. Container Kill — `mariadb` container only (master)
5. Pod Failure (5 min pause) — Master

### Stress chaos
6. Memory stress (OOMKill 1200MB) — Master
7. Memory stress — Slave
8. CPU stress 98% — Master
9. Combined Memory + CPU stress — Master

### IO chaos
10. IO Latency (100ms) — Master
11. IO Latency (100ms) — Slave
12. IO Fault (EIO 50%) — Master
13. IO Fault (EIO 50%) — Slave
14. IO Attr Override (read-only datadir, 5m) — Master
15. IO Mistake (random data corruption) — Master

### Network chaos
16. Network Partition (Master ↔ Slaves, 2m)
17. Network Partition (Slave isolated from cluster)
18. Network Partition (MaxScale ↔ MariaDB)
19. Network Latency (1s between nodes)
20. Network Packet Loss (30%)
21. Network Packet Duplicate (50%)
22. Network Packet Corrupt (50%)
23. Network Bandwidth Throttle (1 Mbps) — Master

### Time / DNS
24. DNS Error on Master
25. Clock Skew (-5 min) on Master

### Full cluster
26. Full MariaDB cluster kill (all 3 pods)
27. Full MaxScale kill (all 3 MaxScale pods)
28. Compound: Master + MaxScale kill simultaneously

### Rolling
29. Rolling restart (delete md-0 → md-1 → md-2 with 40s gap)

---

## Test Log

### Test 0 — Baseline sanity
**Setup:** reset `sbtest` DB (only `testdb` existed pre-test), prepared sysbench 4 tables × 50k rows, created `chaos_track.markers` tracking table. Initial state: md-2 Master, md-0/md-1 Slaves, all `Slave_IO_Running=Yes, SQL_Running=Yes, Seconds_Behind_Master=0`.
**Baseline TPS:** 949 (15s run, 4 threads, via MaxScale `md-mx:3306`), 19k QPS, 0 errors.
**Defect found:** none.

### Test 1 — Pod Kill Master (`md-2`)
**Chaos:** `PodChaos action=pod-kill mode=one labelSelector{kubedb.com/role=Master}`, gracePeriod=0.
**Expected:** Master killed → failover to a Slave → MaxScale re-routes → killed pod recreated as Slave → cluster `Ready`, zero data loss.
**Observed:**
- Sysbench uninterrupted: **1043 TPS** (actually higher than baseline, no reconnects, 4 ignored errors).
- Failover md-2 → md-0 completed. md-0 became Master, md-1/md-2 Slaves replicating from md-0.
- All 3 nodes: 2/2 markers preserved, checksums identical (`sbtest1=535950349` across all).
- MariaDB CR stayed `Ready` throughout (never went `Critical` or `NotReady` — maxscale kept serving).
**Defect found:** none.

---
