#!/bin/bash

# Quick data verification - checksums only with comparison

NAMESPACE="${1:-demo}"
PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

echo "Quick Checksum Verification"
echo "==========================="

# Get pods
PODS=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=md -o jsonpath='{.items[*].metadata.name}')
POD_ARRAY=($PODS)

# Tables to check
TABLES=("sbtest1" "sbtest2" "sbtest3" "sbtest4" "sbtest5" "sbtest6" "sbtest7" "sbtest8" "sbtest9" "sbtest10" "sbtest11" "sbtest12")

# Collect checksums
declare -A CHECKSUMS

for POD in $PODS; do
  echo ""
  echo "=== $POD ==="
  RESULT=$(kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4, sbtest.sbtest5, sbtest.sbtest6, sbtest.sbtest7, sbtest.sbtest8, sbtest.sbtest9, sbtest.sbtest10, sbtest.sbtest11, sbtest.sbtest12;" 2>/dev/null)
  echo "$RESULT"
  
  for TABLE in "${TABLES[@]}"; do
    CS=$(echo "$RESULT" | grep "$TABLE" | awk '{print $2}')
    CHECKSUMS["${POD}_${TABLE}"]=$CS
  done
done

echo ""
echo "==========================="
echo "Checksum Comparison Result"
echo "==========================="

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

echo ""
if [ $MISMATCH_FOUND -eq 0 ]; then
  echo "✅ All checksums match across all pods!"
else
  echo "⚠️  WARNING: Checksum mismatches detected!"
fi