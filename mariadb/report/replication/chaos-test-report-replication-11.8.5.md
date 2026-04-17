# MariaDB Replication Chaos Test Report

**Version:** MariaDB 11.8.5
**Topology:** MariaDBReplication (Master-Slave) + MaxScale Proxy (3 replicas)
**Date:** 2026-04-17
**Cluster:** md (namespace: demo)
**Proxy:** MaxScale (md-mx service, port 3306)
**Baseline:** ~926 TPS, ~18.5k QPS (sysbench oltp_read_write via MaxScale, 4 threads)
**Tracking rows:** 25 rows in chaos_track.markers

---

## Test Results

| # | Experiment | Type | Result | Recovery | Data Intact |
|---|---|---|---|---|---|
| 1 | Kill Master Pod | PodChaos | PASS | Failover md-0→md-1, MaxScale re-routed, 958 TPS | 25/25 markers, checksums MATCH |
| 2 | OOMKill (memory stress) | StressChaos | PASS | Survived 1200MB, 946 TPS via MaxScale | 25/25 markers, checksums MATCH |
| 3 | Network Partition Master | NetworkChaos | PASS | No failover, Master still serving via MaxScale, 939 TPS | 25/25 markers, checksums MATCH |
| 4 | IO Latency (100ms) | IOChaos | PASS | TPS 926→5 (Master only writes), 0 errors | 25/25 markers, checksums MATCH |
| 5 | Network Latency (1s) | NetworkChaos | PASS | 941 TPS (async repl unaffected!), 0 errors | 25/25 markers, checksums MATCH |
| 6 | CPU Stress (98%) | StressChaos | PASS | 933 TPS, negligible impact | 25/25 markers, checksums MATCH |
| 7 | Packet Loss (30%) | NetworkChaos | PASS | TPS 926→1.9, severe but 0 errors | 25/25 markers, checksums MATCH |
| 8 | Full Cluster Kill | PodChaos | PASS | ~3 min recovery, bootstrap via MaxScale, 951 TPS | 25/25 markers, checksums MATCH |
| 9 | DNS Error | DNSChaos | PASS | No impact, 945 TPS via MaxScale | 25/25 markers, checksums MATCH |
| 10 | IO Fault (EIO 50%) | IOChaos | PASS | Master crashed, MaxScale lost route, recovered after | 25/25 markers, checksums MATCH |
| 11 | Clock Skew (-5 min) | TimeChaos | PASS | 865 TPS (7% drop), all running | 25/25 markers, checksums MATCH |
| 12 | Bandwidth Throttle (1mbps) | NetworkChaos | PASS | 22 TPS (97% drop), 0 errors | 25/25 markers, checksums MATCH |
| 13 | Pod Failure (freeze) | PodChaos | PASS | Failover to other node, 1104 TPS | 25/25 markers, checksums MATCH |
| 14 | Container Kill (mariadb) | PodChaos | PASS | Failover, 1163 TPS via MaxScale | 25/25 markers, checksums MATCH |
| 15 | Packet Duplicate (50%) | NetworkChaos | PASS | 926 TPS, no impact | 25/25 markers, checksums MATCH |
| 16 | Packet Corrupt (50%) | NetworkChaos | PASS | 967 TPS (repl handles it, unlike Galera!) | 25/25 markers, checksums MATCH |
| 17 | IO Attr Override (read-only) | IOChaos | PASS | 870 TPS (6% drop), 0 errors | 25/25 markers, checksums MATCH |
| 18 | IO Mistake (random corruption) | IOChaos | PASS | 964 TPS, 0 errors | 25/25 markers, checksums MATCH |

---

## Experiment Details

