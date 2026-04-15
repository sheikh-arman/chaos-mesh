# InnoDB Cluster: Reboot from Complete Outage — Fix for GR ERROR State

**Date:** 2026-04-15
**Affected:** MySQL 8.4.x and 9.6.0 InnoDB Cluster
**Branch:** Both `innodb-support` (8.4.x) and 9.6.0 branch

---

## The Issue

After a complete cluster outage (e.g., all 3 pods restarted, OOMKill, error 3100 from large transactions), the coordinator detects the outage and elects a bootstrap candidate. It sends the `reboot_from_complete_outage` signal to pod-0 (the pod with the most GTID transactions).

Pod-0's `run_innodb.sh` calls:
```javascript
dba.rebootClusterFromCompleteOutage('mysql_ha_cluster', {force: true})
```

But this fails with:
```
Dba.rebootClusterFromCompleteOutage: The MySQL instance 'mysql-ha-cluster-2:3306'
belongs to a GR group that is not managed as an InnoDB Cluster. (RuntimeError)
```

## Root Cause

When GR enters an ERROR state (e.g., from error 3100 — transaction too large, OOMKill, network issues), the `group_replication` plugin stays loaded and the member remains in `ERROR` state. It does NOT automatically transition to `OFFLINE`.

```sql
-- Pod-2 stuck in ERROR state:
SELECT MEMBER_STATE FROM performance_schema.replication_group_members;
-- Returns: ERROR
```

MySQL Shell's `dba.rebootClusterFromCompleteOutage()` checks all peers in the cluster metadata. If any peer has GR in a non-OFFLINE state (including ERROR), mysqlsh considers it part of an "active but unmanaged" GR group and refuses to proceed.

**Expected peer states for reboot to work:**
- `OFFLINE` — GR stopped, ready for reboot
- No GR running — standalone instance

**States that block reboot:**
- `ERROR` — GR plugin active but failed
- `UNREACHABLE` — GR plugin active but lost quorum

## How We Fixed It (Manual)

1. Stopped GR on the ERROR-state pod:
```sql
-- On pod-2:
STOP GROUP_REPLICATION;
```

2. Restarted pod-0 to give it a fresh signal:
```bash
kubectl delete pod -n demo mysql-ha-cluster-0
```

3. The coordinator re-sent `reboot_from_complete_outage` to pod-0, and this time `dba.rebootClusterFromCompleteOutage()` succeeded because all peers were in OFFLINE state.

## Automated Fix (Script Change)

**File:** `run_innodb.sh` — `reboot_from_completeOutage()` function

**Change:** Before calling `dba.rebootClusterFromCompleteOutage()`, iterate through all peers and stop GR on any that are in ERROR state.

```bash
function reboot_from_completeOutage() {
    ...
    # Stop GR on any peer stuck in ERROR state
    for host in "${peers[@]}"; do
        peer_state=$(mysql -u${MYSQL_ROOT_USERNAME} -h${host} \
            -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
            "SELECT MEMBER_STATE FROM performance_schema.replication_group_members LIMIT 1;" 2>/dev/null)
        if [[ "$peer_state" == "ERROR" ]]; then
            log "INFO" "Stopping GR on $host (stuck in ERROR state)..."
            mysql -u${MYSQL_ROOT_USERNAME} -h${host} \
                -p${MYSQL_ROOT_PASSWORD} --port=3306 -N -e \
                "STOP GROUP_REPLICATION;" 2>/dev/null
        fi
    done

    # Now reboot proceeds with all peers in OFFLINE state
    ${mysql_local} -N -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
    yes | $mysqlsh_self -e "dba.rebootClusterFromCompleteOutage('$clusterName',{force:true})"
    ...
}
```

## What Triggers This Scenario

| Trigger | How GR Enters ERROR State |
|---|---|
| Error 3100 (transaction too large) | Write-set exceeds `group_replication_transaction_size_limit` (default 150MB) |
| OOMKill during replication | Applier thread killed mid-transaction |
| Network partition timeout | Member expelled, can't reconnect |
| Disk full / IO errors | InnoDB can't write redo log |

## Changes Needed

### 1. `run_innodb.sh` (BOTH branches)

Already applied. The `reboot_from_completeOutage()` function now stops GR on ERROR-state peers before calling `dba.rebootClusterFromCompleteOutage()`.

### 2. Coordinator (`mysql-coordinator`) — No Changes Needed

The coordinator correctly:
- Detects the complete outage (no primary found after 3 retries)
- Compares GTIDs across all pods
- Elects the pod with the highest GTID as bootstrap candidate
- Sends `reboot_from_complete_outage` signal
- Retries up to 10 times if the init script hasn't processed the signal

The coordinator does NOT need to know about the GR ERROR state — the init script handles it.

### 3. Prevention

To reduce the chance of error 3100 causing cluster-wide outage:

```sql
-- Increase transaction size limit (default 150MB → 512MB)
SET PERSIST group_replication_transaction_size_limit = 536870912;

-- Increase redo log capacity if seeing checkpointer warnings
SET PERSIST innodb_redo_log_capacity = 536870912;
```

These can be added to the `custom.conf` ConfigMap or set in the MySQL CR's configuration.

## Test Verification

After the fix:
1. All 3 pods came back ONLINE as PRIMARY (Multi-Primary mode)
2. Cluster status: `Ready`
3. All GTIDs matched across pods
4. Data integrity preserved — no data loss
