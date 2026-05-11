# MariaDB Replication GTID Fix Guide

## Problem: GTID Out-of-Order Sequence Error

**Error:**
```
2026-05-06 10:27:23 28 [ERROR] Slave SQL: An attempt was made to binlog GTID 0-1-1738 which would create an out-of-order sequence number with existing GTID 0-1-1738, and gtid strict mode is enabled, Gtid 0-1-1738, Internal MariaDB error code: 1950
```

**Cause:**
- The slave already has GTID `0-1-1738` in its local binary log
- Master tries to replicate the same GTID
- With `gtid_strict_mode=ON`, MariaDB rejects the duplicate GTID as out-of-order
- This happens when the slave's GTID advances independently of the master (e.g., after backup-stream restore with stale GTID)

## Quick Fix - Run on Broken Slave

```bash
# Get into the replication directory
cd /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb/replication/

# Fix the specific slave (md-2)
./fix-gtid.sh demo md-0 md-2
```

## Fix All Slaves at Once

```bash
cd /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb/replication/
./fix-all-slaves.sh demo
```

## Manual Fix (if script doesn't work)

```bash
# Step 1: Get password
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)

# Step 2: Get correct GTID from master (backup_info is more accurate)
kubectl exec -n demo md-0 -c mariadb -- cat /var/lib/mysql/mariadb_backup_info | grep "GTID of the last change"

# Step 3: Fix the slave
kubectl exec -n demo md-2 -c mariadb -- mariadb -uroot -p"$PASS" -e "STOP SLAVE;"
kubectl exec -n demo md-2 -c mariadb -- mariadb -uroot -p"$PASS" -e "RESET SLAVE ALL;"
kubectl exec -n demo md-2 -c mariadb -- mariadb -uroot -p"$PASS" -e "SET GLOBAL gtid_slave_pos='0-1-1737';"  # Use actual GTID from step 2

# Step 4: Restart replication
kubectl exec -n demo md-2 -c mariadb -- mariadb -uroot -p"$PASS" -e "
CHANGE MASTER TO 
  MASTER_HOST='md-0.md-pods.demo.svc.cluster.local',
  MASTER_PORT=3306,
  MASTER_USER='repl',
  MASTER_PASSWORD='$PASS',
  MASTER_USE_GTID=slave_pos;
START SLAVE;"

# Step 5: Verify
kubectl exec -n demo md-2 -c mariadb -- mariadb -uroot -p"$PASS" -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running|Slave_SQL_Running"
```

## Prevention

The root cause is that the init script uses a stale GTID from `/scripts/gtid.txt` instead of the actual GTID from the backup. 

**Fix applied in newer images:** After backup-stream restore, read GTID from `/var/lib/mysql/mariadb_backup_info` (authoritative) instead of `/scripts/gtid.txt`.

## Verify Data Integrity After Fix

```bash
# Run checksum comparison
cd /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mariadb/replication/
./quick-check.sh
```

Expected output should show all ✓ with matching checksums across all pods.