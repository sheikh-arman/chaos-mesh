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
| 4 | IO Latency (100ms) | IOChaos | PASS | Node unresponsive during, auto-rejoin after | 25/25 markers, checksums MATCH |
| 5 | Network Latency (1s) | NetworkChaos | PASS | Severe TPS drop (1039→3), no errors, auto-recover | 25/25 markers, checksums MATCH |
| 6 | CPU Stress (98%) | StressChaos | PASS | No impact, 1034 TPS, all Synced | 25/25 markers, checksums MATCH |
| 7 | Packet Loss (30%) | NetworkChaos | PASS | Severe TPS drop (1039→1.3), no expulsion, 0 errors | 25/25 markers, checksums MATCH |
| 8 | Full Cluster Kill | PodChaos | PASS | ~3 min full recovery, Galera bootstrap | 25/25 markers, checksums MATCH |
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

### #6 CPU Stress (98%)
- **File:** `1-single-experiments/stress-cpu-primary.yaml`
- **Action:** 98% CPU stress on one node (2 workers) for 5 minutes
- **During:** All 3 nodes Synced, cluster_size=3. wsrep_flow_control_paused=0.012
- **Sysbench during:** 1034 TPS (barely any drop from 1039 baseline), 0 errors
- **Data:** 25/25 markers on all nodes, checksums MATCH
- **Result:** PASS (CPU stress had negligible impact on Galera cluster)

### #5 Network Latency (1s between nodes)
- **File:** `1-single-experiments/network-latency-primary-to-replicas.yaml`
- **Action:** 1s latency + 50ms jitter on network between one node and all others, 10min duration
- **During:** All 3 nodes stayed Synced (cluster_size=3) — no node expulsion
- **Sysbench during:** TPS dropped from 1039 to 2.77 (99.7% drop!). P95 latency: 2045ms. But 0 errors, 0 reconnects
- **Key insight:** Galera certification requires every write to be acknowledged across all nodes. 1s network latency means every transaction takes at least 1s to certify
- **Data:** 25/25 markers on all nodes, checksums MATCH
- **Result:** PASS (no data loss, cluster stayed operational but severely degraded)

### #4 IO Latency (100ms on all disk ops)
- **File:** `1-single-experiments/io-latency-primary.yaml`
- **Action:** 100ms latency on all IO operations in /var/lib/mysql for 3 minutes
- **During:** Affected node (md-1) became unresponsive (socket connection refused). Galera cluster_size dropped to 2 on healthy nodes
- **Galera during:** md-0: cluster_size=2, Synced. md-2: cluster_size=2, Synced. md-1: unresponsive
- **Sysbench on 2 healthy nodes:** 1450 TPS, 29k QPS, 0 errors
- **Recovery:** After chaos expired, md-1 auto-rejoined, all 3 Synced, cluster_size=3
- **Data:** 25/25 markers on all nodes, checksums MATCH
- **Result:** PASS

