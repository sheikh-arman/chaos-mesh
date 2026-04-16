# MariaDB Galera Cluster Chaos Test Report

**Version:** MariaDB 11.8.5
**Topology:** Galera Cluster (3 nodes, all Primary/read-write)
**Date:** 2026-04-16
**Cluster:** md (namespace: demo)
**Baseline:** ~1039 TPS, ~20k QPS (sysbench oltp_read_write, 4 threads)
**Tracking rows:** 25 rows in chaos_track.markers

---

## Test Results

| # | Experiment | Type | Result | Recovery | Data Intact |
|---|---|---|---|---|---|
| 1 | Pod Kill | PodChaos | PASS | ~5s (auto-rejoin, all Synced) | 25/25 markers, checksums MATCH |
| 2 | OOMKill (memory stress 1200MB) | StressChaos | PASS | No OOMKill (survived), 1050 TPS | 25/25 markers, checksums MATCH |
| 3 | Network Partition | NetworkChaos | PASS | Auto-rejoin after 2m, all Synced | 25/25 markers, checksums MATCH |
| 4 | IO Latency (100ms) | IOChaos | - | - | - |
| 5 | Network Latency (1s) | NetworkChaos | - | - | - |
| 6 | CPU Stress (98%) | StressChaos | - | - | - |
| 7 | Packet Loss (30%) | NetworkChaos | - | - | - |
| 8 | Full Cluster Kill | PodChaos | - | - | - |
| 9 | DNS Error | DNSChaos | - | - | - |
| 10 | IO Fault (EIO 50%) | IOChaos | - | - | - |
| 11 | Clock Skew (-5 min) | TimeChaos | - | - | - |
| 12 | Bandwidth Throttle (1mbps) | NetworkChaos | - | - | - |

---

## Experiment Details

### #1 Pod Kill
- **File:** `1-single-experiments/pod-kill-primary.yaml`
- **Action:** Kill one MariaDB pod (gracePeriod=0)
- **Pre-state:** All 3 nodes Synced, wsrep_cluster_size=3
- **During:** Pod md-0 killed, recreated in ~5s
- **Galera during:** md-1 and md-2 stayed Synced (cluster_size briefly 2), md-0 rejoined as Synced
- **Post-recovery sysbench:** 1061 TPS, 21k QPS, 0 errors, 0 reconnects
- **Data:** 25/25 markers on all nodes, checksums MATCH across all 3 nodes
- **Result:** PASS

### #2 OOMKill (Memory Stress 1200MB)
- **File:** `1-single-experiments/stress-memory-primary.yaml`
- **Action:** 1200MB memory stress on one node (pod limit: 1.5Gi)
- **During:** No OOMKill triggered — MariaDB survived with 1200MB stress
- **Sysbench during stress:** 1050 TPS, 21k QPS, 0 reconnects
- **Data:** 25/25 markers on all nodes, checksums MATCH
- **Result:** PASS (no OOMKill, cluster fully operational under memory pressure)

### #3 Network Partition (2 min)
- **File:** `1-single-experiments/network-partition-primary.yaml`
- **Action:** Isolate one node from the other 2 for 2 minutes
- **During:** Isolated node (md-2): wsrep_cluster_size=1, non-Primary, wsrep_ready=OFF. Remaining 2 nodes: cluster_size=2, Synced, wsrep_ready=ON
- **DB status:** Critical (quorum maintained by 2 nodes, writes accepted)
- **Sysbench during partition:** 1430 TPS (37% increase — less Galera certification overhead with 2 nodes)
- **Recovery:** Isolated node auto-rejoined after partition expired, all 3 Synced
- **Data:** 25/25 markers on all nodes, checksums MATCH
- **Key observation:** `wsrep_flow_control_paused` on isolated node was 0.007 (low), confirming it was disconnected not congested
- **Result:** PASS

