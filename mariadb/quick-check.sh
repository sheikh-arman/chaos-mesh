#!/bin/bash

# Quick data verification - checksums only

NAMESPACE="${1:-demo}"
PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

echo "Quick Checksum Verification"
echo "==========================="

for POD in md-0 md-1 md-2; do
  echo ""
  echo "=== $POD ==="
  kubectl exec -n $NAMESPACE $POD -c mariadb -- mariadb -uroot -p"$PASSWORD" -e "
  CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4, sbtest.sbtest5, sbtest.sbtest6, sbtest.sbtest7, sbtest.sbtest8, sbtest.sbtest9, sbtest.sbtest10, sbtest.sbtest11, sbtest.sbtest12;" 2>/dev/null
done