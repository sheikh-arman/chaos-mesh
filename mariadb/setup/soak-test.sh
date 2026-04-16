#!/bin/bash
# Soak Test: Long-duration chaos + sustained write load for MariaDB Galera Cluster
# Usage: bash setup/soak-test.sh [duration_hours]
# Default: 2 hours

DURATION_HOURS=${1:-2}
DURATION_SECS=$((DURATION_HOURS * 3600))
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SECS))
LOG_DIR="soak-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

echo "=== MariaDB Galera Soak Test Started ==="
echo "Duration: ${DURATION_HOURS} hours"
echo "Log dir: $LOG_DIR"
echo "Start: $(date)"
echo "End:   $(date -d @$END_TIME 2>/dev/null || date -r $END_TIME 2>/dev/null)"
echo ""

# Apply scheduled chaos: kill a random pod every 5 minutes
cat <<'EOF' | kubectl apply -f -
apiVersion: chaos-mesh.org/v1alpha1
kind: Schedule
metadata:
  name: mariadb-soak-pod-kill
  namespace: chaos-mesh
spec:
  schedule: "*/5 * * * *"
  historyLimit: 300
  concurrencyPolicy: "Forbid"
  type: "PodChaos"
  podChaos:
    action: pod-kill
    mode: one
    selector:
      namespaces:
        - demo
      labelSelectors:
        "app.kubernetes.io/instance": "md"
EOF

echo "Scheduled pod kill applied (every 5 min)"

# Verification function
verify() {
    local ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$ts] === Verification ===" >> "$LOG_DIR/verify.log"

    echo "--- Galera Status ---" >> "$LOG_DIR/verify.log"
    for i in 0 1 2; do
        echo "pod-$i:" >> "$LOG_DIR/verify.log"
        kubectl exec -n demo md-$i -c mariadb -- \
            mariadb -uroot -p"$PASS" -e \
            "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready','wsrep_connected');" \
            2>/dev/null >> "$LOG_DIR/verify.log" 2>&1
    done

    echo "--- GTIDs ---" >> "$LOG_DIR/verify.log"
    for i in 0 1 2; do
        echo -n "pod-$i: " >> "$LOG_DIR/verify.log"
        kubectl exec -n demo md-$i -c mariadb -- \
            mariadb -uroot -p"$PASS" -N -e "SELECT @@gtid_current_pos;" \
            2>/dev/null >> "$LOG_DIR/verify.log" 2>&1
    done

    echo "--- Checksums ---" >> "$LOG_DIR/verify.log"
    for i in 0 1 2; do
        echo -n "pod-$i: " >> "$LOG_DIR/verify.log"
        kubectl exec -n demo md-$i -c mariadb -- \
            mariadb -uroot -p"$PASS" -N -e \
            "CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4;" \
            2>/dev/null >> "$LOG_DIR/verify.log" 2>&1
    done
    echo "" >> "$LOG_DIR/verify.log"
}

# Main loop: run sysbench in 5-minute bursts, verify after each
ROUND=0
while [ $(date +%s) -lt $END_TIME ]; do
    ROUND=$((ROUND + 1))
    echo "[$(date +"%H:%M:%S")] Round $ROUND starting..."

    kubectl exec -n demo $SBPOD -- sysbench oltp_write_only \
        --mysql-host=md --mysql-port=3306 \
        --mysql-user=root --mysql-password="$PASS" \
        --mysql-db=sbtest --tables=4 --table-size=50000 \
        --threads=4 --time=300 --report-interval=60 run \
        >> "$LOG_DIR/sysbench-round-$ROUND.log" 2>&1
    SB_EXIT=$?

    echo "[$(date +"%H:%M:%S")] Round $ROUND finished (exit=$SB_EXIT)"

    # Verify data integrity after each round
    verify

    # If sysbench failed, wait for cluster to recover
    if [ $SB_EXIT -ne 0 ]; then
        echo "[$(date +"%H:%M:%S")] Sysbench failed, waiting 30s for recovery..."
        sleep 30
    else
        sleep 10
    fi
done

# Cleanup chaos
kubectl delete schedule mariadb-soak-pod-kill -n chaos-mesh 2>/dev/null
echo ""
echo "=== Soak Test Completed ==="
echo "Duration: ${DURATION_HOURS} hours"
echo "Rounds: $ROUND"
echo "Logs: $LOG_DIR/"
echo ""

# Final verification
echo "=== Final Verification ==="
verify
cat "$LOG_DIR/verify.log" | tail -20
