# Slave IO Thread Fix — max_allowed_packet Exceeded in Binlog

**Date:** 2026-04-17
**Topology:** MariaDB Replication (1 Master + 2 Slaves) + MaxScale
**Version:** MariaDB 11.8.5

---

## The Problem

After running 18 chaos experiments, MaxScale showed md-0 and md-2 as `Running` instead of `Slave, Running`:

```
┌─────────┬─────────────────────────────────────┬──────┬─────────────────┬────────────┐
│ Server  │ Address                             │ Port │ State           │ GTID       │
├─────────┼─────────────────────────────────────┼──────┼─────────────────┼────────────┤
│ server1 │ md-0.md-pods.demo.svc.cluster.local │ 3306 │ Running         │ 0-2-202551 │
│ server2 │ md-1.md-pods.demo.svc.cluster.local │ 3306 │ Master, Running │ 0-2-217013 │
│ server3 │ md-2.md-pods.demo.svc.cluster.local │ 3306 │ Running         │ 0-2-202551 │
└─────────┴─────────────────────────────────────┴──────┴─────────────────┴────────────┘
```

md-0 and md-2 were ~14,000 transactions behind the Master (GTID `0-2-202551` vs `0-2-217013`).

## Root Cause

Checking `SHOW SLAVE STATUS` on the stuck nodes:

```
Slave_IO_Running: No
Slave_SQL_Running: Yes
Seconds_Behind_Master: NULL
Last_IO_Error: Got fatal error 1236 from master when reading data from binary log:
  'log event entry exceeded max_allowed_packet; Increase max_allowed_packet on master;
   the first event 'mariadb-bin.000004' at 61938064, the last event read from
   'mariadb-bin.000004' at 61977407, the last byte read from 'mariadb-bin.000004'
   at 61977426.'
```

**What happened:**

1. During the chaos experiments (particularly IO fault, IO mistake, and sysbench load), some large transactions were written to the Master's binary log (`mariadb-bin.000004`).
2. These binlog events exceeded the default `max_allowed_packet` size of **16MB** (`16777216` bytes).
3. When md-0 and md-2 were restarted during chaos (pod kills, container kills, IO faults), their Slave IO threads attempted to reconnect and read from the binlog.
4. The Master's binlog dump thread tried to send these oversized events but they exceeded `max_allowed_packet`, causing error `1236`.
5. The Slave IO thread stopped (`Slave_IO_Running: No`), but the SQL thread continued (`Slave_SQL_Running: Yes`) — it had already applied all events in the relay log.
6. With no IO thread, the slaves couldn't fetch new events, so they fell behind.

**Why `max_allowed_packet` was the problem:**

MariaDB's binlog dump thread (on the Master) uses `max_allowed_packet` to limit the size of events it sends to slaves. The default 16MB was insufficient for the large write-set events generated during chaos testing under sysbench load.

## Fix Applied

### Step 1: Increase max_allowed_packet on all nodes

```sql
-- On all 3 nodes (md-0, md-1, md-2):
SET GLOBAL max_allowed_packet = 67108864;  -- 64MB
SET GLOBAL slave_max_allowed_packet = 67108864;  -- 64MB
```

This alone didn't fix it because the Master's binlog dump thread was already started with the old value.

### Step 2: Skip past the problematic binlog events

Tried `CHANGE MASTER TO ... MASTER_LOG_POS=<new_position>` to skip the oversized events. This didn't work because there were **multiple** oversized events scattered throughout `mariadb-bin.000004`.

### Step 3: Flush binary logs on the Master (the actual fix)

```sql
-- On the Master (md-1):
FLUSH BINARY LOGS;
```

This created a new binlog file (`mariadb-bin.000005`) starting fresh. The key insight: **the problematic oversized events were only in the old binlog file** (`mariadb-bin.000004`). By rotating to a new file, the slaves could connect and start reading from a clean binlog.

### Step 4: Restart slave threads

```sql
-- On md-0 and md-2:
STOP SLAVE;
START SLAVE;
```

The slaves reconnected using GTID-based replication (`MASTER_USE_GTID=current_pos`), found the new binlog file, and caught up instantly since their GTID was already close to the Master's position.

## Result After Fix

```
┌─────────┬─────────────────────────────────────┬──────┬─────────────────┬────────────┐
│ Server  │ Address                             │ Port │ State           │ GTID       │
├─────────┼─────────────────────────────────────┼──────┼─────────────────┼────────────┤
│ server1 │ md-0.md-pods.demo.svc.cluster.local │ 3306 │ Slave, Running  │ 0-2-217017 │
│ server2 │ md-1.md-pods.demo.svc.cluster.local │ 3306 │ Master, Running │ 0-2-217017 │
│ server3 │ md-2.md-pods.demo.svc.cluster.local │ 3306 │ Slave, Running  │ 0-2-217017 │
└─────────┴─────────────────────────────────────┴──────┴─────────────────┴────────────┘
```

All GTIDs match (`0-2-217017`), all slaves `Slave, Running`, `Seconds_Behind_Master: 0`.

## Prevention

To prevent this in future deployments, set `max_allowed_packet` in the MariaDB config:

```yaml
apiVersion: kubedb.com/v1
kind: MariaDB
metadata:
  name: md
  namespace: demo
spec:
  configSecret:
    name: md-config
  # ... rest of spec
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: md-config
  namespace: demo
stringData:
  md.cnf: |-
    [mysqld]
    max_allowed_packet = 64M
```

This ensures the setting persists across pod restarts.

## Key Takeaway

When running chaos tests that involve heavy write loads + pod restarts on MariaDB Replication:
- Oversized binlog events can break slave IO threads if `max_allowed_packet` is too small
- `FLUSH BINARY LOGS` on the Master is the quickest fix — rotates to a clean binlog file
- Always set `max_allowed_packet` explicitly in config for production replication clusters
- MaxScale shows `Running` (without `Slave`) when the IO thread is stopped — this is the indicator to check `SHOW SLAVE STATUS`
