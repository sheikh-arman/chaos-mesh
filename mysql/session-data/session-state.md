# Chaos Testing Session State

**Updated:** 2026-04-27

## 2026-04-27: Coordinator auto-resolve for view-change errant GTIDs
After pod-failure chaos on pod-0 (primary at the time), pod-0 came back with errant `cbc40000-0000-00d2-b31a-448a5848010d:7` — a GR view-change event committed locally during expulsion. Coordinator (mysql.go:895) detected and refused to clone (good — clone would silently lose data in the general case). Found that the "mystery UUID" is mathematically derivable from group_name by zeroing bytes 2..6 of the 16-byte UUID — that is MySQL's AUTOMATIC view_change_uuid algorithm.

**GTID block jump explained (pod-1/pod-2 had `cbc41be7-…:1-20028:1000001-1000100`):** GR's `group_replication_gtid_assignment_block_size = 1000000`. When the primary changes, the new primary skips to the next 1M block instead of continuing 20029, 20030… Gap `20029–1000000` is normal GR allocation — not lost data.

Added a safe auto-resolve path in the coordinator:
- New file `pkg/coordinator/errant_gtid.go` with `parseGTIDSet`, `deriveAutoViewChangeUUID`, `reconcileViewChangeErrants`, `injectEmptyTransaction` (uses `engine.DB().Conn(ctx)` to pin a connection so SET GTID_NEXT survives across BEGIN/COMMIT)
- New constant `selectGroupName` in `queries.go`
- `partialRecovery()` in `mysql.go` (both InnoDB and GR branches) calls `reconcileViewChangeErrants()` BEFORE the clone-approval gate. If every errant GTID's UUID matches the auto-derived view_change_uuid for the cluster's group_name, coordinator injects empty txns on primary (zero data risk), then takes the normal rejoin path. Any foreign UUID in the errant set falls through to existing clone-approval flow — no regression.

**Decision: do NOT add bash equivalent in run.sh.** Earlier I sketched a `reconcile_view_change_errants` bash function for run.sh — DROPPED. Coordinator is the single gatekeeper (writes signal.txt). Bash version would create a second source of truth, race the coordinator, lose Go's structured parsing/error handling, and clutter logs. run.sh needs zero changes for this fix — its existing `super_read_only=ON` (line 214), conditional `RESET BINARY LOGS AND GTIDS` (line 436, only on first join), and `START GROUP_REPLICATION` retry loop (line 497) all stay correct under the coordinator-driven flow.

**Manual unblock for currently stuck cluster (no clone, no data loss):** on a live primary, run `SET @@SESSION.GTID_NEXT='cbc40000-0000-00d2-b31a-448a5848010d:7'; BEGIN; COMMIT; SET @@SESSION.GTID_NEXT='AUTOMATIC';` — propagates via GR, then `kubectl delete pod mysql-ha-cluster-0 -n demo` retriggers coordinator → no errant → incremental rejoin (donor must still hold `cbc41be7-…:1000001-1000100` in binlog; verify `gtid_purged` first).

**Optional hardening (deferred):** set `loose-group_replication_view_change_uuid = "<deterministic-value>"` explicitly in `group.cnf` so coordinator's derivation can't drift if MySQL changes the AUTOMATIC algorithm in a future release. Not required for the current fix.

Verified: package compiles, vet clean. Pure-function test confirmed UUID derivation produces exactly the observed mystery UUID for the live cluster's group_name. Image rebuild still pending — fix is on disk only.

## 2026-04-27: Ported SoftBank PostgreSQL chaos YAMLs to MySQL
Created `mysql/setup/soft/` with MySQL-adapted versions of all 16 chaos scenarios from `my-library/chaos/chaos-testing-scripts/Chaos Test Procedure_20250806_en.md`. Same parameters as the postgres doc — only `app.kubernetes.io/name: postgreses.kubedb.com` swapped to `mysqls.kubedb.com`, `volumePath /var/pv` swapped to `/var/lib/mysql`, namespace set to `demo`. Files: 01 pod-failure, 02 pod-kill, 03 oom (StressChaos, primary pod-name placeholder), 04 network-partition (target=secondary), 05 bandwidth, 06 delay 2s, 07 loss 100%, 08 duplicate 100%, 09 corrupt 100%, 10 clock-skew -10m, 11 dns-error, 12 io-latency 2s on /var/lib/mysql, 13 io-fault errno=5, 14 io-attroverride perm=72, 15 io-mistake READ/WRITE, 16 kill-mysqld (bash exec script — no CRD).
Switched from `generateName:` to fixed `name:` on all 15 CRDs so `kubectl apply -f` works (apply rejects generateName — `cannot use generate name with apply`). For repeat runs, delete the prior chaos resource before reapplying.

## 2026-04-21: Added SoftBank-style Expected/Actual verification blocks to MySQL blog post
Added `**Expected behavior:**` / `**Actual result:**` bullet blocks to every chaos experiment in `appscode/blog/content/post/chaos-testing-mysql/index.md` — 33 total (21 Group Replication + 12 InnoDB Cluster). Blocks are placed after each experiment's "What this chaos does:" intro, following the format from the translated SoftBank Chaos Testing doc. Gives readers at-a-glance summary before the detailed command walkthrough.

**Location:** /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql

---

## Current Task

Fixed `run_innodb.sh` for MySQL 8.4.8 InnoDB Cluster compatibility.
Blog post: experiments 1-13 written with full outputs. Remaining 14-21 outputs already captured from earlier runs.

### 2026-04-13: Router Service Testing & Primary Kill

**Router Service:** `mysql-ha-cluster-router` — ClusterIP exposing 6446 (RW), 6447 (RO)

**Router Connectivity Verified:**
- Port 6446 → routes to PRIMARY
- Port 6447 → routes to SECONDARY

**Sysbench via Router (pre-kill):** ~1000 TPS, 0 errors (4 tables × 50k rows)

**Primary Kill Test (pod-0 deleted during load):**
- Sysbench saw TPS drop: 1031 → 799 → 326 → Lost connection (error 2013)
- GR failover: pod-2 elected as new PRIMARY, pod-1 stayed SECONDARY
- Router automatically re-routed RW traffic to pod-2
- Post-failover sysbench: 927 TPS, 0 errors — fully functional
- Pod-0 auto-rejoined as SECONDARY (coordinator handled recovery)

**Cluster recovery from complete outage (earlier):**
- First sysbench prepare (12 tables × 500k rows) was too large → GR error 3100 (replication hook)
- All members went ERROR/UNREACHABLE; coordinator detected outage & rebooted cluster
- Manual bootstrap needed for pod-0; coordinator then rejoined pod-1 & pod-2 (10-attempt restart cycle)
- Reduced to 4 tables × 50k rows for subsequent tests

**Current cluster state:** All 3 ONLINE, pod-2 = PRIMARY, pod-0 & pod-1 = SECONDARY

**Router Config Analysis:**
- Router pod listens on all 5 ports (6446, 6447, 6448, 6449, 6450)
- `mysqlrouter.conf` at `/tmp/mysqlrouter/mysqlrouter.conf` — auto-generated by `mysqlrouter --bootstrap --force` on every pod start
- MySQL Router 8.4+ bootstrap automatically includes `[routing:bootstrap_rw_split]` on port 6450 with `connection_sharing=1`, `access_mode=auto`
- Config is ephemeral (`/tmp/`) but regenerated every restart — so rw-split is always present
- `custom.conf` at `/etc/mysqlrouter/custom.conf` (from Secret `mysql-ha-cluster-router-config`) is persistent but currently empty
- K8s Service only exposes 6446 (rw) and 6447 (ro) — **missing 6450 (rw-split), 6448 (x-rw), 6449 (x-ro)**
- **Only change needed:** update `ensureRouterService()` in operator to add port 6450 to the Service
- No script changes needed — bootstrap handles config generation

**mysql-router-init repo:** `/home/arman/go/src/kubedb.dev/mysql-router-init/` (image: `ghcr.io/kubedb/mysql-router-init:v0.41.0`)
- initContainer copies Go binary + `router_run.sh` to shared `/scripts` volume
- mainContainer runs `/scripts/mysql-router-init` → calls `router_run.sh` in loop → `/run.sh mysqlrouter --extra-config=/etc/mysqlrouter/custom.conf`
- Oracle's `/run.sh` runs `mysqlrouter --bootstrap --force` → auto-generates config with all 5 ports (including 6450 rw-split in MySQL 8.4+)
- No changes needed in mysql-router-init repo or scripts — only operator `ensureRouterService()` needs port 6450 added

**Changes applied for port 6450 (rw-split):**
1. `apimachinery/apis/kubedb/constants.go` — added `MySQLRouterReadWriteSplitPortName="rwsplit"` and `MySQLRouterReadWriteSplitPort=6450` ✅
2. `mysql/pkg/controller/service.go` — added 6450 port to `ensureRouterService()` ✅
3. `mysql/pkg/controller/router.go` — added 6450 container port to router StatefulSet ✅
4. `mysql/vendor/kubedb.dev/apimachinery/apis/kubedb/constants.go` — vendored copy updated ✅

**Note:** `petset.go` does NOT need changes — it defines MySQL DB pods (port 3306). Router StatefulSet is in `router.go` (already updated).
**Note:** No config changes needed to enable rw-split — MySQL Router 8.4+ bootstrap auto-generates `[routing:bootstrap_rw_split]` on port 6450 with `access_mode=auto` (writes→PRIMARY, reads→round-robin across all members).

**Port 6450 tested and working:**
- Service updated: `6446/TCP,6447/TCP,6450/TCP` ✅
- Round-robin confirmed across members ✅
- Sysbench `oltp_read_write` via 6450: 555 TPS, 11k QPS, 0 errors ✅
- **Note:** Port 6450 requires `--mysql-ssl=REQUIRED` (caching_sha2_password + connection_sharing needs secure connection)
- Ports 6446/6447 do NOT require SSL flag

**InnoDB Cluster Chaos Testing — COMPLETE (2026-04-13):**
- 12 experiments, ALL PASS
- Report: `report/innodb-cluster/chaos-test-report-8.4.8.md`
- All tests run through MySQL Router (port 6446 RW)
- 25/25 tracking rows preserved, GTIDs MATCH on all, checksums MATCH on all
- Key findings vs GR: OOMKill triggered at 1200MB (GR survived), Packet loss 30% no failover (GR did failover)
- Blog updated: `appscode/blog/content/post/chaos-testing-mysql/index.md` — added full InnoDB Cluster section (setup, 12 experiments, Router observations, comparison tables)
- Blog title updated: 57 → 69 experiments, added InnoDB Cluster + MySQL Router tags
- Fixed blog: Router exposes 3 ports (6446, 6447, 6450) via K8s Service, not 5
- Removed "InnoDB Cluster on MySQL 9.6.0" from What's Next section

### 2026-04-13: InnoDB Cluster on MySQL 9.6.0 — server_id Bug
**Issue:** `run_innodb.sh` didn't set `server_id` in my.cnf (unlike `run.sh` for GR mode). It relied on `dba.configureInstance()` to set it, but the `gtid_mode=ON` check skipped `configureInstance()` on MySQL 9.6.0 (which ships with `gtid_mode=ON` by default) → `server_id` stayed at default `1` → `dba.createCluster()` failed with "server_id must be unique"
**Fix (two changes):**
1. Added explicit `server_id = ${svr_id}` to my.cnf (same logic as `run.sh`: hostname ordinal + 1)
2. Replaced `gtid_mode=ON` check with `dba.checkInstanceConfiguration()` — asks mysqlsh directly if instance needs configuration. Works on all MySQL versions (8.4, 9.6+).
**File:** `run_innodb.sh` — `configure_instance()` function

### 2026-04-13: InnoDB Cluster on MySQL 9.6.0 — rescan() options removed
**Issue:** `cluster.rescan({addInstances:[...], interactive:false})` fails on MySQL Shell 9.6.0 — these options were removed
**Error:** `Invalid options: addInstances, interactive (ArgumentError)`
**Fix:** Changed to `cluster.rescan()` (no options) in `is_already_in_cluster()` and `make_sure_instance_join_in_cluster()`
**File:** `run_innodb.sh` — two locations

### 2026-04-13: InnoDB Cluster on MySQL 9.6.0 — errant GTIDs from entrypoint
**Issue:** MySQL 9.6.0 has `gtid_mode=ON` by default → Docker entrypoint DDL (CREATE USER root, timezone load) generates GTIDs before our script runs → `cluster.addInstance()` with `recoveryMethod:'incremental'` fails because secondaries have errant GTIDs not in the cluster
**Error:** `Cannot use recoveryMethod=incremental ... errant GTIDs: cf8fb055-...:1-5`
**Fix:** Added `RESET BINARY LOGS AND GTIDS` after user creation on first boot in `create_replication_user()`
**File:** `run_innodb.sh`

### MySQL 9.6.0 InnoDB Cluster — All 5 fixes summary
1. `server_id` not set in my.cnf → added `server_id=${svr_id}`
2. `gtid_mode=ON` check skipped `configureInstance()` → use `dba.checkInstanceConfiguration()` instead
3. Errant GTIDs from entrypoint → `RESET BINARY LOGS AND GTIDS` on first boot
4. `cluster.rescan()` options removed in 9.6 → use without options
5. Missing `TRANSACTION_GTID_TAG` privilege (new in 9.6) → grant separately with `2>/dev/null` fallback for 8.4.x (also added to `else` branch for existing users)

**Additional fix:** TRANSACTION_GTID_TAG grant was failing silently because `super_read_only=ON` was already set before the grant, and `2>/dev/null` hid the error. Fixed to explicitly disable `super_read_only` before granting in both `if` and `else` branches.

**Status:** All fixes confirmed working — pod-1 and pod-2 joined successfully on MySQL 9.6.0. Redeploying with rebuilt image.

### 2026-04-13: Multi-Primary support added to run_innodb.sh
**Changes:**
1. Added `loose-group_replication_single_primary_mode=OFF` and `loose-group_replication_enforce_update_everywhere_checks=ON` to my.cnf when `PRIMARY_TYPE == "Multi-Primary"` (matching run.sh)
2. `create_cluster()` passes `multiPrimary:true,force:true` to `dba.createCluster()` for multi-primary mode
3. No changes needed for join/rejoin/reboot — they work the same regardless of topology mode

**Operator changes for InnoDB Multi-Primary:**
- `env.go` — pass `PRIMARY_TYPE` env var from `db.Spec.Topology.InnoDBCluster.Mode`
- `service.go` — only create standby service for Single-Primary InnoDB Cluster (skip for Multi-Primary)
- User YAML: `topology.innoDBCluster.mode: Multi-Primary`
- `run_innodb.sh` on `innodb-support` branch — same multi-primary changes applied

### 2026-04-13: server_uuid mismatch in InnoDB Cluster metadata
**Issue:** After pod restart, `server_uuid` can change (MySQL generates new UUID on fresh init). InnoDB Cluster metadata has stale UUIDs → `dba.getCluster()` fails with "unmanaged replication group" or "Metadata for instance not found" → rejoin fails for all pods.
**Manual fix:** `UPDATE mysql_innodb_cluster_metadata.instances SET mysql_server_uuid='<new_uuid>' WHERE address='<pod_address>'`
**Fixed:** Added `fix_metadata_uuids()` function in `run_innodb.sh` — data-safe approach:
1. Finds a "good" peer whose UUID matches metadata (valid data)
2. Connects via that peer (`dba.getCluster()` works)
3. Removes stale instance from cluster (`removeInstance({force:true})`)
4. Re-adds with `recoveryMethod:'clone'` — full data copy from healthy node, zero data loss
Called in `rejoin_in_cluster()`, `is_already_in_cluster()`, and `reboot_from_completeOutage()`.
**Note:** These 9.6.0 fixes are NOT needed on `innodb-support` branch (8.4.x) — only multi-primary support was added there.

### 2026-04-20: cluster.rescan() fails with MYSQLSH 51500 during AuthSecret rotation
**Issue:** `cluster = dba.getCluster(); cluster.rescan()` fails after auth secret rotate ops request with "Failed to acquire Cluster lock through primary member" (MYSQLSH 51500) across all 10 retries.
**Root cause:** `cluster.rescan()` acquires an exclusive cluster-wide lock on PRIMARY. During rotation, multiple pods restart and run `run_innodb.sh`, each calling rescan at lines 217, 261, 306 — they race for the same lock. Stale mysqlsh sessions from pre-rotation (authenticated with old password) may also still hold the lock. The operator itself may also trigger a rescan during rotation, racing with pod scripts.
**Mitigation:** Wait for ops request to finish, then manually run rescan. Check stuck sessions via `performance_schema.metadata_locks WHERE lock_type='EXCLUSIVE'` + `SHOW PROCESSLIST` on primary; KILL stale mysqlsh connections if needed.
**Longer-term fix idea:** Serialize rescan in `run_innodb.sh` (only joining pod rescans) or pre-check with `SELECT IS_FREE_LOCK(...)` before calling rescan.
**Resolution (2026-04-20):** Confirmed root cause on live cluster. Lock owner query (`JOIN performance_schema.threads ON metadata_locks.OWNER_THREAD_ID`) showed stuck `repl@10.244.0.28` (my-innodb-1) Sleep session holding `AdminAPI_cluster.AdminAPI_lock`. `KILL <processlist_id>` on PRIMARY (my-innodb-2) released it. Cluster recovered: my-innodb-2 PRIMARY + my-innodb-1 SECONDARY ONLINE, my-innodb-0 able to rejoin.
**Also note:** A manually-started `mysqlsh cluster.rescan()` can itself hang and hold the lock (our own session became Sleep 184s holding the lock). If running rescan manually, monitor and kill if it stalls.
**Auto-fix applied (2026-04-20):** Added `clear_stale_cluster_lock()` helper to `run_innodb.sh`, preflight on all 8 AdminAPI call-sites (rescan x3, addInstance x2, removeInstance x2, rejoinInstance x1), Sleep>5s threshold. Full debug writeup: `report/innodb-cluster/auth-rotate-cluster-lock-bug.md` (covers diagnostic queries, coordinator shutdown mechanism at helper.go:193-234, known limitation: preflight runs once-per-call not per-retry).
**Status:** First iteration of fix deployed in cluster (image built with Sleep>30s, 3 rescan sites only). Latest iteration (5s, 8 sites) on disk but NOT in image — rebuild pending. Cluster currently unstable: pod-1 looping shutdown→restart because stuck lock keeps recurring; coordinator's force-shutdown fires every ~100s per helper.go logic.

### 2026-04-15: reboot_from_completeOutage fails when peer has GR in ERROR state
**Issue:** `dba.rebootClusterFromCompleteOutage()` refuses to proceed if any peer has GR in ERROR state — "belongs to a GR group that is not managed as an InnoDB Cluster"
**Fix:** Added loop to stop GR on all ERROR-state peers before calling rebootClusterFromCompleteOutage()
**File:** `run_innodb.sh` — `reboot_from_completeOutage()` function. Needed on BOTH 8.4.x and 9.6.0 branches.
**Report:** `report/innodb-cluster/reboot-from-complete-outage-fix.md`
**Better fix:** Added `loose_group_replication_exit_state_action = OFFLINE_MODE` to my.cnf — members transition to OFFLINE instead of ERROR on GR failure, so reboot works without needing to manually stop GR. Applied to innodb-support branch.

### GR Error 3100: replication hook 'before_commit'
Large single-transaction INSERTs (e.g. `INSERT...SELECT FROM big_table` to double table size) fail with error 3100 — GR certification can't handle oversized write-sets. Fix: batch inserts in chunks (LIMIT 10000), or increase `group_replication_transaction_size_limit`.

---

## InnoDB Cluster Script Fix (`run_innodb.sh`)

**File:** `/home/arman/go/src/kubedb.dev/mysql-init-docker/scripts/run_innodb.sh`
**Branch:** `chaos-57` (also needs porting to 8.4 branches)

### Issues Found & Fixed (8.0.31 → 8.4.8)

| # | Issue | Root Cause | Fix |
|---|---|---|---|
| 1 | `/entrypoint.sh: No such file` | Appscode image uses `/usr/local/bin/docker-entrypoint.sh` | Use `docker-entrypoint.sh` (in PATH) |
| 2 | `CREATE USER 'root'@'%'` error 1396 | Appscode entrypoint already creates `root@%` | `CREATE USER IF NOT EXISTS` |
| 3 | `SQL_LOG_BIN=0` no effect | Each `retry` creates new connection | Single session for all SQL |
| 4 | `Access denied for 'repl'@'localhost'` | 8.4 enforces REQUIRE SSL on socket connections | Use `root` for all local operations |
| 5 | `dba.configureInstance` SQL syntax error | mysqlsh 8.4 defaults to SQL mode (was JS in 8.0) | Add `--js` flag to all JS API calls |
| 6 | `Invalid options: interactive, password` | 8.4 removed these from `configureInstance()` | Pass creds via URI, remove options |
| 7 | `clusterAdminPassword not allowed for existing account` | repl already created by `create_replication_user()` | Don't pass clusterAdmin options |
| 8 | `restart:true` unreliable in containers | mysqlsh can't restart process it didn't start | Use `restart:false` + `mysqladmin shutdown` |
| 9 | `joined_in_cluster` variable typo | `join_in_cluster=1` sets function name not variable | Fixed to `joined_in_cluster=1` |
| 10 | `consistency` in createCluster | 8.4 defaults to BEFORE_ON_PRIMARY_FAILOVER | Removed explicit option |
| 11 | `select_primary` tight loop | No sleep between retries | Added `sleep 1` |
| 12 | Missing password update for existing users | No else branch in create_replication_user | Added ALTER USER for RotateAuth |

### Why 8.0.31 Worked

| Aspect | 8.0.31 (Oracle mysql-server) | 8.4.8 (appscode image) |
|---|---|---|
| Entrypoint | `/entrypoint.sh` | `/usr/local/bin/docker-entrypoint.sh` |
| `root@%` created by entrypoint | No (only `root@localhost`) | Yes |
| mysqlsh default mode | JavaScript | SQL |
| `configureInstance()` options | `password`, `interactive` accepted | Removed |
| REQUIRE SSL on socket | Lenient | Strictly enforced |

### Status

Script fully rewritten. Needs:
1. Rebuild init image with updated `run_innodb.sh`
2. Deploy and test InnoDB Cluster creation
3. Verify all signal handlers (create_cluster, join_in_cluster, rejoin, clone, reboot)

---

## Blog Post Status

**File:** `/home/arman/go/src/github.com/appscode/blog/content/post/chaos-testing-mysql/index.md`

### Written with Full Real Outputs (PostgreSQL blog style):
- [x] Verify Cluster Ready section
- [x] Chaos#1: Kill Primary Pod
- [x] Chaos#2: OOMKill Primary
- [x] Chaos#3: Network Partition
- [x] Chaos#4: IO Latency (100ms)
- [x] Chaos#5: Network Latency (1s)
- [x] Chaos#6: CPU Stress (98%)
- [x] Chaos#7: Packet Loss (30%) — includes UNREACHABLE state
- [x] Chaos#8: Combined Stress (mem+cpu+load)
- [x] Chaos#9: Full Cluster Kill
- [x] Chaos#10: OOMKill Natural (90 JOINs)
- [x] Chaos#11: Scheduled Pod Kill
- [x] Chaos#12: Degraded Failover (IO + Kill workflow)
- [x] Chaos#13: Double Primary Kill

### Written with Earlier Outputs (need fresh run for consistency):
- [x] Chaos#14: Rolling Restart — output captured, blog updated
- [x] Chaos#15: Coordinator Crash — output captured, blog updated
- [x] Chaos#16: Long Network Partition (10 min) — output captured, blog updated
- [x] Chaos#17: DNS Failure — output captured, blog updated
- [x] Chaos#18: PVC Delete + Pod Kill — output captured, blog updated
- [x] Chaos#19: IO Fault (EIO 50%) — output captured, blog updated
- [x] Chaos#20: Clock Skew (-5 min) — output captured, blog updated
- [x] Chaos#21: Bandwidth Throttle (1mbps) — output captured, blog updated
- [x] Results Summary Table

### Blog Format:
- Each experiment shows: before state → chaos YAML → apply → during status → GR members (with MEMBER_PORT) → sysbench output → recovery → verify → cleanup
- DB status explained: Ready/Critical/NotReady
- GR query: `SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;`
- Shows real GR states: ONLINE, UNREACHABLE, ERROR, RECOVERING

---

## Chaos Testing Results (all previous runs)

### Single-Primary (MySQL 8.4.8) — 21 experiments, ALL PASS
### Single-Primary (MySQL 8.0.36) — 12 experiments, ALL PASS
### Single-Primary (MySQL 9.6.0) — 12 experiments, ALL PASS
### Multi-Primary (MySQL 8.4.8, coordinator :23) — 12 experiments, ALL PASS

---

## Key Files

| File | Purpose |
|---|---|
| `setup/kubedb-mysql.yaml` | MySQL cluster YAML |
| `setup/sysbench.yaml` | Sysbench deployment |
| `setup/gr-0.sh` | GR member check script |
| `setup/soak-test.sh` | Long-duration soak test |
| `1-single-experiments/*.yaml` | Chaos experiment YAMLs |
| `report/group-replication-single-primary/` | Single-Primary reports |
| `report/group-replication-multi-primary/` | Multi-Primary reports |
| `report/RELEASE-NOTE-chaos-testing.md` | Release note |
| Blog: `appscode/blog/content/post/chaos-testing-mysql/index.md` | Blog post |
| `mysql-init-docker/scripts/run_innodb.sh` | InnoDB Cluster init script (FIXED) |
| `mysql-init-docker/scripts/run.sh` | Group Replication init script (working) |
| `mysql-coordinator/pkg/coordinator/mysql.go` | Coordinator (signals to run_innodb.sh) |

---

## Environment

```bash
# Regenerate after cluster redeploy:
PASS=$(kubectl get secret mysql-ha-cluster-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')
echo "PASS=$PASS" > /tmp/chaos-env.sh && echo "SBPOD=$SBPOD" >> /tmp/chaos-env.sh
```
