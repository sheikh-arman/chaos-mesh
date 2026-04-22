# KubeDB MariaDB 11.8.5 — Defect Hunt (MariaDBReplication)

**Started:** 2026-04-21
**Target:** `kubedb.com/v1/MariaDB` in `MariaDBReplication` topology (1 Master + 2 Slaves + MaxScale x3)
**Version under test:** MariaDB 11.8.5, KubeDB v2026.2.26
**Focus:** *Find* issues with KubeDB MariaDB — no fixes applied during the hunt.

---

## Cluster Info

| Component | Value |
|---|---|
| MariaDB CR | `md` in namespace `demo` |
| Topology | MariaDBReplication (1 Master + 2 Slaves) |
| Pods | `md-0` Slave, `md-1` Slave, `md-2` Master, `md-mx-0/1/2` MaxScale |
| Proxy | MaxScale, service `md-mx:3306` |
| Storage | 2Gi PVC per node (`data-md-0/1/2`) |
| Sysbench | `sysbench-load-*` pod |
| Auth secret | `md-auth` |

---

## Defects Found

_Table updated as defects are discovered._

| # | Test | Defect | Severity | Reproducer |
|---|---|---|---|---|
| 1 | Test 12/13 — IOChaos `fault` (EIO 50%) on any MariaDB pod (Master **or** Slave) | After chaos clears, affected pod gets stuck with `mariadbd` process dead but init script (`run-on-present.sh`) only running a `sleep 1` loop + a ping loop waiting for mariadb to come up. mariadb is NEVER restarted automatically — `ps -ef` shows tini → std-replication-run.sh → std-replication-on-start.sh → run-on-present.sh (the old handle) but no `mariadbd`. Coordinator log stuck in `Pinging MariaDB server, attempt N` indefinitely. MariaDB CR stays `Critical`, pod role label becomes `Down`. Recovery requires pod delete (manual intervention) or ≥15 min timeout before the init-script 900-attempt loop gives up. **Reproduces on both Master and Slave** — role-independent. | **High** | 1. Run IOChaos action=fault errno=5 percent=50 on kubedb.com/role=Master OR Slave, duration 2m 2. After chaos clears, `kubectl exec <pod> -c mariadb -- ps -ef` shows no mariadbd 3. MariaDB CR remains `Critical` with role=Down on affected pod |
| 2 | Test 15 — IOChaos `mistake` (random data corruption 50%) on Master | After chaos clears, **replication is permanently broken on both slaves** with `Slave_IO_Running: No`, `Last_IO_Error: Relay log write failure: could not queue event from master`. All 4 sysbench table checksums permanently diverge between master (md-0) and slaves (md-1/md-2). KubeDB marks both slave roles as `Unknown` but does not auto-repair replication — slaves indefinitely serve stale reads via MaxScale while master has the newest data. No events emitted on the MariaDB CR or PetSet beyond the role label change. Requires operator to manually `STOP SLAVE; RESET MASTER/SLAVE; CHANGE MASTER` (or delete+rebuild slaves) to recover. | **Critical** — silent stale-reads + manual recovery | 1. Apply IOChaos action=mistake filling=random maxOccurrences=10 maxLength=100 percent=50 on kubedb.com/role=Master 2m 2. After chaos clears: `SHOW SLAVE STATUS\G` on any slave shows `Slave_IO_Running: No`, `Last_IO_Error: Relay log write failure...` 3. `CHECKSUM TABLE sbtest.sbtest1` returns different values across master vs slaves 4. Cluster shown `Ready` by KubeDB operator despite broken replication; slaves labeled `Unknown` |
| 3 | Follow-up during recovery | When master runs with `innodb_force_recovery > 0` (used for legitimate undo-corruption rescue), `mariadb-backup` refuses to run (`"innodb_force_recovery should only be used with --prepare"`). KubeDB's backup-stream flow doesn't detect this: master silently fails to stream, joiner cycles through 3 retries + container restart loop, no event, cluster stays Critical with no clear reason surfaced. Operator has to read joiner logs to figure out the cause. | **Medium** — surfaces only during corruption recovery but compounds operator confusion | 1. Set `innodb_force_recovery=5` on master in mariadbd args 2. Scale cluster or force a slave rebuild 3. Joiner loops forever with "datadir lacks mariabackup artifacts" while master coordinator silently fails |

### Defect #1 — detailed evidence

**File:** `/home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb/report/defect-hunt-yamls/t12-io-fault-master.yaml`

Process tree inside md-1 (`mariadb` container) after chaos cleared:
```
mysql          1       0  0 Apr21 ?        00:00:00 /scripts/tini -g -- /scripts/std-replication-run.sh
mysql         14       1  0 Apr21 ?        00:00:00 bash /scripts/std-replication-run.sh
mysql         20      14  0 Apr21 ?        00:00:00 bash ./scripts/std-replication-on-start.sh
mysql        120      20  0 Apr21 ?        00:00:00 bash ./run-script/run-on-present.sh
# no mariadbd
```

Container logs (init script):
```
Attempt 735: Pinging 'md-1.md-pods.demo.svc' has returned: ''
Attempt 734: Pinging 'md-1.md-pods.demo.svc' has returned: ''
... (counter decrements from ~900 to 0 before giving up)
```

md-coordinator log (stuck waiting too):
```
mariadb.go:1103] Pinging MariaDB server, attempt 1
mariadb.go:1103] Pinging MariaDB server, attempt 2
... 9, 10, ...
```

Kubernetes view:
- Pod: `Running 2/2 Ready` (false-positive — tini is PID 1, always alive)
- Last container state: `Terminated Error Exit Code 137`, Restart Count 2 (from the actual OOM-kill or similar during chaos)
- Container `State: Running` (the RE-started container — but the script inside it never recovers mariadbd)
- MariaDB CR: `Critical` (cluster-level visible problem)
- Role label on md-1: `Down` (KubeDB correctly identifies it's dead, but doesn't auto-recover)

**Impact:** a real-world I/O glitch on the master would leave the master offline for up to 15 minutes before the init-script timeout forces pod restart.

---

### Defect #2 — detailed evidence

**File:** `/home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb/report/defect-hunt-yamls/t15-io-mistake.yaml`

**Broken `SHOW SLAVE STATUS` on both slaves after chaos cleared:**
```
Master_Host: md-0.md-pods.demo.svc.cluster.local
Slave_IO_Running: No
Slave_SQL_Running: Yes
Seconds_Behind_Master: NULL
Last_IO_Error: Got fatal error 1236 from master when reading data from binary log:
  'log event entry exceeded max_allowed_packet; Increase max_allowed_packet on master;
   the first event '.' at 4,
   the last event read from 'mariadb-bin.000006' at 283652762,
   the last byte read from 'mariadb-bin.000006' at 283652781.'
```

**Binlog corruption visible on master — `mariadb-binlog` fails to parse past the corrupted offset:**
```
$ mariadb-binlog --start-position=283652700 mariadb-bin.000006
...
# Warning: this binlog is either in use or was not closed properly.
ROLLBACK/*!*/;
BINLOG '...'/*!*/;
ERROR: Error in Log_event::read_log_event(): 'Found invalid event in binary log',
       data_len: 12210, event_type: 232
DELIMITER ;
# End of log file
```

**What the chaos actually corrupted:** IOChaos with `action=mistake, filling=random, percent=50` wrote random bytes into files under `/var/lib/mysql/**/*` on master. The binary log file `mariadb-bin.000006` was hit around offset 283 652 762. The `event_type: 232` shown above is garbage — valid MariaDB binlog event types top out near ~165. The `data_len: 12210` is also random noise which triggers the downstream slaves' `max_allowed_packet` error.

**Checksum divergence across all 4 sysbench tables (evidence of permanent drift):**
```
md-0 (Master):   sbtest1=3516987802  sbtest2=3705067580  sbtest3=4286005503  sbtest4=2381007598
md-1 (Slave):    sbtest1=4204010318  sbtest2=2087776634  sbtest3=3308655002  sbtest4=1826698280
md-2 (Slave):    sbtest1=4204010318  sbtest2=2087776634  sbtest3=3308655002  sbtest4=1826698280
```
Slaves match each other (both stopped at the same binlog position) but both differ from master — master accepted more writes after the corruption point that slaves could never replay.

### Later observation: corruption is deeper than just the binlog

After rebuilding slaves and reaching a state where md-0 was attempting to bootstrap as the new master, md-0's mariadbd refused to start with:

```
2026-04-22 05:27:16 0 [ERROR] InnoDB: Failed to read page 3 from file './/undo003':
                              Page read from tablespace is corrupted.
```

This means IOChaos `mistake` also wrote random bytes into **InnoDB undo tablespace (`undo003`)** — not only binlog files. Once mariadbd crashes on this, the init script's ping loop (Defect #1) runs indefinitely and the cluster becomes completely unrecoverable without external backup:

| Pod | End state | Why |
|---|---|---|
| md-0 (original master) | Stuck Defect #1 ping loop | `undo003` corrupt — mariadbd can't start |
| md-1 (rebuilt slave) | Down | Waiting for a master that will never come online |
| md-2 (rebuilt slave) | Unknown | Same |

Coordinator log showed it detected the stuck state and tried to recover (`mysqld process is not running, restarting the coordinator` → re-entered flow → `bootstrapping new cluster`), but each recovery attempt hits the same corrupt `undo003` and stalls again.

Impact escalation: **IOChaos mistake on the master can leave the entire cluster unrecoverable without external backup**. Matches SoftBank's "Fault解消後も復旧せず" observation.

Full error (the critical lines):
```
[ERROR] InnoDB: Failed to read page 3 from file './/undo003': Page read from tablespace is corrupted.
[ERROR] InnoDB: File './/undo003' is corrupted
[Note]  InnoDB: Retry with innodb_force_recovery=5     ← MariaDB's own hint
[ERROR] Plugin 'InnoDB' registration as a STORAGE ENGINE failed.
[ERROR] Unknown/unsupported storage engine: InnoDB
[ERROR] Aborting
```

**Recovery procedures (operator has to do manually — no auto-recovery in KubeDB):**
1. `innodb_force_recovery=5` + dump + reload into fresh datadir (lossy, for data extraction)
2. Rebuild pod from a healthy peer via backup-stream (only if a clean peer exists)
3. Restore from external `mariadb-backup` snapshot (only if one was taken pre-chaos)
4. `kubectl delete mariadb` + recreate (accepts full data loss)

### Follow-up defect found mid-recovery — **Defect #3**

When the master is running with `innodb_force_recovery > 0` (a legitimate transient state during corruption recovery per Option 1 above), mariadb-backup refuses to run:

```
mariabackup: The option "innodb_force_recovery" should only be used with "--prepare".
mariabackup: innodb_init_param(): Error occurred.
```

But KubeDB's backup-stream flow doesn't detect this:
- Master-side `backup-stream.sh` exits non-zero without sending any bytes.
- Joiner-side `socat` receives nothing → `mbstream -x` extracts nothing.
- Joiner's own post-check (xtrabackup_checkpoints / ibdata1 absent) correctly flags "treating as failure" — but only after running through all 3 retries (~4–6 minutes).
- Container then restarts via kubelet (because our `exit 1` after max retries is in place).
- Loop forever.

No alert, no Event on the MariaDB CR, no aggregation of "master can't serve mariadb-backup". Operator only knows by reading the joiner logs.

**Suggested KubeDB-level fix:** master-side `ensureBackupStream()` in the coordinator should:
- Check master's `@@innodb_force_recovery` before running backup-stream.sh
- If > 0, emit a Kubernetes Event on the MariaDB CR (`MasterNotBackupCapable`) and set cluster phase Critical with a human-readable reason.

**Why this is a KubeDB defect, not just a MariaDB limitation:**
- Master continues to serve writes fine (only the binlog file was corrupted, InnoDB pages are still good enough).
- Slaves can never advance past the corrupted binlog event — their IO thread is permanently halted.
- **MariaDB CR flipped back to `Ready`** after the role detector saw mariadb responding — but replication is still broken under the hood.
- Slave role label became `Unknown` — the coordinator detected the anomaly — **but nothing auto-repairs the replication stream**.
- Reads via MaxScale may route to the stale slaves, producing silent stale-data responses with **no user-visible alarm** beyond the role label.
- Pod delete alone does not fix this: after md-1/md-2 were `kubectl delete pod`-ed, they came back with their existing PVCs and the same broken IO position; they still hit the same corrupted offset and the same `fatal error 1236`.

---

## Test Plan (revised — pure chaos only)

OpsRequest tests deferred. This pass focuses on Chaos-Mesh-style fault injection only.

### Pod / container chaos
1. Pod Kill — Master (`md-2`)
2. Pod Kill — Slave (`md-1`)
3. Pod Kill — MaxScale (`md-mx-0`)
4. Container Kill — `mariadb` container only (master)
5. Pod Failure (5 min pause) — Master

### Stress chaos
6. Memory stress (OOMKill 1200MB) — Master
7. Memory stress — Slave
8. CPU stress 98% — Master
9. Combined Memory + CPU stress — Master

### IO chaos
10. IO Latency (100ms) — Master
11. IO Latency (100ms) — Slave
12. IO Fault (EIO 50%) — Master
13. IO Fault (EIO 50%) — Slave
14. IO Attr Override (read-only datadir, 5m) — Master
15. IO Mistake (random data corruption) — Master

### Network chaos
16. Network Partition (Master ↔ Slaves, 2m)
17. Network Partition (Slave isolated from cluster)
18. Network Partition (MaxScale ↔ MariaDB)
19. Network Latency (1s between nodes)
20. Network Packet Loss (30%)
21. Network Packet Duplicate (50%)
22. Network Packet Corrupt (50%)
23. Network Bandwidth Throttle (1 Mbps) — Master

### Time / DNS
24. DNS Error on Master
25. Clock Skew (-5 min) on Master

### Full cluster
26. Full MariaDB cluster kill (all 3 pods)
27. Full MaxScale kill (all 3 MaxScale pods)
28. Compound: Master + MaxScale kill simultaneously

### Rolling
29. Rolling restart (delete md-0 → md-1 → md-2 with 40s gap)

---

## Test Log

### Test 0 — Baseline sanity
**Setup:** reset `sbtest` DB (only `testdb` existed pre-test), prepared sysbench 4 tables × 50k rows, created `chaos_track.markers` tracking table. Initial state: md-2 Master, md-0/md-1 Slaves, all `Slave_IO_Running=Yes, SQL_Running=Yes, Seconds_Behind_Master=0`.
**Baseline TPS:** 949 (15s run, 4 threads, via MaxScale `md-mx:3306`), 19k QPS, 0 errors.
**Defect found:** none.

### Tests 1–11 summary (all PASS, no defects)

| # | Test | TPS during | Behavior |
|---|---|---|---|
| 1 | Pod Kill Master (md-2) | 1043 | Failover md-2→md-0, killed pod rejoined as Slave, 0 reconnects |
| 2 | Pod Kill Slave | 1125 | Slave killed+recreated, no write impact |
| 3B | Pod Kill MaxScale | 898 | md-mx-0 restarted 1x, MaxScale service kept routing via remaining 2 pods (note: Test 3A had label-selector bug; retry with `app.kubernetes.io/instance=md-mx` worked) |
| 4 | Container Kill — mariadb on Master | N/A (sysbench dropped) | Failover md-0→md-1, reconnects worked, recovered in ~30s |
| 5 | Pod Failure 90s on Master | 750–1127 range | master frozen, kubelet killed container 4× during freeze (restart count 4 on md-1), failover completed, sysbench dipped but recovered |
| 6 | Memory stress 1400MB on Master | 775–950 range | OOMKilled, failover md-0→md-1, rejoined as Slave |
| 7 | Memory stress 1400MB on Slave | 1138 | Slave OOMKilled — zero write impact (writes only go to master via MaxScale) |
| 8 | CPU 98% stress on Master | 867–950 | No failover, degraded but stable |
| 9 | Combined Memory+CPU on Master | 749–958 | No restart, survived combined stress |
| 10 | IO Latency 100ms on Master | **5** TPS | Severe write throttle (master disk-bound) but no failover, 0 errors |
| 11 | IO Latency 100ms on Slave | 1131 | Slave disk-bound read degraded but writes unaffected |

### Test 12 — IOChaos `fault` (EIO 50%) on Master — **DEFECT FOUND** (see table above)

### Tests 13–29 (after cluster rebuild, Round 2)

| # | Test | TPS | Behavior |
|---|---|---|---|
| 13 | IO fault slave — **DEFECT #1 repro** | N/A | Same stuck pattern — see Defect #1 |
| 14 | IO attrOverride (r/o datadir) on master | 656 | Degraded, no crash, recovered |
| 15 | IO mistake (random corruption 50%) — **DEFECT #2 + escalation** | N/A | Permanent binlog + InnoDB undo corruption; cluster unrecoverable → rebuild required |
| — | *Cluster rebuilt fresh after T15* | — | — |
| 16 | NetworkPartition Master↔Slaves 90s | 1122 | No failover (async replication), 0 reconnects |
| 17 | NetworkPartition Slave isolated 90s | 964 | No write impact |
| 18 | NetworkPartition MaxScale↔MariaDB 60s | 0 during / 955 after | Sysbench lost conn as expected, full recovery after chaos |
| 19 | Network latency 1s master↔slaves | 1148 | **Zero impact** — confirms async replication shrugs off this test (contrasts with Galera where same test tanks TPS to ~3) |
| 20 | Packet loss 30% master↔slaves | 954 | No write impact |
| 21 | Packet duplicate 50% | 948 | No impact |
| 22 | Packet corrupt 50% | 1156 | No impact (contrasts with Galera — 50% corrupt kills Galera entirely) |
| 23 | Bandwidth 1mbps master | 21 | TPS -97%, 0 errors, fully stable |
| 24 | DNS error master | 956 | No impact |
| 25 | Clock skew -5m master | 879 | Minor dip |
| 26 | Full MariaDB cluster kill (3 pods) | N/A | Recovery ~75s, 12/12 markers preserved |
| 27 | Full MaxScale kill (3 pods) | N/A | Recovery ~3min (client outage throughout), 955 TPS after |
| 28 | Compound: master+all MaxScale kill | N/A | Recovery ~90s, md-0 re-elected Master, 14/14 markers |
| 29 | Rolling restart 0→1→2 (rapid) | N/A | All 3 briefly showed role=Down during rapid sequence; recovered to Master+2×Slave in ~2m30s, 15/15 markers. Ran pods too fast — kubelet didn't have time to settle between deletes; operator still recovered correctly |

## Final verdict

**Tests run:** 29 chaos experiments on MariaDBReplication + MaxScale topology (MariaDB 11.8.5, KubeDB v2026.2.26).
**Defects discovered:** 3 (listed in Defects Found table at top of report).

**By-category summary:**
- **Pod / container chaos (T1–T5):** 5/5 pass — robust failover via MaxScale.
- **Stress chaos (T6–T9):** 4/4 pass — OOMKill recovery works, CPU stress transparent.
- **IO latency chaos (T10–T11):** 2/2 pass — graceful degradation.
- **IO fault/corruption chaos (T12–T15):** **2/4 FAIL** — IO faults leave pods stuck, and IO data corruption on master irreversibly damages both binlogs AND InnoDB undo tablespace with no auto-recovery.
- **Network chaos (T16–T23):** 8/8 pass — async replication shrugs off latency/loss/corrupt.
- **DNS/clock (T24–T25):** 2/2 pass.
- **Full-cluster / compound / rolling (T26–T29):** 4/4 pass — self-heal within 1–3 min.

**Overall:** 26/29 pass, 3 defects identified (all in IO-chaos category and immediate recovery paths).

### Test 1 — Pod Kill Master (`md-2`)
**Chaos:** `PodChaos action=pod-kill mode=one labelSelector{kubedb.com/role=Master}`, gracePeriod=0.
**Expected:** Master killed → failover to a Slave → MaxScale re-routes → killed pod recreated as Slave → cluster `Ready`, zero data loss.
**Observed:**
- Sysbench uninterrupted: **1043 TPS** (actually higher than baseline, no reconnects, 4 ignored errors).
- Failover md-2 → md-0 completed. md-0 became Master, md-1/md-2 Slaves replicating from md-0.
- All 3 nodes: 2/2 markers preserved, checksums identical (`sbtest1=535950349` across all).
- MariaDB CR stayed `Ready` throughout (never went `Critical` or `NotReady` — maxscale kept serving).
**Defect found:** none.

---
