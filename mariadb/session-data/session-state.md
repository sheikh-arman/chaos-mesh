# MariaDB Chaos Testing Session State

**Updated:** 2026-04-24

## 2026-04-24: Blog updated with Replication 29-test run (folded in-place, no separate defect-hunt section)

Per user direction "no need different section like extended defect — add the additional tests to previous section, mention solution of two failed tests":
- Replaced the old 18-row Replication Chaos Experiments table with a **single 29-row table** showing the full defect-hunt outcome (27 PASS + 2 FAIL clearly flagged on T12/T13 and T15).
- Follow-up `#### IO Chaos Defects & Solutions` subsection inline under the table documents Defect #1 + Defect #2 with reproducer YAML refs and fix status. Defect #3 (`innodb_force_recovery>0` blocks backup-stream) dropped from the blog because it isn't a failed chaos test — it's a follow-up issue during recovery of #2, not the user's focus.
- `## MariaDB Replication with MaxScale (18 Experiments)` → `(29 Experiments)` with a short intro explaining why it's deeper than Galera's 18 (slave-side variants, MaxScale kills, compound, rolling restart).
- Combined Results summary header: "36/36 Baseline PASS + 3 Defects" → **"45/47 PASS, 2 IO-Chaos Defects with Fixes on Chaos Branch"** (18 Galera + 29 Replication = 47 total; 45 pass; 2 IO-chaos defects).
- Replication summary table in the combined-results section expanded from 18 → 29 rows matching the top table, with a new Result column that marks the two failures.
- Conclusion paragraph + capability table updated to drop "defect hunt" language and refer only to "the two IO-chaos failures".

Final blog length: 2,263 lines. Galera sections untouched.

Follow-up same day: added `### Replication Testing Procedure (Step-by-step)` subsection between "Deploy MariaDB Replication with MaxScale" and "Replication Chaos Experiments" — 6-step reusable flow (one-time setup → capture baseline → start sysbench load → apply chaos → wait clear → verify recovery → verify data integrity) with pass/fail criteria that references the known T12/T13/T15 failure modes. Readers can now apply any of the 29 YAMLs in `defect-hunt-yamls/` with the same procedure; only the YAML path in Step 3 changes. Blog now 2,385 lines.

Also adjusted counts: 27/29 → 26/29 PASS on Replication, 45/47 → 44/47 combined, "2 IO-chaos failures" → "3 IO-chaos failures" (T12, T13, T15 all count separately). Each failure's writeup now explicitly documents the manual operator intervention needed on current releases to avoid data loss (Defect #1: `kubectl delete pod`; Defect #2: `FLUSH BINARY LOGS` + PVC-delete+pod-delete re-seed for binlog-only, external backup restore for undo-corruption).

## 2026-04-24: Bug #3 — backup-stream.sh echoes never appear in any log

Why `"Backup data for pod $ip transferred successfully."` / `"...failed..."` from `backup-stream.sh` are invisible in every log: `kmodules.xyz/client-go/tools/exec/lib.go:155-157` inside `ExecIntoPod` does

```go
if execErr.Len() > 0 {
    return "", fmt.Errorf("stderr: %v", execErr.String())
}
return execOut.String(), nil
```

**Any byte on stderr → ExecIntoPod returns `("", error)` and throws stdout away.** `mariadb-backup` prints every `[00] <ts> <file>` progress line to stderr, so `execErr` is always non-empty → coordinator takes the Warning branch at `mariadb.go:688`, logs only the stderr, and the `klog.Info("backup stream output: ", output)` at L689 never runs.

**Fix (chaos-branch `backup-stream.sh`):**
- Redirect mariadb-backup's and socat's stderr to `/tmp/mariabackup.err` / `/tmp/socat.err`.
- Clean stderr means `ExecIntoPod` returns the stdout normally → success/failure echoes finally land in coordinator log.
- On failure, fold captured stderr files onto stdout (`tail -c 4000`) so the operator still sees the real cause even though `ExecIntoPod`'s stdout/stderr-handling is lossy.

Not changing `kmodules.xyz/client-go` — it's shared across operators and the "stderr == failure" behavior, while wrong for chatty tools like mariabackup, isn't ours to flip.

## 2026-04-24: Bug #2 on chaos branch — stale GTID causes 1062 Duplicate entry on slave

After the PIPESTATUS fix unblocked backup-stream, md-2 restored successfully but the slave SQL thread immediately aborted with `Duplicate entry '786405' for key 'PRIMARY'` on `testdb.big_table`, stuck at `Exec_Master_Log_Pos: 344` (beginning of `mariadb-bin.000004`).

**Root cause — race between gtid-sample and backup lock:**
- Coordinator's `createMasterGtidFile()` (`mariadb-coordinator/pkg/coordinator/mariadb.go:172-207`) queries master's `gtid_binlog_pos` and writes `/scripts/gtid.txt` BEFORE backup-stream is triggered.
- Between that query and mariabackup's BACKUP-STAGE-START lock, master keeps committing transactions.
- On this run: `gtid.txt = 0-1-28`, mariabackup's `mariadb_backup_info.binlog_pos.GTID = 0-1-30` (two commits slipped in during the gap).
- Joiner runs `SET GLOBAL gtid_slave_pos='0-1-28'; START SLAVE`. Master resends GTID 0-1-29 and 0-1-30 — but those rows are already in the restored datadir → 1062.

**Fix applied to chaos branch** (`kubedb.dev/mariadb-init-docker/scripts/std-replication-setup.sh:425-450`): after a successful backup-stream restore, read the authoritative GTID from `/var/lib/mysql/mariadb_backup_info` (the `GTID of the last change '...'` line) and use that as `gtid_slave_pos`. Fall back to `/scripts/gtid.txt` only when there was no backup-stream (first-cluster setup path). Extraction verified on-pod: correctly parsed `0-1-30`.

**Live recovery without image rebuild:** `STOP SLAVE; SET GLOBAL gtid_slave_pos='<backup_info-gtid>'; START SLAVE` on the stuck joiner. Did this on md-2 just now — slave caught up immediately (`Seconds_Behind_Master: 0`, `Exec_Master_Log_Pos: 310141056`). Cluster is now `Ready` with md-0 Master, md-1+md-2 Slaves.

**Next rebuild must include both fixes** in `skaliarman/mariadb-init:test12` (or similar):
1. PIPESTATUS snapshot in `std-replication-setup.sh` + `backup-stream.sh`.
2. GTID-from-backup_info in `std-replication-setup.sh`.

## 2026-04-24: ROOT CAUSE — PIPESTATUS double-read bug in my backup-stream fix

**The "mbstream=1 failure" was a phantom.** Backup-stream was working end-to-end — master streamed all data, joiner's mbstream extracted all 216 entries / 238M into `/var/lib/mysql` successfully. But the post-pipeline rc check was wrong and told the script it had failed, so the cleanup loop wiped the freshly-restored datadir and retried 10 times before giving up.

**The bug (both `backup-stream.sh` and `std-replication-setup.sh`):**
```bash
socat ... | mbstream ...
socat_rc=${PIPESTATUS[0]:-1}     # reads [0]=0 from the real pipeline
mbstream_rc=${PIPESTATUS[1]:-1}  # PIPESTATUS got reset by the assignment above!
                                  # now [1] is unset → :-1 default kicks in → 1
```
Reproduced directly on md-2 pod (bash 5.2.21):
```
after pipeline: [0]=0 [1]=1    ← the pipeline's real status
after assign:   [0]=0 [1]=     ← simple-command assignment reset PIPESTATUS to 1-element
```
So every success path reported `mbstream=1` (phantom), while real failures happened to also report `mbstream=1` — indistinguishable, which is why I chased socat/mbstream/target-dir/content red herrings for hours.

**Confirming evidence that was there all along but I dismissed:**
- All 10 stderr-capture files `/tmp/mbstream.err.N` on md-2 are **0 bytes**. mbstream never complained — because mbstream never failed.
- Production path extracted exactly 216 entries / 238M every attempt — identical to my successful manual test (which used the same tools but different shell structure).
- Master's mariabackup reported `completed OK!` on every run — not `Broken pipe` (the broken-pipe entries from 2026-04-23 were on the old corrupted cluster).

**Fix applied to chaos branch** (`kubedb.dev/mariadb-init-docker/scripts/`):
- `std-replication-setup.sh:306-308`
- `backup-stream.sh:36-37`

Pattern:
```bash
pipe_status=("${PIPESTATUS[@]}")   # snapshot the whole array atomically
socat_rc=${pipe_status[0]:-1}
mbstream_rc=${pipe_status[1]:-1}
```
Verified on-pod: buggy pattern reports `0/1` on success, fixed pattern reports `0/0` on success and still `1/1` on genuine failure.

**Next:** rebuild `skaliarman/mariadb-init` (next tag, e.g. `test12`), bump the MariaDBVersion/PetSet image ref, let the pod restart. Retry loop should succeed on attempt 1 and bring the cluster to `Ready`. No other changes needed for this fix.

**Aside (not load-bearing but still worth doing):** the fallback abort path
```bash
while true; do
   log "ERROR" "All $MAX_BACKUP_STREAM_ATTEMPTS backup stream attempts failed — aborting (operator intervention required)"
done
```
has no `sleep`, spams the kubelet log at ~100k lines/sec and overwrites the useful diagnostics. Should be `sleep 30` inside, or replace the loop with `exit 1` so kubelet surfaces the crash-loop visibly.

## 2026-04-24: earlier same-day investigation (kept for context — mostly red herrings now that PIPESTATUS bug is the real cause)

**State at session start:** md-0 Terminating (old pod, role Unknown from earlier binlog-corruption run), md-1 Master (running), md-2 in infinite `All 10 backup stream attempts failed` log loop with empty `/var/lib/mysql`. Deployed image is `skaliarman/mariadb-coordinator:test8` + `skaliarman/mariadb-init:test10` — has the 10-attempt cap, POD_IP/range bind, PIPESTATUS defaults, quarantine-via-find-delete, but **does NOT yet carry the Bug #4/#5 source-level fixes** (stderr capture, `mariadb_backup_checkpoints` artifact name).

**md-0 restarted fresh at 10.244.0.29** (empty PVC) and hits the identical deterministic failure — from its `mariadb` container log:
```
Backup stream attempt 1/10 (bind=10.244.0.29, accept only from 10.244.0.25)
Backup stream pipeline failed (socat=0, mbstream=1)
Cleaning failed restore from /var/lib/mysql (230 entries, 163M)
```
`socat=0, mbstream=1, 230 entries / 163M` is the same signature as md-2 from 2026-04-23. Matching side on md-1 (`md-coordinator` log) shows `mariadb-backup: Error writing file 'UNKNOWN' (errno: 32 "Broken pipe")` right after streaming `aria_log_control` and again on `undo001` — i.e. joiner's mbstream dies first, socat-joiner reaches EOF cleanly (rc=0), master's mariabackup gets SIGPIPE.

**Confirming last session's diagnosis:** the failure is not in the backup content — the 2026-04-23 manual test (`kubectl exec md-1 mariabackup-backup | kubectl exec md-2 mbstream -x`) successfully extracted full 163MB with all `mariadb_backup_checkpoints`/`ibdata1`/`undo001-003`. Only the **socat-TCP transport** path fails, and always at the same cut-point. Strongly suggests socat half-close / EOF semantics truncating the byte stream to mbstream (mbstream then exits 1 on truncated input).

**Why we still can't see mbstream's actual error message:** `run-on-present.sh` pipeline has no `2>stderr.log` redirection (Bug #5 fix was source-only, not in `test10` image), and the tight abort-loop `while true; do log "ERROR" ...; done` at script tail overwrites the kubelet log buffer, so any mbstream stderr from the failed attempt is not recoverable from `kubectl logs`.

**Next actions to unblock:**
1. Rebuild `mariadb-init-docker` → push as `test11` with Bug #4 (`mariadb_backup_checkpoints` name) and Bug #5 (per-attempt `2>$errfile`, `head -c 2000 $errfile | tr '\n' '|'` on failure) applied. Bump MariaDBVersion/PetSet image tag so md-0 and md-2 pick it up on next restart. This gives us the actual mbstream error string.
2. Parallel: try `nc` instead of socat in `backup-stream.sh` + `run-on-present.sh`, or add `shut-down`/`end-close` options to socat to rule out the half-close theory. If nc works, root cause is definitely socat.
3. Cluster is not re-seedable in place. For fresh chaos-test runs, `kubectl delete mariadb md -n demo && re-apply` is the clean path.

**Also noticed:** the abort path
```bash
while true; do
   log "ERROR" "All $MAX_BACKUP_STREAM_ATTEMPTS backup stream attempts failed — aborting (operator intervention required)"
done
```
is a tight no-sleep infinite loop at `run-on-present.sh` tail. Spams logs at ~100k lines/sec, overwrites buffer, burns CPU. Should be `sleep 30` inside the loop, or better yet `exit 1` so kubelet handles the crash-loop visibly.

## 2026-04-23: Debugged re-triggered Defect #2 on running cluster
**Symptom:** Ran `iochaos.chaos-mesh.org/md-master-io-mistake` against md-0. Both slaves went to `Slave_IO_Running: No` with errno 1595 (`Relay log write failure: could not queue event from master`) stuck at `mariadb-bin.000005:2682863`. Deleted md-2 PVC+pod to force rebuild — new md-2 still looped errno 1236 (`log event entry exceeded max_allowed_packet … last event read from mariadb-bin.000005 at 2679199`).

**Key finding — current `recoverBrokenSlaveIOIfNeeded()` fix (mariadb-coordinator/pkg/coordinator/mariadb.go:632-668) is INSUFFICIENT for real binlog corruption.** Re-pointing slave to `mariadb-bin.000005:<master-head>` doesn't help because master's binlog-dump thread has to read the same file sequentially to serve events, hits the corruption at offset 2679199 BEFORE reaching the requested position, throws errno 1236 back every 10s cycle.

**Proposed proper fix:** On 1236-family error, coordinator must first run `FLUSH BINARY LOGS` on master to rotate past the corrupt file (creates `mariadb-bin.000006` clean), THEN re-point slaves to the new file. Without this, the fix is a no-op against true binlog-level corruption.

**Cosmetic bug fixed (Defect #3 tail):** `backup-stream.sh:36-37` and `std-replication-setup.sh:299-300` used bare `${PIPESTATUS[N]}` which produced "`[: : integer expression expected`" when a PIPESTATUS slot was empty. Hardened to `${PIPESTATUS[N]:-1}` in both files — empty/unknown treated as failure (safe default, hits existing retry/quarantine).

**Bug #4 discovered — wrong filename in post-stream artifact check:** `std-replication-setup.sh:303` checked `/var/lib/mysql/xtrabackup_checkpoints` but MariaDB's `mariabackup` writes `mariadb_backup_checkpoints` (xtrabackup_* is the Percona naming). So the post-check falls through to the "lacks mariabackup artifacts" branch even on successful extractions. Fixed.

**Bug #5 — mbstream stderr silently swallowed:** `std-replication-setup.sh` pipeline had no stderr redirection on socat/mbstream, so when mbstream exits 1 we only see "pipeline failed" with no cause. Added per-attempt stderr capture files + log tail on failure (first 2000 chars, newlines → `|`).

**Mystery still open (this cluster):** mbstream=1 on joiner even though manual kubectl-piped test from md-1 → md-2 extracted full 163MB with rc=0 and all required files (mariadb_backup_checkpoints, ibdata1, undo001-003). Failure is deterministic at 163MB/230 entries every attempt. Likely a socat-TCP-transport-level issue (close semantics / buffering / range option quirk). Stderr capture added above will reveal root cause on next occurrence — requires rebuild of `mariadb-init-docker` image + redeploy.

**Current cluster state is not recoverable in place** — md-0 is now slave (role Unknown, stuck errno 1595 on `mariadb-bin.000003:405`), md-1 is promoted master, md-2 in infinite backup-stream retry loop. Clean path = rebuild cluster fresh (`kubectl delete mariadb md -n demo && re-apply`).

## 2026-04-21: Earlier state

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

## 2026-04-22: Completed all 29 chaos tests on MariaDB 11.8.5 + MaxScale
**Cluster was rebuilt fresh after T15 corruption to resume testing.**

Tests 16–29 all PASS:
- Network partition (master↔slaves, slave isolated, maxscale↔mariadb): cluster handles
- Network latency 1s: zero impact on async replication (key contrast with Galera)
- Packet loss/duplicate/corrupt: async replication resilient
- Bandwidth 1mbps: TPS -97% but no errors, zero data loss
- DNS error: no impact (pre-resolved IPs)
- Clock skew: minor TPS dip
- Full cluster kill: ~75s auto-recovery
- Full MaxScale kill: ~3min auto-recovery
- Compound master+maxscale kill: ~90s recovery
- Rapid rolling restart: ~2m30s recovery, momentarily all roles "Down" during rapid deletes

**Final tally: 26/29 pass. 3 defects found (all IO-chaos category):**
1. **Defect #1 (High):** IOChaos fault (EIO 50%) leaves pod with mariadbd dead, init script ping-loop forever
2. **Defect #2 (Critical):** IOChaos mistake (random corruption) on master breaks binlog + InnoDB undo permanently, no auto-recovery
3. **Defect #3 (Medium):** master with `innodb_force_recovery>0` silently blocks slave provisioning via backup-stream

Report: `mariadb/report/kubedb-mariadb-defect-hunt-2026-04-21.md`
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
