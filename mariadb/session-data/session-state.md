# MariaDB Galera Chaos Testing Session State

**Updated:** 2026-04-16
**Location:** /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb

---

## Current Task

Chaos testing COMPLETE on MariaDB 11.8.5 Galera Cluster — 12/12 experiments PASS.

### Cluster Info
- **Kind:** MariaDB (KubeDB)
- **Name:** md
- **Namespace:** demo
- **Version:** 11.8.5
- **Topology:** Galera Cluster (all nodes Primary/read-write)
- **Pods:** md-0, md-1, md-2 (all 2/2 Running, Synced)
- **Secret:** md-auth
- **Sysbench pod:** sysbench-load-5b8c9dbcdc-pcjwc

### Baseline
- ~1039 TPS, ~20k QPS (oltp_read_write, 4 threads, 4 tables x 50k rows)
- 25 tracking rows in chaos_track.markers

### Labels
- `app.kubernetes.io/instance: md`
- `kubedb.com/role: Primary` (all nodes — Galera multi-master)
- Container name: `mariadb`

### Galera Status Query
```sql
SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_connected','wsrep_flow_control_paused');
```

### Environment
```bash
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')
```

---

## Tests Progress

| # | Experiment | Status |
|---|---|---|
| 1 | Pod Kill | PASS - ~5s recovery, 1061 TPS, 25/25 markers, checksums MATCH |
| 2 | OOMKill | PASS - survived 1200MB stress, 1050 TPS, checksums MATCH |
| 3 | Network Partition | PASS - isolated node non-Primary, 1430 TPS (2 nodes), auto-rejoin, checksums MATCH |
| 4 | IO Latency | PASS - node unresponsive during, 1450 TPS (2 nodes), auto-rejoin, checksums MATCH |
| 5 | Network Latency | PASS - TPS 1039→3, 0 errors, all Synced, checksums MATCH |
| 6 | CPU Stress | PASS - 1034 TPS, no impact, all Synced, checksums MATCH |
| 7 | Packet Loss | PASS - TPS 1039→1.3, all Synced, 0 errors, checksums MATCH |
| 8 | Full Cluster Kill | PASS - ~3 min recovery, Galera bootstrap, 1024 TPS, checksums MATCH |
| 9 | DNS Error | PASS - 1016 TPS, no impact, all Synced, checksums MATCH |
| 10 | IO Fault | PASS - node crashed, 1404 TPS (2 nodes), auto-rejoin, checksums MATCH |
| 11 | Clock Skew | PASS - 988 TPS, minor drop, all Synced, checksums MATCH |
| 12 | Bandwidth Throttle | PASS - 280 TPS, 73% drop, all Synced, 0 errors, checksums MATCH |

---
