# KubeDB MySQL Chaos Engineering — Test Report (MySQL 8.4.8)

**Date:** 2026-04-07
**Cluster:** KubeDB MySQL 8.4.8 — 3-node Group Replication (Single-Primary)
**Namespace:** `demo`
**Chaos Engine:** Chaos Mesh
**Load Generator:** sysbench, 4 tables x 50k rows

---

## Experiments Summary

| # | Experiment | Failover | Data Loss | GTIDs | Checksums | Verdict |
|---|---|---|---|---|---|---|
| 1 | Pod Kill Primary | Yes | Zero | MATCH | MATCH | PASS |
| 2 | OOMKill Primary (stress) | No (survived) | Zero | MATCH | MATCH | PASS |
| 3 | Network Partition | Yes | Zero | MATCH | MATCH | PASS |
| 4 | IO Latency (100ms) | No | Zero | MATCH | MATCH | PASS |
| 5 | Network Latency (1s) | No | Zero | MATCH | MATCH | PASS |
| 6 | CPU Stress (98%) | No | Zero | MATCH | MATCH | PASS |
| 7 | Packet Loss (30%) | Yes | Zero | MATCH | MATCH | PASS |
| 8 | Combined Stress (mem+cpu+load) | Yes (OOMKill) | Zero | MATCH (after settling) | MATCH (after settling) | PASS |
| 9 | Full Cluster Kill | Yes | Zero | MATCH (after settling) | MATCH (after settling) | PASS |
| 10 | OOMKill Natural Load (128 threads) | No (survived) | Zero | MATCH | MATCH | PASS |
| 11 | Scheduled Replica Kill (every 30s) | Multiple | Zero | MATCH | MATCH | PASS |
| 12 | Degraded Failover (IO + Kill) | Yes | Zero | MATCH | MATCH | PASS |
| 13 | Double Primary Kill | Yes (x2) | Zero | MATCH | MATCH | PASS |
| 14 | Rolling Restart (0→1→2) | Yes (x3) | Zero | MATCH | MATCH | PASS |
| 15 | Coordinator Crash | No | Zero | MATCH | MATCH | PASS |
| 16 | Long Network Partition (10 min) | Yes | Zero | MATCH | MATCH | PASS |
| 17 | DNS Failure on Primary | No | Zero | MATCH | MATCH | PASS |
| 18 | PVC Delete + Pod Kill | Yes | Zero | MATCH | MATCH | PASS |

---

## Detailed Results

### Exp 1: Pod Kill Primary
- **Action:** Force-deleted primary pod (pod-0)
- **Failover:** Pod-2 elected as new PRIMARY
- **Tracking rows:** 6/6 preserved
- **Split-brain:** None
- **Extra GTID warnings:** 0

### Exp 2: OOMKill Primary (Memory Stress)
- **Action:** Applied 1600MB memory stress on primary
- **Result:** Primary survived — stress did not trigger OOMKill on 8.4.8
- **Tracking rows:** 7/7 preserved

### Exp 3: Network Partition
- **Action:** Isolated primary from replicas for 2 minutes
- **Failover:** Pod-1 elected as new PRIMARY
- **Cluster status:** Critical at check time (pod-2 still recovering)
- **Tracking rows:** 8/8 preserved
- **Note:** Cluster recovered to Ready after settling

### Exp 4: IO Latency (100ms)
- **Action:** IO latency on primary + 8-thread write load
- **TPS:** 3.55 avg (99.8% reduction)
- **95th latency:** 3,640ms
- **Errors:** 0
- **Tracking rows:** 9/9 preserved

### Exp 5: Network Latency (1s)
- **Action:** 1s latency between primary and replicas + 8-thread write load
- **TPS:** 1.22 avg (99.9% reduction)
- **95th latency:** 8,956ms
- **Errors:** 0
- **Tracking rows:** 10/10 preserved

### Exp 6: CPU Stress (98%)
- **Action:** 98% CPU stress on primary + 8-thread write load
- **Tracking rows:** 11/11 preserved
- **No failover**

### Exp 7: Packet Loss (30%)
- **Action:** 30% packet loss on all nodes + 8-thread write load for 2 min
- **Failover:** Yes — primary changed from pod-1 to pod-2
- **Tracking rows:** 12/12 preserved

### Exp 8: Combined Stress (Memory + CPU + Load)
- **Action:** 1200MB memory stress on primary, 800MB on replica, 90% CPU on all + 16-thread write load
- **Result:** Pods OOMKilled, cluster went NotReady during recovery
- **At check time:** GTIDs MISMATCH, checksums MISMATCH (replication lag)
- **After settling (3 min):** GTIDs MATCH, all checksums MATCH
- **Tracking rows:** 12/12 preserved (no new row — insert happened before chaos took effect)

### Exp 9: Full Cluster Kill
- **Action:** Force-deleted all 3 pods simultaneously
- **At check time:** NotReady, GTIDs/checksums MISMATCH (still recovering)
- **After settling:** GTIDs MATCH, all checksums MATCH, cluster Ready
- **Election:** Pod-2 elected as PRIMARY
- **Tracking rows:** 12/12 preserved

### Exp 10: OOMKill via Natural Load (128 threads + JOINs)
- **Action:** 128-thread sysbench + large JOIN queries to exhaust memory naturally
- **Result:** Primary survived — 8.4.8 did not OOMKill under this load
- **Tracking rows:** 13/13 preserved

### Exp 11: Scheduled Replica Kill (every 30s)
- **Action:** Kill random standby pod every 30s for 3 minutes
- **Multiple failovers:** Replicas killed and recovered repeatedly
- **Tracking rows:** 14/14 preserved

### Exp 12: Degraded Failover Workflow (IO Latency + Pod Kill)
- **Action:** IO latency on primary + pod kill workflow
- **Failover:** Pod-1 elected as new PRIMARY
- **Tracking rows:** 15/15 preserved

---

## Issues Found

### Issue 1: Transient Checksum/GTID Mismatch During Recovery (Exp 8, 9)

**Severity:** Low (cosmetic)

During combined stress (Exp 8) and full cluster kill (Exp 9), the verification check ran while the cluster was still recovering (NotReady state). GTIDs and checksums showed MISMATCH at that point. After waiting 3 minutes for replication to settle, all GTIDs matched and all checksums matched.

**Root cause:** Replication applier threads need time to catch up after heavy write load + node restarts. The check ran too early.

**Impact:** None — data was consistent after recovery completed.

### Issue 2: OOMKill Did Not Trigger on 8.4.8 (Exp 2, 10)

**Severity:** Info

Neither the StressChaos memory stressor (1600MB) nor the natural load (128 threads + large JOINs) triggered OOMKill on MySQL 8.4.8. The same tests successfully OOMKilled MySQL 9.6.0.

**Possible reason:** MySQL 8.4.8 may handle memory allocation differently (more conservative buffer management), or the 1536Mi limit provides more headroom on this version.

---

## Extended Experiments (13-18)

### Exp 13: Double Primary Kill (PASS)

**Scenario:** Kill the primary, wait for a new primary to be elected, then immediately kill the new primary. Tests whether the cluster can survive two consecutive leader failures.

**Method:**
```bash
# Start sysbench load
kubectl exec -n demo $SBPOD -- sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=12 --table-size=100000 \
  --threads=4 --time=120 --report-interval=10 run &

# Kill first primary
kubectl delete pod mysql-ha-cluster-2 -n demo --force --grace-period=0

# Wait 15s for new primary election
sleep 15

# Kill the newly elected primary
NEW_PRIMARY=$(kubectl get pods -n demo \
  -l "app.kubernetes.io/instance=mysql-ha-cluster,kubedb.com/role=primary" \
  -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $NEW_PRIMARY -n demo --force --grace-period=0
```

**Load:** sysbench `oltp_write_only`, 4 threads, 120s

| Check | Result |
|---|---|
| First primary killed | pod-2 |
| New primary elected | pod-1 (within ~3 seconds) |
| Second primary killed | pod-1 (15s after first kill) |
| Final primary | pod-0 elected as third primary |
| Sysbench | Lost connection during first kill (error 2013 — expected) |
| Recovery time | ~90 seconds for full 3-node cluster |
| GTIDs | MATCH |
| Checksums | All 4 tables MATCH across 3 pods |
| Errant GTIDs | 0 |

---

### Exp 14: Rolling Restart 0→1→2 (PASS)

**Scenario:** Simulate a rolling upgrade by deleting each pod sequentially with 40-second gaps, while write load is running. Tests graceful rolling restart behavior.

**Method:**
```bash
# Start sysbench load
kubectl exec -n demo $SBPOD -- sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=12 --table-size=100000 \
  --threads=4 --time=180 --report-interval=10 run &

# Rolling restart: delete each pod with 40s gap
kubectl delete pod mysql-ha-cluster-0 -n demo --force --grace-period=0
sleep 40
kubectl delete pod mysql-ha-cluster-1 -n demo --force --grace-period=0
sleep 40
kubectl delete pod mysql-ha-cluster-2 -n demo --force --grace-period=0
```

**Load:** sysbench `oltp_write_only`, 4 threads, 180s

**Timeline:**
| Time | Event | Primary |
|---|---|---|
| T+0s | Sysbench started, ~700 TPS | pod-0 (PRIMARY) |
| T+5s | pod-0 (primary) deleted | Failover → pod-2 |
| T+40s | pod-0 recovered, pod-1 deleted | pod-2 remained PRIMARY |
| T+80s | pod-1 recovered, pod-2 (primary) deleted | Failover → pod-1 |
| T+120s | All 3 pods online | pod-1 (PRIMARY) |

| Check | Result |
|---|---|
| Pod-0 deleted (primary) | Recovered in ~30s, failover to pod-2 |
| Pod-1 deleted (secondary) | Recovered in ~30s, pod-2 remained PRIMARY |
| Pod-2 deleted (primary) | Recovered in ~30s, failover to pod-1 |
| Total failovers | 2 (when primary was deleted) |
| GTIDs | MATCH |
| Checksums | All 4 tables MATCH across 3 pods |
| Errant GTIDs | 0 |

---

### Exp 15: Coordinator Crash (PASS)

**Scenario:** Kill only the mysql-coordinator sidecar container on the primary pod, leaving the MySQL process running. Tests whether the cluster remains stable when the coordinator managing it crashes.

**Method:**
```bash
# Kill coordinator process (PID 1) on the primary pod
kubectl exec -n demo mysql-ha-cluster-1 -c mysql-coordinator -- kill 1

# Kubernetes automatically restarts the container
# Verify MySQL stayed running and no failover occurred
```

**Verification:**
```bash
# Confirm writes still work
kubectl exec -n demo $SBPOD -- sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=12 --table-size=100000 \
  --threads=4 --time=15 --report-interval=5 run
```

| Check | Result |
|---|---|
| Coordinator container | Restarted automatically (restart count +1) |
| MySQL process | Stayed running — zero interruption |
| Primary change | **None** — same pod remained PRIMARY |
| TPS after coordinator restart | 728 (normal baseline) |
| GR member status | All 3 ONLINE, no state change |
| GTIDs | MATCH |
| Checksums | All 4 tables MATCH across 3 pods |
| Errant GTIDs | 0 |

**Key finding:** The coordinator crash has zero impact on the running MySQL cluster. Kubernetes restarts the coordinator container, which reconnects and resumes its monitoring loop. MySQL Group Replication operates independently of the coordinator — the coordinator only manages recovery and labeling.

---

### Exp 16: Long Network Partition — 10 min (PASS)

**Scenario:** Isolate the primary from all replicas for 10 minutes (5x longer than the standard 2-minute partition test). Tests whether the coordinator can recover the cluster after an extended isolation period.

**Chaos YAML:** `1-single-experiments/network-partition-long.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: mysql-primary-network-partition-long
  namespace: chaos-mesh
spec:
  action: partition
  mode: one
  selector:
    namespaces:
      - demo
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
      "kubedb.com/role": "primary"
  target:
    mode: all
    selector:
      namespaces:
        - demo
      labelSelectors:
        "kubedb.com/role": "standby"
  direction: both
  duration: "10m"
```

**Load:** sysbench `oltp_write_only`, 4 threads, 60s (started after partition applied)

| Check | Result |
|---|---|
| Partition duration | 10 minutes |
| Failover | Yes — new primary elected within seconds of partition |
| Cluster status during partition | NotReady (2/3 members), then Critical |
| Sysbench during partition | Connection refused (cluster transitioning) |
| Recovery after partition removed | All 3 nodes ONLINE within ~2 minutes |
| GTIDs | MATCH |
| Checksums | All 4 tables MATCH across 3 pods |
| Errant GTIDs | 0 |

**Key finding:** Even after 10 minutes of complete network isolation, the isolated primary rejoins the group cleanly via GR distributed recovery. No manual intervention needed. The coordinator detects the partition, facilitates failover, and manages the rejoin.

---

### Exp 17: DNS Failure on Primary (PASS)

**Scenario:** Block all DNS resolution on the primary pod for 3 minutes. GR uses hostnames for inter-node communication, so DNS failure tests a critical infrastructure dependency.

**Chaos YAML:** `1-single-experiments/dns-error-primary.yaml`
```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: DNSChaos
metadata:
  name: mysql-dns-error-primary
  namespace: chaos-mesh
spec:
  action: error
  mode: one
  selector:
    namespaces:
      - demo
    labelSelectors:
      "app.kubernetes.io/instance": "mysql-ha-cluster"
      "kubedb.com/role": "primary"
  duration: "3m"
```

**Load:** sysbench `oltp_write_only`, 4 threads, 60s

| Check | Result |
|---|---|
| TPS during DNS failure | 497 avg (29,825 transactions in 60s) |
| TPS reduction | ~32% from baseline (~730) |
| Failover | **No** — primary stayed online |
| Errors | 0 |
| GR member status | All 3 ONLINE throughout |
| GTIDs | MATCH |
| Checksums | All 4 tables MATCH across 3 pods |
| Errant GTIDs | 0 |

**Key finding:** DNS failure on the primary causes TPS degradation (~32%) but does NOT trigger failover or break the GR group. MySQL's existing TCP connections to other nodes remain open despite DNS being broken. Writes continue successfully, just slower due to DNS-dependent operations timing out and retrying.

---

### Exp 18: PVC Delete + Pod Kill (PASS)

**Scenario:** Completely destroy a node's data by deleting both the pod and its PVC. The node must rebuild from scratch — on MySQL 8.0+, the CLONE plugin performs a full data snapshot from a donor node.

**Method:**
```bash
# Force delete the pod and its persistent volume claim
kubectl delete pod mysql-ha-cluster-0 -n demo --force --grace-period=0
kubectl delete pvc data-mysql-ha-cluster-0 -n demo

# The StatefulSet controller will:
# 1. Create a new PVC (empty)
# 2. Create a new pod with the empty PVC
# 3. The init script + coordinator will detect empty data dir
# 4. CLONE plugin copies full data from a donor
# 5. Node joins GR with complete data
```

**Verification:**
```bash
# Check new PVC was created
kubectl get pvc -n demo

# Wait for pod to be Running and verify GR membership
kubectl exec -n demo mysql-ha-cluster-0 -c mysql -- mysql -uroot -p"$PASS" \
  -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE \
  FROM performance_schema.replication_group_members;"

# Verify data matches
for i in 0 1 2; do
  echo -n "pod-$i: "
  kubectl exec -n demo mysql-ha-cluster-$i -c mysql -- \
    mysql -uroot -p"$PASS" -N -e "CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4;"
done
```

| Check | Result |
|---|---|
| Old PVC | Deleted |
| New PVC created | Yes — auto-provisioned by StatefulSet (new volume ID) |
| Data sync method | CLONE plugin (full snapshot from donor) |
| Pod recovery time | ~90 seconds (pod Running + CLONE + GR join) |
| GR status | All 3 ONLINE (pod-0 as SECONDARY) |
| GTIDs | MATCH (pod-0 has identical GTIDs after CLONE) |
| Checksums | All 4 tables MATCH across 3 pods |
| Errant GTIDs | 0 |

**Key finding:** The CLONE plugin on MySQL 8.0+ enables complete data rebuild from scratch. Even when a node's entire persistent storage is destroyed, the cluster can automatically provision a new volume, clone all data from a donor, and rejoin GR — all without manual intervention. This is a critical recovery capability that MySQL 5.7 lacks.

---

## Summary

| Metric | Value |
|---|---|
| Experiments run | 18 |
| Data loss | **Zero** across all experiments |
| Checksum mismatches (after settling) | **Zero** |
| GTID mismatches (after settling) | **Zero** |
| Split-brain incidents | **Zero** |
| Extra GTID warnings | **Zero** |
| Cluster auto-recovered | All 18 experiments |

**Verdict: All 18 experiments PASSED on MySQL 8.4.8. Zero data loss, zero split-brain, zero errant GTIDs.**
