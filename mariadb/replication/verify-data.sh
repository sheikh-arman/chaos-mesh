#!/bin/bash

# Verify data integrity across all MariaDB pods
# Compares checksums across all pods and reports mismatches

NAMESPACE="${1:-demo}"
PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

echo "=========================================="
echo "MariaDB Data Verification Script"
echo "=========================================="

# Get all MariaDB pods
PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=md -o jsonpath='{.items[*].metadata.name}')
POD_ARRAY=($PODS)

echo ""
echo "=== Checking Row Counts ==="
declare -A ROW_COUNTS
for POD in $PODS; do
  echo ""
  echo "--- $POD ---"
  RESULT=$(kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  SELECT 
    TABLE_NAME, 
    TABLE_ROWS 
  FROM information_schema.TABLES 
  WHERE TABLE_SCHEMA = 'sbtest' 
  ORDER BY TABLE_NAME;" 2>/dev/null)
  echo "$RESULT"
done

echo ""
echo "=========================================="
echo "=== Checking Table Checksums ==="
echo "=========================================="

# Collect checksums from all pods
declare -A CHECKSUMS
TABLES=("sbtest1" "sbtest2" "sbtest3" "sbtest4" "sbtest5" "sbtest6" "sbtest7" "sbtest8" "sbtest9" "sbtest10" "sbtest11" "sbtest12")

for POD in $PODS; do
  echo ""
  echo "--- $POD ---"
  RESULT=$(kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4, sbtest.sbtest5, sbtest.sbtest6, sbtest.sbtest7, sbtest.sbtest8, sbtest.sbtest9, sbtest.sbtest10, sbtest.sbtest11, sbtest.sbtest12;" 2>/dev/null)
  echo "$RESULT"
  
  # Store checksum for comparison
  for TABLE in "${TABLES[@]}"; do
    CS=$(echo "$RESULT" | grep "$TABLE" | awk '{print $2}')
    CHECKSUMS["${POD}_${TABLE}"]=$CS
  done
done

echo ""
echo "=========================================="
echo "=== Checksum Comparison Result ==="
echo "=========================================="

MISMATCH_FOUND=0
FIRST_POD="${POD_ARRAY[0]}"

for TABLE in "${TABLES[@]}"; do
  REFERENCE_CS="${CHECKSUMS[${FIRST_POD}_${TABLE}]}"
  MISMATCHED_PODS=""
  
  for POD in $PODS; do
    POD_CS="${CHECKSUMS[${POD}_${TABLE}]}"
    if [ "$POD_CS" != "$REFERENCE_CS" ]; then
      MISMATCH_FOUND=1
      if [ -z "$MISMATCHED_PODS" ]; then
        MISMATCHED_PODS="$POD"
      else
        MISMATCHED_PODS="$MISMATCHED_PODS, $POD"
      fi
    fi
  done
  
  if [ $MISMATCH_FOUND -eq 1 ]; then
    echo "❌ MISMATCH: $TABLE"
    echo "   Reference (${FIRST_POD}): $REFERENCE_CS"
    echo "   Mismatched pods: $MISMATCHED_PODS"
  else
    echo "✓ $TABLE: $REFERENCE_CS (all match)"
  fi
done

if [ $MISMATCH_FOUND -eq 0 ]; then
  echo ""
  echo "✅ All checksums match across all pods!"
else
  echo ""
  echo "⚠️  WARNING: Checksum mismatches detected!"
fi

echo ""
echo "=========================================="
echo "=== Checking Chaos Track Markers ==="
echo "=========================================="

declare -A MARKER_COUNTS
for POD in $PODS; do
  echo ""
  echo "--- $POD ---"
  RESULT=$(kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "SELECT COUNT(*) as marker_count FROM chaos_track.markers;" 2>/dev/null)
  echo "$RESULT"
  COUNT=$(echo "$RESULT" | tail -1)
  MARKER_COUNTS["$POD"]=$COUNT
done

# Compare markers
echo ""
echo "=== Marker Comparison ==="
REF_MARKERS="${MARKER_COUNTS[${FIRST_POD}]}"
MARKER_MISMATCH=0
for POD in $PODS; do
  if [ "${MARKER_COUNTS[$POD]}" != "$REF_MARKERS" ]; then
    MARKER_MISMATCH=1
    echo "❌ MISMATCH: $POD has ${MARKER_COUNTS[$POD]} markers, expected $REF_MARKERS"
  fi
done

if [ $MARKER_MISMATCH -eq 0 ]; then
  echo "✅ All marker counts match: $REF_MARKERS"
else
  echo "⚠️  WARNING: Marker count mismatches detected!"
fi

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