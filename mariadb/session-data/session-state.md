# MariaDB Chaos Testing Session State

**Updated:** 2026-04-20
**Location:** /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb

---

## Current Task

Chaos testing COMPLETE on MariaDB 11.8.5 **MariaDBReplication** topology with MaxScale — 18/18 PASS.

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
| 8 | Full Cluster Kill | PASS - ~3 min recovery, 951 TPS via MaxScale, checksums MATCH |
| 9 | DNS Error | PASS - 945 TPS, no impact, checksums MATCH |
| 10 | IO Fault | PASS - Master crashed, recovered, checksums MATCH |
| 11 | Clock Skew | PASS - 865 TPS (7% drop), checksums MATCH |
| 12 | Bandwidth Throttle | PASS - 22 TPS (97% drop), 0 errors, checksums MATCH |
| 13 | Pod Failure | PASS - failover, 1104 TPS, checksums MATCH |
| 14 | Container Kill | PASS - failover, 1163 TPS via MaxScale, checksums MATCH |
| 15 | Packet Duplicate | PASS - 926 TPS, no impact, checksums MATCH |
| 16 | Packet Corrupt | PASS - 967 TPS (repl handles it unlike Galera!), checksums MATCH |
| 17 | IO Attr Override | PASS - 870 TPS, 0 errors, checksums MATCH |
| 18 | IO Mistake | PASS - 964 TPS, 0 errors, checksums MATCH |

---

## 2026-04-20: Architecture Review — Issue Hunt Starting

### Files reviewed
- Coordinator: `/home/arman/go/src/kubedb.dev/mariadb-coordinator/pkg/coordinator/mariadb.go`
- Init: `/home/arman/go/src/kubedb.dev/mariadb-init-docker/scripts/run.sh` (+ `on-start.sh`, `std-replication-*.sh`, `bootstrap-new-cluster.sh`, etc.)

### Recovery flow (Galera)
`RunMariaDBCoordinator()` main loop (line 862):
1. `makeNodeReadyForClusterSetup`
2. If data dir empty:
   - Pod-0 only: try `checkOnePrimaryComponentOnline` 5× with 1s sleep, then bootstrap if none found (line 890-902)
   - Others: `runJoinGaleraClusterScript`
3. If data dir present:
   - Primary online → single-node recovery
   - No primary → `galeraClusterPrimaryRecovery` (line 702): compare seqnos across all nodes, bootstrap from max
4. Ping mysqld 10× (10s each); on all fail → `c.initialize()` restarts coordinator

### POTENTIAL BUGS IDENTIFIED

**Bug #1 (candidate) — lexicographic seqno comparison in full-cluster recovery**
File: `mariadb.go:725`
```go
if strings.Compare(output, maxSeqNo) == 1 {
    maxSeqNo = output
    maxSeqPodName = podName
}
```
`strings.Compare` is lexicographic. Example: seqno "100" vs "99" → "100" < "99" (because '1' < '9') → picks node with seqno 99 as winner → bootstrap from stale node → **loses committed transactions from the node with seqno 100**.
Test idea: drive writes until seqno crosses 10→100, kill all 3 pods simultaneously, verify which pod bootstraps vs which had highest real seqno. Check for data loss.

**Bug #2 (potential) — bootstrap race, pod-0-only fresh-cluster path**
File: `mariadb.go:890-902`
If pod-0 starts with empty data dir, it waits only 5s (5 × 1s) for `checkOnePrimaryComponentOnline` before bootstrapping. If the rest of the cluster is alive but slow to respond (DNS lag, SSL handshake, packet loss), pod-0 creates a new cluster → split-brain.
Test idea: delete PVC of pod-0 while pod-1 + pod-2 are healthy + under network packet-loss chaos, watch if pod-0 joins existing cluster or creates new one.

**Bug #3 (potential) — coordinator self-restart during SST**
File: `mariadb.go:977-980`
If `engine.Ping()` fails 10× in a row (100s), coordinator calls `c.initialize()` to restart itself. During mariabackup SST, the joiner's mysqld is unavailable for writes for minutes — ping likely fails. Coordinator restart mid-SST could abort the transfer or race with SST completion.
Test idea: trigger SST (large dataset, rsync/mariabackup), monitor coordinator restart counter during transfer.

### Fix applied for Bug #1 (seqno compare)
**File:** `kubedb.dev/mariadb-coordinator/pkg/coordinator/mariadb.go:702-762` (`galeraClusterPrimaryRecovery`)
- Changed `maxSeqNo` from `string` "0" to `int64 = -1` (baseline below any valid seqno)
- Parse each node's seqno with `strconv.ParseInt` before comparing
- On parse failure: log + skip (don't bootstrap from node with untrustable seqno)
- Numeric compare `curSeqNo > maxSeqNo` replaces `strings.Compare(output, maxSeqNo) == 1`
- If no node has valid seqno → refuse to bootstrap (return error), wait for intervention
- Build + `go vet` clean

**Same bug also exists in:** `kubedb.dev/percona-xtradb-coordinator/pkg/coordinator/percona-xtradb.go:462` — needs identical fix (Percona XtraDB Cluster is also Galera-based).

### Next steps
- [ ] Rebuild `mariadb-coordinator` image with fix and deploy
- [ ] Chaos test for Bug #1: drive writes past seqno=100, kill all 3 pods, verify correct bootstrap pod
- [ ] Fix same bug in `percona-xtradb-coordinator`
- [ ] Investigate Bug #2 (bootstrap race) and Bug #3 (coordinator restart mid-SST)

---
