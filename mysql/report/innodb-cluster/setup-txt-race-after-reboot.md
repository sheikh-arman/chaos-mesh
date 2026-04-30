# Race: `setup.txt` removed before GR is ONLINE after `rebootFromCompleteOutage`

## Symptom

After the coordinator triggers `rebootFromCompleteOutage()` for an InnoDB
Cluster, the `restartMySQLProcess()` skip-guard stops firing one iteration
later, and the coordinator begins counting "mysql process is not healthy"
attempts even though mysqld itself is reachable. From a sample log:

```
I0430 04:43:21.966977  mysql.go:482   all peers acknowledged bootstrap
I0430 04:43:21.966992  helper.go:248  skipping restart, setup file exists, mysqld setup is ongoing...
I0430 04:43:21.966996  helper.go:196  signal file does not exist, skipping mysql process restart.
I0430 04:43:21.967000  mysql.go:388   all peers acknowledged — this node will bootstrap the cluster
I0430 04:43:21.967989  mysql.go:394   cluster rebooting from complete outage
…
E0430 04:43:31.974929  mode-detector.go:55  error querying performance schema query result is nil
E0430 04:43:31.983751  mysql.go:703   unable to query group members: query result is nil
E0430 04:43:32.269742  mysql.go:744   unable to query group members to check recovering state, err: query result is nil
I0430 04:43:32.269756  helper.go:209  mysql process is not healthy, need at-least 2 attempt to restart mysql... attempt: 1
I0430 04:43:42.559525  helper.go:209  mysql process is not healthy, need at-least 2 attempt to restart mysql... attempt: 2
```

The user's question on seeing this is reasonable: line 196 fired at
`04:43:21.966996` (early return), so how does line 209 fire at
`04:43:32.269756`? The function was supposed to return.

## Root cause

`restartMySQLProcess()` has only one early-return path:

```go
// pkg/coordinator/helper.go
func (c *Coordinator) restartMySQLProcess() {
    if !c.signalFileExists() && c.setupFileExists() {
        klog.Infoln("signal file does not exist, skipping mysql process restart.")
        return
    }
    …
}
```

The skip fires only when both:

- `signal.txt` is absent (no operation pending), **and**
- `setup.txt` is present (init script is mid-setup).

`setup.txt` is created and deleted by the init scripts:

```bash
# kubedb.dev/mysql-init-docker/scripts/run_innodb.sh
echo "running" > /scripts/setup.txt   # line 439 — start of setup
…
rm -rf /scripts/setup.txt              # line 506 — end of setup
```

Same pattern in `run.sh` (lines 21 / 610 create, line 647 deletes).

When the coordinator calls `rebootFromCompleteOutage()`, the init script
does its reboot work and then runs `rm -rf /scripts/setup.txt`. The
coordinator's next loop iteration sees:

| | Value |
|---|---|
| `signalFileExists()` | `false` |
| `setupFileExists()` | `false` ← just removed |
| skip condition `!false && false` | **`false`** — does **not** return |

So the function falls through past the early return. Then:

```go
if result, _ := c.queryInDatabase(c.curPodMeta, selectOne); result != nil {
    if c.curNodeRecovering() { … }
    if c.tryRestartCount < maxRetry {
        c.tryRestartCount++
        klog.Infoln("mysql process is not healthy, need at-least ", maxRetry, " attempt to restart mysql... attempt: ", c.tryRestartCount)
        return
    }
    …
}
```

`selectOne` (`SELECT 1`) succeeds because mysqld accepts connections. But
the wider coordinator state checks — `mode-detector` querying
`performance_schema.replication_group_members`, `mysql.go:703` /
`mysql.go:744` querying group state — all return `query result is nil`
because Group Replication is not yet reporting through performance_schema
on this node (still completing post-reboot recovery). The coordinator
interprets this as "mysqld unhealthy" and starts the retry counter.

## Reconstructed timeline

```
T=04:43:21.96 | setup.txt present, signal.txt absent
              | helper.go:196   "signal file does not exist, skipping"  ← early return
              | mysql.go:388    "all peers acknowledged — this node will bootstrap"
              | mysql.go:390    rebootFromCompleteOutage()
              | mysql.go:394    "cluster rebooting from complete outage"
              |
              | [run_innodb.sh runs reboot logic, finishes setup, then:]
              |   run_innodb.sh:506   rm -rf /scripts/setup.txt   ← deleted
              |
T=04:43:31    | next coordinator loop
              |   signalFileExists()  == false
              |   setupFileExists()   == false   ← gone
              |   skip condition       == false  ← does NOT return
              |
              | mysqld up (selectOne ok), but GR not yet ONLINE
              |   → tryRestartCount < maxRetry branch
T=04:43:32.27 | helper.go:209   "attempt: 1"
T=04:43:42.56 | helper.go:209   "attempt: 2"
              | (next iteration would proceed to actual shutdown if still
              |  unhealthy)
```

## Why this matters

The retry counter is harmless on its own (it just emits two warning lines
before triggering an actual restart), but on a slow recovery path it can
cause the coordinator to shut mysqld down again *while* GR is still
catching up — extending the outage instead of waiting for normal recovery.

This shows up most often after:

- `rebootFromCompleteOutage()` (this report's case)
- `clone` recovery, where mysqld is up but cloned data is still being
  applied
- network-partition recovery on a slower node, where GR's distributed
  recovery hasn't yet caught up

## Fix options

Two reasonable directions, not exclusive.

### Option 1 — Delay `rm -rf /scripts/setup.txt` until GR is ONLINE

In `run_innodb.sh` (and the equivalent block in `run.sh`), keep
`setup.txt` on disk until this node is verified `ONLINE` in
`performance_schema.replication_group_members` (or until the AdminAPI
`dba.getCluster()` reports this instance ONLINE). Pseudocode:

```bash
# After the existing setup work succeeds, before deleting setup.txt:
for i in $(seq 1 60); do
    state=$(${mysql} -N -e "
        SELECT MEMBER_STATE FROM performance_schema.replication_group_members
        WHERE MEMBER_HOST='${report_host}'" 2>/dev/null)
    [ "$state" = "ONLINE" ] && break
    sleep 5
done

rm -rf /scripts/setup.txt
log "INFO" "removing setup.txt file"
```

Pros: surgical, keeps the existing skip semantics intact, no coordinator
change needed.

Cons: if GR genuinely cannot reach ONLINE (real recovery failure), the
init script will hold setup.txt forever and the coordinator won't ever
intervene. Need an upper bound and a clear failure path.

### Option 2 — Make `restartMySQLProcess()` distinguish "GR not yet ready" from "mysqld unhealthy"

`selectOne` succeeding while group-membership queries return nil is the
fingerprint of "mysqld up, GR not yet ONLINE." Add a third early-return
branch in `restartMySQLProcess()`:

```go
if result, _ := c.queryInDatabase(c.curPodMeta, selectOne); result != nil {
    // mysqld is reachable. Check whether GR is in the middle of
    // initializing — replication_group_members empty / nil means GR
    // hasn't started up yet, which is normal during reboot/clone recovery
    // and not a "mysqld unhealthy" signal.
    if grEmpty, err := c.groupReplicationNotYetReady(); err == nil && grEmpty {
        klog.Infof("mysqld up but GR not yet ONLINE on this node; deferring restart")
        return
    }

    if c.curNodeRecovering() { … }
    if c.tryRestartCount < maxRetry { … }
    …
}
```

Pros: works for any recovery path where mysqld is up but GR is mid-init
(reboot, clone, partition recovery), not just the post-reboot case.

Cons: needs care in `groupReplicationNotYetReady()` — must not mask a
genuinely broken member. The check should be "no membership info at all"
(empty `replication_group_members` query), not "this node not ONLINE"
(which is the legitimate unhealthy case after a real failure).

## Recommendation

Apply **both**:

1. Option 1 in `run_innodb.sh` — close the obvious window cheaply.
2. Option 2 in `restartMySQLProcess()` — handle the residual race for
   other recovery paths (clone, partition recovery, etc.) that don't go
   through `setup.txt`.

## References

- `mysql-coordinator/pkg/coordinator/helper.go:194` —
  `restartMySQLProcess()` and the skip guard
- `mysql-coordinator/pkg/coordinator/helper.go:240` —
  `signalFileExists()`
- `mysql-coordinator/pkg/coordinator/helper.go:248` —
  `setupFileExists()`
- `mysql-coordinator/pkg/coordinator/mysql.go:388-394` —
  bootstrap path that calls `rebootFromCompleteOutage()`
- `mysql-init-docker/scripts/run_innodb.sh:439, 506` —
  `setup.txt` create/delete (InnoDB Cluster)
- `mysql-init-docker/scripts/run.sh:21, 610, 647` —
  `setup.txt` create/delete (Group Replication)
