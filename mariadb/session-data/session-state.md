# MariaDB Galera Chaos Testing Session State

**Updated:** 2026-04-16
**Location:** /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb

---

## Current Task

Running chaos tests on MariaDB 11.8.5 Galera Cluster (3 nodes).

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
| 2 | OOMKill | pending |
| 3 | Network Partition | pending |
| 4 | IO Latency | pending |
| 5 | Network Latency | pending |
| 6 | CPU Stress | pending |
| 7 | Packet Loss | pending |
| 8 | Full Cluster Kill | pending |
| 9 | DNS Error | pending |
| 10 | IO Fault | pending |
| 11 | Clock Skew | pending |
| 12 | Bandwidth Throttle | pending |

---
