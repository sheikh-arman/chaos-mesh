# MariaDB Chaos Testing Session State

**Updated:** 2026-04-17
**Location:** /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb

---

## Current Task

Running chaos tests on MariaDB 11.8.5 **MariaDBReplication** topology with MaxScale proxy.

### Cluster Info
- **Kind:** MariaDB (KubeDB)
- **Name:** md
- **Namespace:** demo
- **Version:** 11.8.5
- **Topology:** MariaDBReplication (1 Master + 2 Slaves) + MaxScale (3 replicas)
- **Pods:** md-0 (Master), md-1 (Slave), md-2 (Slave), md-mx-0/1/2 (MaxScale)
- **Secret:** md-auth
- **Load via:** `md-mx` service (MaxScale proxy, port 3306)
- **Sysbench pod:** sysbench-load-5b8c9dbcdc-pcjwc

### Baseline (via MaxScale)
- ~926 TPS, ~18.5k QPS (oltp_read_write, 4 threads, 4 tables x 50k rows)
- 25 tracking rows in chaos_track.markers

### Labels
- `app.kubernetes.io/instance: md`
- `kubedb.com/role: Master` (md-0) / `kubedb.com/role: Slave` (md-1, md-2)
- Container name: `mariadb`

### Environment
```bash
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')
```

---

## Previous Completed Tests

### Galera Cluster (MariaDB 11.8.5) — 18/18 PASS
All 18 chaos experiments passed with zero data loss.

---

## Replication Tests Progress

| # | Experiment | Status |
|---|---|---|
| 1 | Kill Master Pod | PASS - failover md-0→md-1, MaxScale re-routed, 958 TPS, checksums MATCH |
| 2 | OOMKill | PASS - survived 1200MB, 946 TPS via MaxScale, checksums MATCH |
| 3 | Network Partition | PASS - no failover, 939 TPS via MaxScale, checksums MATCH |
| 4 | IO Latency | PASS - 5 TPS (Master IO bottleneck), 0 errors, checksums MATCH |
| 5 | Network Latency | PASS - 941 TPS (async repl unaffected!), checksums MATCH |
| 6 | CPU Stress | PASS - 933 TPS, negligible, checksums MATCH |
| 7 | Packet Loss | PASS - 1.9 TPS, severe but 0 errors, checksums MATCH |
| 8 | Full Cluster Kill | pending |
| 9 | DNS Error | pending |
| 10 | IO Fault | pending |
| 11 | Clock Skew | pending |
| 12 | Bandwidth Throttle | pending |
| 13 | Pod Failure | pending |
| 14 | Container Kill | pending |
| 15 | Packet Duplicate | pending |
| 16 | Packet Corrupt | pending |
| 17 | IO Attr Override | pending |
| 18 | IO Mistake | pending |

---
