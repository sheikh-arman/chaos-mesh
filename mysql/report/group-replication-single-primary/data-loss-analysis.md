# MySQL Coordinator & Startup Scripts - Data Loss Analysis

**Date:** 2026-04-03
**Scope:** `kubedb.dev/mysql-coordinator` (coordinator) + `kubedb.dev/mysql-init-docker/scripts/run.sh` (branches: `chaos` for 8.0.*, `fix-842` for 8.4.*)

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 6 |
| HIGH | 6 |
| MEDIUM | 7 |
| LOW | 2 |

---

## CRITICAL Findings

### C1. Full Recovery Can Elect Wrong Pod - Transaction Loss

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:379-423`

In `findMaxTransactedPod()`, when a GTID query or comparison fails for a pod, the pod is **silently skipped** (`continue`). If the pod with the highest GTID set is temporarily unreachable (network blip, DNS lag), a pod with a *lower* GTID set is elected as recovery primary. All transactions that only existed on the skipped pod are **permanently lost** once the new cluster bootstraps.

```go
// line 401-405
result, err := c.queryInDatabase(&podMeta, selectGTID)
if err != nil {
    klog.Warningf(...)
    continue   // pod with highest GTID silently skipped
}
```

Additionally, `maxGTID` starts as `""` (line 387). The empty set is always a subset of any GTID, so the first reachable pod wins by default regardless of actual transaction count.

**Data loss scenario:** During a full cluster outage, pod-0 has GTID `uuid:1-100` (most transactions) but takes 5s longer to restart. Pod-1 with GTID `uuid:1-90` is reachable first and is elected. Transactions 91-100 are lost forever.

---

### C2. No Distributed Lock for Group Replication Recovery - Split Brain

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:158-203, 287-323`

`setupSynchronousCluster()` (Group Replication mode) has **no distributed lock**. Compare with semi-sync mode which acquires a Raft lock (`semi-sync.go:600-601`). During full recovery, multiple pods run `findMaxTransactedPod()` concurrently. If two pods both conclude they have the highest GTID (due to stale reads or timing), both call `createNewCluster()`, resulting in **two separate clusters** with diverging data.

**Data loss scenario:** After a full cluster outage, pod-0 and pod-2 both detect no primary and both bootstrap new clusters simultaneously. Writes go to both, causing irrecoverable data divergence.

---

### C3. `checkPrimaryOnline()` Skips Current Pod - Triggers Unnecessary Full Recovery

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:353-374`

```go
if podName == c.curPodName {
    continue  // never checks if WE are the primary
}
```

If the current pod **is** the primary, `checkPrimaryOnline()` returns `false`. This causes the coordinator to fall into `fullRecovery()` instead of recognizing the cluster is already operational. Full recovery may elect a pod with fewer transactions as the new primary.

**Data loss scenario:** Primary pod's coordinator restarts. It doesn't check itself, concludes no primary exists, triggers full recovery, and bootstraps a new cluster from a pod with fewer transactions.

---

### C4. Infinite Loop in `findMaxTransactedPod()` Blocks All Recovery

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:392-399`

```go
for {
    if result, _ := c.queryInDatabase(&podMeta, selectOne); result != nil {
        break
    }
    time.Sleep(dnsPollInterval)
}
```

This is an **unbounded busy-wait loop** with no timeout. If a pod is permanently down (disk failure, node eviction), this function blocks forever. The entire coordinator hangs, no primary is elected, and all writes to the cluster are blocked indefinitely.

---

### C5. Inverted Version Check in `LabelPods()` - Misdirects Writes

**File:** `mysql-coordinator/pkg/coordinator/mode-detector.go:41-44`

```go
query := primaryReplicaQueryNewVersion
if isNewMySQLVersion() {
    query = primaryReplicaQueryOldVersion  // backwards!
}
```

When `isNewMySQLVersion()` returns true (>= 8.4.2), it uses `primaryReplicaQueryOldVersion`. Pods get wrong labels. A replica could be labeled as primary, directing client writes to a read-only node (error 1290) or, if super_read_only is somehow off, causing data divergence.

---

### C6. RESET MASTER / RESET BINARY LOGS Destroys GTID History

**File:** `mysql-init-docker/scripts/run.sh`

**chaos branch (8.0.*):** lines 406, 424, 487:
```bash
retry 60 ${mysql} -N -e "RESET MASTER;"
```

**fix-842 branch (8.4.*):** equivalent lines:
```bash
retry 60 ${mysql} -N -e "RESET BINARY LOGS AND GTIDS;"
```

These commands **irrecoverably destroy** binary log and GTID execution history. In `join_by_clone()`, `RESET MASTER` is called **before** the clone starts. If the clone then fails for all donors, the node has lost its GTID history AND has no cloned data. It cannot rejoin via incremental recovery.

**Data loss scenario:** Node needs to rejoin via clone. RESET MASTER wipes GTID. Clone fails (disk full, network error). Node now has original data but no GTID history -- unrecoverable without manual intervention.

---

## HIGH Findings

### H1. `restartMySQLProcess()` Shuts Down Without Draining Transactions

**File:** `mysql-coordinator/pkg/coordinator/helper.go:148-180`

```go
_, err := c.queryInDatabase(c.curPodMeta, shutdownCommand)
```

Issues a raw `shutdown;` with no `SET GLOBAL innodb_fast_shutdown=0`, no `FLUSH TABLES WITH READ LOCK`, and no mechanism to ensure in-flight transactions complete. The node may still be receiving write traffic (not fenced or set to read-only first). In-flight transactions are lost.

---

### H2. Semi-Sync Primary Election Doesn't Verify All Replicas Are Synced

**File:** `mysql-coordinator/pkg/coordinator/semi-sync.go:599-653`

When electing a new semi-sync primary, `syncGTID()` is only checked for the **current pod**. It does not verify that all replicas have applied all retrieved GTIDs. If replica A has retrieved-but-not-applied transactions from the old primary, and replica B (with fewer transactions) is elected, those in-flight transactions on A are lost.

---

### H3. Signal File Race Condition (run.sh + coordinator)

**File:** `mysql-init-docker/scripts/run.sh` (both branches), `mysql-coordinator/pkg/coordinator/helper.go:63`

The coordinator writes to `/scripts/signal.txt`, and run.sh reads it then immediately deletes it:
```bash
desired_func=$(cat /scripts/signal.txt)
rm -rf /scripts/signal.txt
```

If the coordinator writes a new signal between `cat` and `rm`, the new signal is lost. A `join_by_clone` signal could be lost, leaving a diverged node sitting idle with stale data.

Additionally, `run_innodb.sh` has a **double-delete** at line 338: `rm -rf /scripts/signal.txt` runs again after `wait $pid`, destroying any signal written while mysqld was running.

---

### H4. Signal-File-Based Cluster Operations Are Fire-and-Forget

**File:** `mysql-coordinator/pkg/coordinator/helper.go:110-122`

Functions `joinInCluster()`, `joinByClone()`, `rejoinInCluster()`, `rebootFromCompleteOutage()`, and `createNewCluster()` all write a signal to `/scripts/signal.txt` and return. There is **no verification** that MySQL actually reads and acts on the signal, no timeout, no acknowledgment. The coordinator marks the join as complete (via `createJoinInClusterFile()`) **before the join has actually happened**.

---

### H5. `SQL_LOG_BIN=0` Applied to Separate Connections - No Effect

**File:** `mysql-init-docker/scripts/run.sh` (both branches), lines 217 and 226:

```bash
retry 60 ${mysql} -N -e "SET SQL_LOG_BIN=0;"
...
retry 60 ${mysql} -N -e "CREATE USER IF NOT EXISTS ..."
retry 60 ${mysql} -N -e "SET SQL_LOG_BIN=1;"
```

`SET SQL_LOG_BIN` is **session-scoped**. Each `retry`/`mysql` invocation creates a new connection. So the `SET SQL_LOG_BIN=0` has zero effect on subsequent CREATE USER/GRANT statements. User creation operations ARE written to the binary log, which can cause replication conflicts when the same user creation is attempted on other nodes.

---

### H6. `reboot_from_completeOutage()` Piping Through `yes` - Premature Member Removal

**File:** `mysql-init-docker/scripts/run_innodb.sh` (both branches), lines 253-254:

```bash
yes | $mysqlshell -e "dba.rebootClusterFromCompleteOutage('$clusterName',{force:'true'})"
```

Piping `yes` auto-confirms **all** prompts, including prompts to remove temporarily-unavailable members. If a node is just slow to restart (not permanently gone), `yes` confirms its removal from cluster metadata. When it comes back, it's treated as a fresh instance rather than a rejoiner, potentially losing its local data.

---

## MEDIUM Findings

### M1. `partialRecovery()` Joins Immediately After MySQL Restart - No Wait

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:246-285`

```go
c.restartMySQLProcess()          // may shut down MySQL
// ... immediately tries to join cluster
if err := joinInCluster(); ...   // MySQL may still be restarting
```

If `restartMySQLProcess()` shuts down MySQL, the code immediately proceeds to join. MySQL is still restarting. If it comes back with a stale GTID set (crash recovery rolled back an uncommitted transaction), it could rejoin with missing data.

---

### M2. `holdsExtraTransactions()` Returns `true` on Transient Errors - Unnecessary Clone

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:560-586`

After our fix, all error paths return `true` (assume extra transactions). If the primary is momentarily unreachable, this triggers `joinByClone()` which **replaces the entire data directory**. While safer than the old behavior (returning `false` which could cause a broken rejoin), it can cause unnecessary data replacement and extended downtime for transient errors.

---

### M3. Errant Transaction Handling via Pseudo-Transaction Masks But Doesn't Remove Data

**File:** `mysql-coordinator/pkg/coordinator/semi-sync.go:466-498`

`insertPseudoTransaction()` inserts empty transactions on the primary for each errant GTID. The original (possibly data-modifying) errant transaction on the replica remains. If the replica later becomes primary, those errant writes are live but every other node has empty transactions for those GTIDs.

---

### M4. `parseGTIDList()` Cannot Handle Multiple UUID Ranges

**File:** `mysql-coordinator/pkg/coordinator/semi-sync.go:502-527`

```go
parts := strings.SplitN(gtidset, ":", 2)
```

A MySQL GTID set can contain multiple UUIDs (e.g., `uuid1:1-5,uuid2:1-3`). This function only handles a single `uuid:range` pair. Multi-UUID errant transactions will be incorrectly parsed, leaving errant transactions unresolved.

---

### M5. Clone Error Handling Falls Through to Unsafe Join

**File:** `mysql-init-docker/scripts/run.sh` (both branches)

Clone success/failure detection relies on checking for the specific error string `"mysqld is not managed by supervisor process"`. Any other clone error (disk full, auth failure, network timeout) causes a `continue` to the next donor. If ALL donors fail, the code falls through to `START GROUP_REPLICATION` on a node that already had `RESET MASTER` executed -- joining with wiped GTID history and stale data.

---

### M6. `joined_in_cluster` Variable Bug in run_innodb.sh

**File:** `mysql-init-docker/scripts/run_innodb.sh` (both branches), line 216:

```bash
join_in_cluster=1
```

This sets the **function name** `join_in_cluster` to `1` rather than the **variable** `joined_in_cluster` (declared at line 207). The variable is never set to 1, so `check_instance_joined_in_cluster` never indicates success, causing `rejoin_in_cluster()` to always fall through to `removeInstance + join_in_cluster` (line 241-243), triggering unnecessary data clone operations.

---

### M7. Raft Lock TOCTOU Race in Semi-Sync

**File:** `mysql-coordinator/pkg/coordinator/raft_client_utils.go:39-93`

`AcquireLockFromRaft()` does a GET to check who holds the lock, then a separate POST to set the lock. Between GET and POST, another node could also read an empty lock and set itself as holder. Both nodes proceed believing they hold the lock, potentially both becoming primary simultaneously.

---

## LOW Findings

### L1. Non-Deterministic Candidate Ordering for Older MySQL

**File:** `mysql-coordinator/pkg/coordinator/mysql.go:502-507`

`candidatePodList()` returns `nil` for older MySQL versions. `findMaxTransactedPod(nil)` builds the pod list from `c.peerList` in reverse order. When GTID sets are equal, the last successful comparison wins. This is non-deterministic across coordinator instances.

---

### L2. Passwords Exposed in Process Table

**File:** All scripts, all branches

MySQL passwords are passed via command-line arguments (`mysql -u root --password=${PASSWORD}`), visible in `/proc/[pid]/cmdline` and `ps` output. The chaos branch partially mitigates this by using `MYSQL_PWD` env var in some places, but it's inconsistent.

---

## Branch Comparison: chaos (8.0.*) vs fix-842 (8.4.*)

| Aspect | chaos (8.0.*) | fix-842 (8.4.*) | Impact |
|--------|---------------|-----------------|--------|
| RESET command | `RESET MASTER` (destructive) | `RESET BINARY LOGS AND GTIDS` (same semantics, new syntax) | Same risk |
| User creation cleanup | `RESET MASTER` after user creation | **`RESET REPLICA`** (much safer) | **fix-842 is safer** |
| Primary discovery timeout | 60 retries | 20 retries | fix-842 could miss slow primaries |
| Primary discovery query | `group_replication_primary_member` (deprecated) | `MEMBER_ROLE = 'PRIMARY'` (correct) | **fix-842 is correct** |
| `CHANGE MASTER TO` syntax | Old syntax | `CHANGE REPLICATION SOURCE TO` | fix-842 uses non-deprecated syntax |
| Removed config directives | Uses `binlog_format`, `transaction_write_set_extraction` | Removed (correct for 8.4+) | fix-842 is correct |

**The fix-842 branch is safer** primarily due to the `RESET REPLICA` vs `RESET MASTER` change in `create_replication_user()`. However, both branches share all the critical signal race, bootstrap, and clone error handling issues.

---

## Recommended Fixes (Priority Order)

### 1. Add timeout to `findMaxTransactedPod()` busy-wait loop (C4)
```go
deadline := time.Now().Add(2 * time.Minute)
for {
    if time.Now().After(deadline) {
        klog.Warningf("timed out waiting for pod %s, skipping", podName)
        break
    }
    if result, _ := c.queryInDatabase(&podMeta, selectOne); result != nil {
        break
    }
    time.Sleep(dnsPollInterval)
}
```

### 2. Add distributed lock for Group Replication full recovery (C2)
Use the same Raft-based lock that semi-sync mode uses before entering `fullRecovery()`.

### 3. Fix `checkPrimaryOnline()` to include current pod (C3)
Remove the `continue` for `c.curPodName` or add a separate self-check.

### 4. Fix inverted version check in `LabelPods()` (C5)
Swap `primaryReplicaQueryNewVersion` and `primaryReplicaQueryOldVersion`.

### 5. Add retry/verification for `findMaxTransactedPod()` (C1)
Require all pods to be reachable before electing a recovery primary, or retry unreachable pods with a timeout.

### 6. Use atomic signal file operations (H3)
Replace `echo > signal.txt` + `cat signal.txt; rm signal.txt` with `mv`-based atomic swap:
```bash
# Writer (coordinator): write to temp then rename
echo "join_in_cluster" > /scripts/signal.txt.tmp && mv /scripts/signal.txt.tmp /scripts/signal.txt

# Reader (run.sh): rename then read
mv /scripts/signal.txt /scripts/signal.txt.processing 2>/dev/null && cat /scripts/signal.txt.processing
```

### 7. Fix `SQL_LOG_BIN` to use single session (H5)
Combine all user creation SQL into a single `mysql -e` invocation.

### 8. Add graceful shutdown to `restartMySQLProcess()` (H1)
```go
c.queryInDatabase(c.curPodMeta, "SET GLOBAL innodb_fast_shutdown=0")
c.queryInDatabase(c.curPodMeta, "SET GLOBAL super_read_only=ON")
c.queryInDatabase(c.curPodMeta, shutdownCommand)
```

### 9. Fix `joined_in_cluster` variable bug in run_innodb.sh (M6)
Change `join_in_cluster=1` to `joined_in_cluster=1`.

### 10. Move `RESET MASTER` after clone success, not before (C6)
Only wipe GTID history after confirming the clone completed successfully.
