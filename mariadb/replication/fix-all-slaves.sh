#!/bin/bash

# Fix GTID replication for all slaves in the cluster
# Usage: ./fix-all-slaves.sh [namespace]

NAMESPACE="${1:-demo}"

PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

echo "=========================================="
echo "Fix All Slaves GTID Replication"
echo "=========================================="

# Get master and all slaves
MASTER_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=md,kubedb.com/role=Master -o jsonpath='{.items[0].metadata.name}')
SLAVE_PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=md,kubedb.com/role=Slave -o jsonpath='{.items[*].metadata.name}')

echo "Master: $MASTER_POD"
echo "Slaves: $SLAVE_PODS"
echo ""

# Get master GTID
echo "Getting master GTID position..."
MASTER_GTID=$(kubectl exec -n $NAMESPACE $MASTER_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SHOW MASTER STATUS;" 2>/dev/null | grep "mariadb-bin" | awk '{print $NF}')

# Try backup_info GTID first
BACKUP_GTID=$(kubectl exec -n $NAMESPACE $MASTER_POD -c mariadb -- cat /var/lib/mysql/mariadb_backup_info 2>/dev/null | grep "GTID of the last change" | awk -F"'" '{print $2}')
if [ -n "$BACKUP_GTID" ]; then
  MASTER_GTID="$BACKUP_GTID"
fi

echo "Using GTID: $MASTER_GTID"
echo ""

# Fix each slave
for SLAVE_POD in $SLAVE_PODS; do
  echo "Fixing $SLAVE_POD..."
  
  # Stop slave
  kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "STOP SLAVE;" 2>/dev/null
  
  # Reset and set new GTID
  kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "RESET SLAVE ALL;" 2>/dev/null
  kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SET GLOBAL gtid_slave_pos='$MASTER_GTID';" 2>/dev/null
  
  # Start replication
  MASTER_HOST="$MASTER_POD.md-pods.$NAMESPACE.svc.cluster.local"
  kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  CHANGE MASTER TO 
    MASTER_HOST='$MASTER_HOST',
    MASTER_PORT=3306,
    MASTER_USER='repl',
    MASTER_PASSWORD='$PASSWORD',
    MASTER_USE_GTID=slave_pos;
  START SLAVE;" 2>/dev/null
  
  sleep 2
  
  # Check status
  STATUS=$(kubectl exec -n $NAMESPACE $SLAVE_POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running" | head -2)
  echo "  Status: $STATUS"
done

echo ""
echo "=========================================="
echo "Checking final replication status..."
echo "=========================================="

# Show final status
for POD in $MASTER_POD $SLAVE_PODS; do
  echo ""
  echo "--- $POD ---"
  kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Slave_IO_Running|Slave_SQL_Running|Last_IO_Error" | head -3
done