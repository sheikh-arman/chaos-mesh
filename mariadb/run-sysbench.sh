#!/bin/bash

# Run sysbench load test
# Usage: ./run-sysbench.sh [duration-in-seconds] [threads]

NAMESPACE="${1:-demo}"
DURATION="${2:-30}"
THREADS="${3:-4}"

PASSWORD=$(kubectl get secret md-auth -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n $NAMESPACE -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

if [ -z "$SBPOD" ]; then
  echo "Error: No sysbench pod found in namespace $NAMESPACE"
  exit 1
fi

echo "Running sysbench for $DURATION seconds with $THREADS threads..."
echo "Pod: $SBPOD"
echo ""

kubectl exec -n $NAMESPACE $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md.$NAMESPACE.svc.cluster.local --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASSWORD" \
  --mysql-db=sbtest --tables=4 --table-size=50000 \
  --threads=$THREADS --time=$DURATION --report-interval=5 run