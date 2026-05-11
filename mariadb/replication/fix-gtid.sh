#!/bin/bash

# Automated GTID Replication Fix Script
# Fixes GTID out-of-order sequence number errors
# Usage: ./fix-gtid.sh [namespace] [master-pod] [slave-pod]

NAMESPACE="${1:-demo}"
MASTER_POD="${2:-md-0}"
SLAVE_POD="${3:-md-2}"

PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

echo "=========================================="
echo "GTID Replication Fix Script"
echo "=========================================="
echo ""
echo "Master: $MASTER_POD"
echo "Slave: $SLAVE_POD"
echo "Namespace: $NAMESPACE"
echo ""

# Step 1: Get the current GTID position from master
echo "Step 1: Getting GTID position from master..."

# First check if mariadb_backup_info exists (for backup-stream restored nodes)
BACKUP_INFO_GTID=$(kubectl exec -n $NAMESPACE $MASTER_POD -c mariadb -- cat /var/lib/mysql/mariadb_backup_info 2>/dev/null | grep "GTID of the last change" | awk -F"'" '{print $2}')

if [ -n "$BACKUP_INFO_GTID" ]; then
  MASTER_GTID="$BACKUP_INFO_GTID"
  echo "Found GTID from mariadb_backup_info: $MASTER_GTID"
else
  # Fall back to SHOW MASTER STATUS
  MASTER_GTID=$(kubectl exec -n $NAMESPACE $MASTER_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SHOW MASTER STATUS;" 2>/dev/null | grep "mariadb-bin" | awk '{print $NF}')
  echo "Found GTID from SHOW MASTER STATUS: $MASTER_GTID"
fi

# Step 2: Check current slave status
echo ""
echo "Step 2: Current slave status..."
kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error|Last_SQL_Error|Executed_Gtid_Set"

# Step 3: Stop the slave
echo ""
echo "Step 3: Stopping slave..."
kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "STOP SLAVE;" 2>/dev/null

# Step 4: Reset slave
echo ""
echo "Step 4: Resetting slave..."
kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "RESET SLAVE ALL;" 2>/dev/null

# Step 5: Set the correct GTID position from master
echo ""
echo "Step 5: Setting GTID position to: $MASTER_GTID"
kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SET GLOBAL gtid_slave_pos='$MASTER_GTID';" 2>/dev/null

# Step 6: Configure and start replication
echo ""
echo "Step 6: Starting replication..."
MASTER_HOST="$MASTER_POD.md-pods.$NAMESPACE.svc.cluster.local"

kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
CHANGE MASTER TO 
  MASTER_HOST='$MASTER_HOST',
  MASTER_PORT=3306,
  MASTER_USER='repl',
  MASTER_PASSWORD='$PASSWORD',
  MASTER_USE_GTID=slave_pos;
START SLAVE;
" 2>/dev/null

# Step 7: Wait and check status
sleep 3

echo ""
echo "Step 7: Checking replication status..."
kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error|Seconds_Behind_Master"

echo ""
echo "=========================================="
echo "GTID Fix Complete"
echo "=========================================="