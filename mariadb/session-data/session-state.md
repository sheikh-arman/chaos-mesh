# MariaDB Chaos Testing Session State

**Updated:** 2026-04-21

## 2026-04-21: Added SoftBank-style Expected/Actual verification blocks to MariaDB blog post
Added `**Expected behavior:**` / `**Actual result:**` bullet blocks to every chaos experiment in `appscode/blog/content/post/chaos-testing-mariadb/index.md` — 18 Galera experiments (Chaos#1-Chaos#18). Replication section only has summary table (no detail sections), so no blocks added there. Format matches the SoftBank translated Chaos Testing doc and mirrors what was applied to the MySQL blog.

## 2026-04-22: MariaDB 11.8.5 defect hunt — 2 defects found so far
**Report:** `mariadb/report/kubedb-mariadb-defect-hunt-2026-04-21.md`

**Defect #1 (High):** IOChaos `fault` (EIO 50%) on any MariaDB pod (master or slave) leaves the pod permanently stuck after chaos clears. mariadbd process dies, init script (`run-on-present.sh`) is stuck in a 900-attempt ping loop, no auto-restart of mariadbd. MariaDB CR → `Critical`, pod role → `Down`. Recovery requires manual pod delete or ~15-min timeout.

**Defect #2 (Critical):** IOChaos `mistake` (random byte corruption 50%) on master corrupts the active binary log file (`mariadb-bin.000006`). Both slaves break with `Slave_IO_Running: No, Last_IO_Error: Got fatal error 1236 ... log event entry exceeded max_allowed_packet`. `mariadb-binlog` output confirms garbage event_type=232 at the corrupted offset. Checksums permanently diverge between master and slaves. Pod delete alone does NOT fix — slaves replay from the same broken binlog position. MariaDB CR shows `Ready` while replication is silently broken; only role label changes to `Unknown`. No auto-repair mechanism in KubeDB.

Tests 1–11 all PASS (pod kill master/slave/maxscale, container kill, pod freeze, memory/cpu stress, IO latency) with no defects — documented in report.
Tests 14 passed cleanly too (r/o filesystem).
**Test 15 (IO mistake) escalation:** after rebuilding slaves to keep hunting bugs, md-0's mariadbd refuses to start with `InnoDB: Failed to read page 3 from file './/undo003': Page read from tablespace is corrupted.` — IOChaos `mistake` also corrupted InnoDB undo tablespace, not just binlog. Cluster becomes fully unrecoverable without external backup. Coordinator loops: "mysqld process is not running, restarting the coordinator" → tries to bootstrap → hits corrupt undo003 → fails → repeat.
**MariaDB's own fix hint:** `innodb_force_recovery=5` (skip undo logs) for read-only dump extraction, then reload into fresh datadir. But this is MANUAL — no auto-path in KubeDB. For our purposes (test cluster), cleanest recovery is `kubectl delete mariadb md + recreate`.

## 2026-04-22: Applied preliminary fixes for Defects #1 and #2
**Fix #1 — init script (`mariadb-init-docker/scripts/std-replication-setup.sh`):** rewrote `wait_for_mysqld_running()` to bail out on `kill -0 $pid` failure instead of waiting 900s. Reduced timeout 900→120. Updated outer `while true` main loop to exit on wait failure (kubelet will restart container). Added pid-alive check inside `signal.txt` wait loop.
**Fix #2 — coordinator (`mariadb-coordinator/pkg/coordinator/mariadb.go`):** added `recoverBrokenSlaveIOIfNeeded()` that runs in the main reconcile loop on slaves. Detects `Slave_IO_Running=No` with binlog-read errors (errno 1236, max_allowed_packet, "log event entry", "could not queue event", "Found invalid event"), reads master's current binlog pos via `SHOW MASTER STATUS`, then runs `STOP SLAVE; RESET SLAVE ALL; CHANGE MASTER TO ..., MASTER_LOG_FILE=X, MASTER_LOG_POS=Y; START SLAVE` to re-point the slave to master's current head (accepts replication gap). Build + vet clean. **Not yet rebuilt/deployed.**
**Fix #3 deferred:** default livenessProbe in petset builder — user interrupted before applying.

## 2026-04-22: Defect #3 — mariadb-backup fails silently when master has innodb_force_recovery>0
While md-0 was recovering from the earlier undo003 corruption using `innodb_force_recovery=5`, the user scaled/rebuilt a slave. md-1 joiner kept failing backup-stream with `"datadir lacks mariabackup artifacts"` — root cause on master side: `mariabackup: The option "innodb_force_recovery" should only be used with "--prepare". innodb_init_param(): Error occurred.` KubeDB's master-side coordinator (`ensureBackupStream`) doesn't check master's force_recovery status before running backup-stream.sh → silent backup failure → joiner loop forever through 3-retry + restart cycle. Report updated with Defect #3 + suggested fix (check `@@innodb_force_recovery` on master before running backup-stream, emit Event if >0).

**Cosmetic bug also observed:** `./run-script/run-on-present.sh: line 300: [: : integer expression expected` — our PIPESTATUS check gets empty value(s) in this particular failure mode. Doesn't change outcome (post-check correctly catches empty datadir) but should be defensive-coded: `[ -n "$socat_rc" ] && [ "$socat_rc" -ne 0 ]` or default to non-zero when empty.
Remaining tests (network chaos, DNS, clock skew, full cluster kill, rolling restart) require a rebuilt cluster (MariaDB CR delete + recreate).

## 2026-04-21: MariaDB client warning `--ssl-verify-server-cert is disabled, because of an insecure passwordless login`
**What it is:** New MariaDB client warning (10.11+/11.x) that triggers when `ssl-verify-server-cert=ON` is combined with a passwordless connection (e.g., `mysql -uroot` over socket). Client silently downgrades to skip cert verify and emits the warning.
**Why it wasn't there before:** 10.5.x client was silent in the same scenario. Seen now because MariaDB 11.8.5 ships with `ssl-verify-server-cert=ON` by default under `[client]` in many builds.
**Impact:** Cosmetic only — the connection was never cert-verified anyway. No actual downgrade.
**Silence it:** add password (`-p$PASS`), or pass `--skip-ssl-verify-server-cert`, or set `ssl-verify-server-cert=OFF` in `[client]`.

## 2026-04-21: Translated SoftBank chaos-testing docs
Translated all 5 Japanese docs (originals were in `mariadb/chaos-testing-softbank/` then briefly `mariadb/chaos-testing-scripts/`). **Current location for the English translations:** `/home/arman/go/src/github.com/sheikh-arman/my-library/chaos/chaos-testing-scripts/` — `_en`/`_EN` siblings (plus one duplicate `Chaos Test Procedure_20250806_en.md` that pairs with the renamed original):
- Chaos Testing — PostgreSQL on AWS EKS with KubeDB, 17 fault types (Pod/Process/Network/IO/Clock/DNS), 200 clusters. Findings: several fault types leave clusters stuck in `NotReady`/`Critical` even after fault cleared.
- DBaaS Scalability and Stress Testing — multi-tenant scalability, AWS EKS + Azure AKS, 500/1000/1500/2000 cluster scale, batch Ops (Restart/VScale/HScale/VolumeExpansion/Upgrade/Reconfigure). 15 distinct software defects identified.
- HScale and DR Testing Under Real-world Write Load and Capacity — `pg_basebackup` fails with WAL-removed error on scale-out and DR under sustained writes.
- KubeDB Test on Laptop — k3d + Docker Desktop setup + Ops-loop test finds KubeDB defects (Restart/VerticalScale/Upgrade/Reconfigure lead to stuck `Progressing`, `Critical`, `NotReady`).
- Write Load Test — sustained PostgreSQL write load causes cluster `Critical`, no online recovery path.
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

### Fix applied: Backup-stream security + data loss (critical)
**Files:** `mariadb-coordinator/pkg/coordinator/mariadb.go`, `mariadb-init-docker/scripts/std-replication-setup.sh`, `mariadb-init-docker/scripts/backup-stream.sh`
**Issue:** Joiner's `socat -u TCP-LISTEN:3307` was unauthenticated, unencrypted, listened on 0.0.0.0 → any pod in the cluster could race the master to feed crafted mariabackup data into `/var/lib/mysql`. On failure the script ran `rm -rf /var/lib/mysql` and retried forever — a trivial data-loss + persistent-poisoning vector.
**Fix:**
- Coordinator writes master pod IP to `/scripts/master_ip.txt` atomically before the joiner listens; aborts if unavailable.
- Joiner waits 60s for master IP, then listens with `bind=$POD_IP,range=$MASTER_IP/32` (kernel-level allowlist). TLS via `OPENSSL-LISTEN` with `verify=1` when `REQUIRE_SSL=TRUE`.
- `rm -rf` replaced with quarantine to `/var/lib/mysql.failed.<ts>.<attempt>`.
- Bounded retries (3 attempts, then hard-exit for operator visibility).
- Master's `backup-stream.sh` uses `OPENSSL:` when SSL enabled for mutual TLS.
**Writeup:** `mariadb/report/backup-stream-security-fix.md`
**Follow-up fixes (2026-04-20) after first test:**
(a) socat `range=X/32` CIDR form rejected when TCP-LISTEN address family is PF_UNSPEC → switched to `range=X:255.255.255.255` netmask form — which then failed because socat's option lexer truncates at `:` ("syntax error in 10.244.0.10"). **Final correct fix:** auto-detect address family from MASTER_IP (IPv6 addresses contain `:`). Pick `TCP4-LISTEN`/`pf=ip4`/`X/32` for IPv4 or `TCP6-LISTEN`/`pf=ip6`/`[X]/128` for IPv6. Master side mirrors with `TCP4:ip:3306` or `TCP6:[ip]:3306`. Works on IPv4-only, IPv6-only, and dual-stack Kubernetes clusters.
(b) `$?` after pipeline reports only last command's exit → socat syntax error silently passed as "Data restore successful" because mbstream saw EOF and exited 0 → now check `PIPESTATUS[0]` (socat) + `PIPESTATUS[1]` (mbstream), and verify `xtrabackup_checkpoints`/`ibdata1` exists before declaring success. Same PIPESTATUS check added to master's `backup-stream.sh`.

### Fix applied: Bootstrap data-loss guard (critical)
**File:** `mariadb-coordinator/pkg/coordinator/mariadb.go` — fresh-join bootstrap path
**Issue:** If pod-0's PVC was empty but pod-1/pod-2 had historical data AND were offline, the coordinator would bootstrap a FRESH empty cluster from pod-0 after only 5 s of peer-detection. When pod-1/pod-2 later rejoined, they'd SST from empty pod-0 and WIPE their own data → full cluster data loss.
**Fix:**
- New helper `isPodDataDirEmpty(ctx, podName)` — pure datadir check, no seqno dependency.
- New helper `allPeersHaveEmptyDataDir(ctx)` — exec into every peer and verify empty; returns error if any peer is unreachable (unknown state → refuse to bootstrap).
- Safety gate placed BEFORE the ordinal-0 bootstrap branch: if any peer has data or is unreachable, refuse to bootstrap, wait for peer to bring cluster online for SST.
- Extended the 5 s wait to 60 s before even considering bootstrap.

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
