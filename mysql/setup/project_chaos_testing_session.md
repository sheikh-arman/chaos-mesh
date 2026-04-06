---
name: Chaos Testing Session State
description: Current state of MySQL coordinator data safety fixes, chaos testing progress, and pending work for KubeDB MySQL Group Replication
type: project
---

## Current State (2026-04-06)

### Cluster Under Test
- MySQL 9.6.0, 3-node Group Replication (Single-Primary), KubeDB
- Namespace: `demo`, Cluster name: `mysql-ha-cluster`
- Coordinator image: `skaliarman/mysql-coordinator:19`
- Init script branch: `chaos-901` at `/home/arman/go/src/kubedb.dev/mysql-init-docker/scripts/run.sh`
- Coordinator code: `/home/arman/go/src/kubedb.dev/mysql-coordinator/pkg/coordinator/`
- Chaos experiments: `/home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql/`
- MySQL root password: `rI3tQLX53C3oX_Zn`

### Coordinator Fixes Completed (in mysql.go, helper.go, mode-detector.go, queries.go, constant.go)

1. **findMaxTransactedPod()** — added podReadyTimeout (2 min), abort if any pod unreachable, use `gtid_subtract` for correct superset detection, Phase 4 fallback for diverged GTIDs with scoring
2. **checkPrimaryOnline()** — checks current pod first (self-check)
3. **LabelPods()** — renamed constants to `primaryReplicaQueryDirect`/`primaryReplicaQueryCompat` (original logic was correct, names were misleading)
4. **holdsExtraTransactions()** — returns false on errors (no false positives), clone requires manual approval via `/scripts/approve-clone`
5. **freshSetup()** — marker file only written in `curNodeJoinedInCluster()` after confirmed ONLINE, not after signal send
6. **setupSynchronousCluster()** — uses `isDataDirectoryEmpty()` (join-in-cluster marker) + `gtidExecuted()` for fresh detection, works on all MySQL versions
7. **firstPodBootstrapAble()** — checks `anyPeerHasData()` and `anyPeerInGRGroup()` before allowing bootstrap
8. **fullRecovery()** — checks `anyPeerInGRGroup()` to prevent split-brain, added peer acknowledgment mechanism (`ack-from-<ordinal>` files) before bootstrap
9. **partialRecovery()** — clone blocked until `/scripts/approve-clone` created, `logExtraTransactions()` logs exact divergent GTIDs
10. **restartMySQLProcess()** — sets `super_read_only=ON` before shutdown
11. **waitForPreviousToJoin()** — nil check for `findPrimaryPod()`
12. **getDataDirectoryExistPods()** — replaced `klog.Fatalln` with error return
13. **curNodeJoinedInCluster()** — writes marker, removes signal/clone/ack files only when they exist (no log spam)
14. **anyPeerInGRGroup()** — new function, queries `replication_group_members` on peers to detect existing GR group before bootstrap
15. **Bootstrap acknowledgment** — peers write `ack-from-<ordinal>` on elected pod's volume via exec, elected pod checks locally before bootstrapping

### run.sh Fixes Completed (branch chaos-901)

1. **create_replication_user()** — all statements in single `mysql -e` session with `SQL_LOG_BIN=0` to prevent errant GTIDs
2. **install_group_replication_plugin()** — wrapped with `SQL_LOG_BIN=0` in same session
3. **install_clone_plugin()** — wrapped with `SQL_LOG_BIN=0` in same session

### Issues Found and Fixed During Testing

1. **Split-brain after OOMKill** (CRITICAL) — coordinator bootstrapped new cluster while peers already had a running GR group. Fixed with `anyPeerInGRGroup()` + acknowledgment mechanism.
2. **Errant GTIDs from run.sh** (HIGH) — `SQL_LOG_BIN=0` on separate connections had no effect. Fixed by combining all statements in single session.
3. **Dual primary labels** (HIGH) — stale `kubedb.com/role=primary` label persisted after OOMKill because `LabelPods()` only runs after successful `setupSynchronousCluster()`. Observed but fix is in coordinator flow (label cleared on setup entry).
4. **Checksum mismatch after force-kill** (MEDIUM) — observed once on MySQL 9.6.0, not reproducible consistently. Likely timing-dependent InnoDB crash recovery behavior.
5. **Fresh setup on MySQL 9.6.0** — `newVersionCondition()` was version-gated to 8.4.2+. Replaced with `isDataDirectoryEmpty()` that works on all versions.

### Chaos Tests Completed (All PASSED on coordinator :19 + fixed run.sh)

1. Pod Kill Primary under load — PASSED, all checksums match
2. OOMKill Primary under load — PASSED, no split-brain, no errant GTIDs, all checksums match
3. Full Cluster Kill — PASSED, correct election, all data preserved
4. Memory + CPU Stress + Load — PASSED, zero errors during 211k transactions
5. Network Partition — PASSED, split-brain prevented
6. IO Latency under load — PASSED, 99.9% TPS drop but zero data loss
7. Network Latency — PASSED, ~1 TPS due to Paxos consensus, zero data loss
8. CPU Stress — PASSED, ~27% TPS reduction, zero data loss
9. Packet Loss 30% — PASSED, cluster survived without failover

### Reports Generated

- `/home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql/setup/chaos-test-report-9.6.0.md` — full chaos test report for MySQL 9.6.0
- `/home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql/setup/chaos-test-report-coordinator-fixes.md` — coordinator fixes test report
- `/home/arman/go/src/kubedb.dev/mysql-coordinator/COORDINATOR-DATA-SAFETY-FIXES.md` — detailed fix report
- `/home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql/setup/data-loss-analysis.md` — initial data loss analysis

### Pending Work

1. **H3: Atomic signal file writes** — `writeSignal()` uses `echo > signal.txt` which can race with run.sh reader. Should use temp file + rename.
2. **run.sh on other branches** — fixes applied only on `chaos-901` branch. Need to port to `fix-842` (MySQL 8.4.*), `chaos` (MySQL 8.0.*) branches.
3. **run_innodb.sh fixes** — `joined_in_cluster=1` variable bug (sets function name instead of variable), `yes |` piping in `reboot_from_completeOutage`.
4. **Checksum mismatch investigation** — the once-observed checksum mismatch after force-kill on MySQL 9.6.0 needs deeper investigation. May be a MySQL bug.
5. **Update chaos test report 9.6.0** — needs updating with latest OOMKill results showing all fixes working.
6. **Test on MySQL 8.0.36 and 8.4.x** — verify all coordinator fixes work on older MySQL versions.
