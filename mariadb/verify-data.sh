#!/bin/bash

# Verify data integrity across all MariaDB pods

NAMESPACE="${1:-demo}"
PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

echo "=========================================="
echo "MariaDB Data Verification Script"
echo "=========================================="

# Get all MariaDB pods
PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=md -o jsonpath='{.items[*].metadata.name}')

echo ""
echo "=== Checking Row Counts ==="
for POD in $PODS; do
  echo ""
  echo "--- $POD ---"
  kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  SELECT 
    TABLE_NAME, 
    TABLE_ROWS 
  FROM information_schema.TABLES 
  WHERE TABLE_SCHEMA = 'sbtest' 
  ORDER BY TABLE_NAME;" 2>/dev/null
done

echo ""
echo "=========================================="
echo "=== Checking Table Checksums ==="
echo "=========================================="
for POD in $PODS; do
  echo ""
  echo "--- $POD ---"
  kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4, sbtest.sbtest5, sbtest.sbtest6, sbtest.sbtest7, sbtest.sbtest8, sbtest.sbtest9, sbtest.sbtest10, sbtest.sbtest11, sbtest.sbtest12;" 2>/dev/null
done

echo ""
echo "=========================================="
echo "=== Checking Chaos Track Markers ==="
echo "=========================================="
for POD in $PODS; do
  echo ""
  echo "--- $POD ---"
  kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SELECT COUNT(*) as marker_count FROM chaos_track.markers;" 2>/dev/null
done

echo ""
echo "=========================================="
echo "=== Galera Cluster Status ==="
echo "=========================================="
kubectl exec -n $NAMESPACE md-0 -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'wsrep_cluster_size',
  'wsrep_cluster_status',
  'wsrep_local_state_comment',
  'wsrep_ready',
  'wsrep_connected'
);" 2>/dev/null

echo ""
echo "=========================================="
echo "Verification Complete"
echo "=========================================="