# InnoDB Cluster — AuthSecret Rotation Hang (MYSQLSH 51500)

**Date:** 2026-04-20
**Cluster:** `my-innodb` (MySQL 8.2.0, 3-node InnoDB Cluster, namespace `demo`)
**Trigger:** AuthSecret rotate ops request

---

## Symptom

During AuthSecret rotation, `run_innodb.sh` on restarted pods fails with:

```
ERROR: The operation cannot be executed because it failed to acquire the
Cluster lock through primary member 'my-innodb-X.my-innodb-pods.demo:3306'.
Another operation requiring access to the member is still in progress,
please wait for it to finish and try again.
Cluster.rescan: Failed to acquire Cluster lock through primary member
'my-innodb-X.my-innodb-pods.demo:3306' (MYSQLSH 51500)
```

All 10 retries fail. Coordinator then force-shuts down mysqld after 100s
"unhealthy" window, triggering an infinite SHUTDOWN → restart → stuck → SHUTDOWN loop.

---

## Root Cause

`cluster.rescan()`, `addInstance()`, `removeInstance()`, `rejoinInstance()`
all acquire an **EXCLUSIVE cluster-wide lock** on the PRIMARY via
the LOCKING SERVICE: `AdminAPI_cluster.AdminAPI_lock`.

**AuthSecret rotation flow** (`kubedb.dev/mysql/pkg/ops/rotate_auth.go`):
1. `ALTER USER` to change passwords on primary
2. `RunParallel(Restart)` — **all pods restart simultaneously**
3. Each restarted pod runs `run_innodb.sh` → each calls AdminAPI operations
4. Multiple pods race for the same primary-side lock
5. If any mysqlsh session dies/disconnects abnormally (retry-wrapper kill, pod
   SIGTERM mid-operation, connection reset) WITHOUT proper release, the
   LOCKING SERVICE lock persists on the idle-but-alive `repl` connection
   until TCP `wait_timeout` (default 28800s)
6. All subsequent rescan/rejoin attempts return MYSQLSH 51500

Once stuck, the pod's init script cannot make progress → coordinator's
`helper.go:restartMySQLProcess()` fires `SHUTDOWN` after 10 unhealthy
polls — expecting a fresh path to succeed. But after restart, the lock
is still held, so it loops.

---

## Diagnostic Queries

### 1. Check for stuck cluster locks (run on PRIMARY)

```sql
SELECT * FROM performance_schema.metadata_locks
WHERE lock_type='EXCLUSIVE'\G
```

Stuck-lock signature:
```
OBJECT_TYPE: LOCKING SERVICE
OBJECT_SCHEMA: AdminAPI_cluster
OBJECT_NAME: AdminAPI_lock
LOCK_TYPE: EXCLUSIVE
LOCK_DURATION: EXPLICIT
LOCK_STATUS: GRANTED
```

### 2. Identify the holder connection

```sql
SELECT t.THREAD_ID, t.PROCESSLIST_ID, t.PROCESSLIST_USER,
       t.PROCESSLIST_HOST, t.PROCESSLIST_COMMAND,
       t.PROCESSLIST_TIME, t.PROCESSLIST_STATE
FROM performance_schema.threads t
JOIN performance_schema.metadata_locks m ON m.OWNER_THREAD_ID = t.THREAD_ID
WHERE m.lock_type='EXCLUSIVE'\G
```

**Interpretation:**
| COMMAND | Meaning |
|---|---|
| `Query` | Legitimate in-flight AdminAPI operation — wait for it |
| `Sleep` (>5s) | **STUCK** — script finished but session didn't disconnect |

### 3. Cluster GR state

```sql
SELECT member_host, member_state, member_role
FROM performance_schema.replication_group_members;
```

---

## Manual Recovery Steps

1. Identify stuck session's `PROCESSLIST_ID` (query #2 above)
2. On PRIMARY:
   ```sql
   KILL <PROCESSLIST_ID>;
   ```
3. Verify lock released:
   ```sql
   SELECT COUNT(*) FROM performance_schema.metadata_locks
   WHERE lock_type='EXCLUSIVE';  -- should be 0
   ```
4. If pod's init script has spawned a hung `mysqlsh` process (never
   completes even after lock release), kill it in the container:
   ```bash
   kubectl exec -n demo <pod> -c mysql -- bash -c 'kill -9 <mysqlsh-pid>'
   # container lacks /bin/kill — use bash builtin
   ```

### Real observed incidents (this session)

| Stuck session | Pod source | Sleep time | Action |
|---|---|---|---|
| `repl@10.244.0.28` conn 24194 | my-innodb-1 | ~175s | `KILL 24194` on primary |
| `repl@10.244.0.50` conn 1393 | my-innodb-1 | ~500s | `KILL 1393` on primary |
| `root@localhost` conn 25856 | our manual rescan | ~184s | `KILL 25856` (own orphan) |

In each case the owning `mysqlsh` session was in `Sleep` state yet
holding `AdminAPI_cluster.AdminAPI_lock` — a smoking-gun for an
abandoned lock.

---

## Coordinator Force-Shutdown Mechanism

`kubedb.dev/mysql-coordinator/pkg/coordinator/helper.go:193-234`

```go
func (c *Coordinator) restartMySQLProcess() {
    if mysqld responds AND node is NOT recovering {
        if tryRestartCount < maxRetry (10) {
            tryRestartCount++
            klog.Infoln("mysql process is not healthy, attempt N")
            return
        }
        if !exists("/scripts/auto-heal-off.txt") {
            SET GLOBAL read_only=ON         // fence writes
            "SHUTDOWN;"                      // this is the SHUTDOWN
            tryRestartCount = 1
        }
    }
}
```

**Translation:** if mysqld is up BUT the node isn't in GR (and not
actively recovering), the coordinator force-shuts-down mysqld after
~100s (10 polls × 10s) to trigger the init script's restart-and-rejoin
path. Useful for normal recovery; harmful when the init script is
blocked on a stuck cluster lock — it loops forever.

---

## Fix Applied to `run_innodb.sh`

**File:** `/home/arman/go/src/kubedb.dev/mysql-init-docker/scripts/run_innodb.sh`

### New helper: `clear_stale_cluster_lock()`

```bash
function clear_stale_cluster_lock() {
    local target_host=$1
    local mysql_root="mysql -u${MYSQL_ROOT_USERNAME} -h${target_host} -p${MYSQL_ROOT_PASSWORD} --port=3306 -N"
    local stuck_ids
    stuck_ids=$(${mysql_root} -e "
        SELECT t.PROCESSLIST_ID
        FROM performance_schema.metadata_locks m
        JOIN performance_schema.threads t ON m.OWNER_THREAD_ID = t.THREAD_ID
        WHERE m.OBJECT_SCHEMA='AdminAPI_cluster'
          AND m.OBJECT_NAME='AdminAPI_lock'
          AND m.LOCK_TYPE='EXCLUSIVE'
          AND t.PROCESSLIST_COMMAND='Sleep'
          AND t.PROCESSLIST_TIME > 5;" 2>/dev/null | awk 'NF')
    if [[ -n "$stuck_ids" ]]; then
        for stuck_id in $stuck_ids; do
            log "WARNING" "Killing stale AdminAPI_lock holder on ${target_host} (conn=${stuck_id}, Sleep>5s)"
            ${mysql_root} -e "KILL ${stuck_id};" 2>/dev/null
        done
        sleep 2
    fi
}
```

**Threshold rationale (5s):** legitimate in-flight AdminAPI operations
stay in `Query` state. A session holding `AdminAPI_lock` while in `Sleep`
= definitionally stuck. 5s is conservative enough to skip any transient
timing noise but tight enough to unblock retries (`retry 10` × 1s = 10s window).

### Preflight call-sites (all 8 AdminAPI operations)

| Function | Line | Operation |
|---|---|---|
| `is_already_in_cluster()` | 244 | `cluster.rescan()` |
| `join_in_cluster()` | 260 | `cluster.addInstance({recoveryMethod:'incremental'})` |
| `join_by_clone()` | 267 | `cluster.removeInstance({force:'true'})` |
| `join_by_clone()` | 269 | `cluster.addInstance({recoveryMethod:'clone'})` |
| `make_sure_instance_join_in_cluster()` | 292 | `cluster.rescan()` |
| `rejoin_in_cluster()` | 298 | `cluster.rejoinInstance(...)` |
| `rejoin_in_cluster()` cleanup | 313 | `cluster.removeInstance({force:'true'})` |
| `reboot_from_completeOutage()` | 340 | `cluster.rescan()` |

Pattern applied before each AdminAPI call:
```bash
clear_stale_cluster_lock "${primary}"
retry 10 ${mysqlshell} -e "cluster = dba.getCluster(); cluster.rescan()"
```

---

## Known Limitation of This Fix

`clear_stale_cluster_lock` runs **once** before the `retry 10` loop.
If a NEW stuck lock appears DURING the retry window (another pod's
mysqlsh dying mid-retry), the 10 attempts will still fail because
preflight doesn't run on each retry iteration.

**Mitigation in practice:** the 5s threshold + retry 10 (10s) means
any stuck lock becomes eligible by the next function call in the outer
loop. Workable but not airtight.

**Future hardening options:**
1. Make `retry` variant that calls preflight each iteration
2. Operator-side: sequential restart in `rotate_auth.go` (replace
   `RunParallel` with staggered restart: secondaries one-by-one, then
   primary last — waiting for ONLINE after each)
3. Skip rescan when local node is already ONLINE in GR (guard in
   `is_already_in_cluster` — check GR membership before calling rescan)

---

## Action Items

- [x] Add `clear_stale_cluster_lock` helper to `run_innodb.sh`
- [x] Wire preflight to all 8 AdminAPI call-sites
- [x] Tighten threshold 30s → 5s
- [ ] **Rebuild `mysql-init-docker` image** and push to registry
- [ ] **Redeploy cluster** with new init image tag
- [ ] Verify AuthSecret rotation completes cleanly (3-node rotation,
      confirm all pods rejoin, no stuck locks)
- [ ] Consider Fix #2: sequential restart in `rotate_auth.go` —
      replace `RunParallel` with staggered loop for InnoDB Cluster /
      Group Replication modes
- [ ] Consider Fix #3: membership-aware rescan guard in
      `is_already_in_cluster()`

---

## File References

| File | Purpose |
|---|---|
| `kubedb.dev/mysql-init-docker/scripts/run_innodb.sh` | Init script (fix applied) |
| `kubedb.dev/mysql/pkg/ops/rotate_auth.go` | Operator rotation flow (uses `RunParallel`) |
| `kubedb.dev/mysql-coordinator/pkg/coordinator/helper.go:193-234` | Force-shutdown recovery trigger |
| `kubedb.dev/mysql-coordinator/pkg/coordinator/queries.go:25` | `shutdownCommand = "shutdown;"` |
