# MariaDB Galera Cluster — Chaos Testing Instructions

Step-by-step guide to reproduce the 18 chaos experiments on a KubeDB MariaDB Galera Cluster.

---

## Prerequisites

- Kubernetes cluster (kind, EKS, GKE, etc.)
- KubeDB operator installed
- Chaos Mesh installed
- `kubectl` configured

## 1. Deploy the Cluster

```bash
kubectl create namespace demo
kubectl apply -f setup/kubedb-mariadb.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Ready mariadb/md -n demo --timeout=5m
```

Verify all 3 pods are Running:

```bash
kubectl get mariadb,pods -n demo -L kubedb.com/role
```

Expected: all 3 pods `2/2 Running`, role `Primary`, MariaDB status `Ready`.

## 2. Deploy Sysbench

```bash
kubectl apply -f setup/sysbench.yaml
```

## 3. Set Environment Variables

Run this before every test session:

```bash
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')
```

## 4. Create the Test Database and Prepare Tables

```bash
# Create database
kubectl exec -n demo md-0 -c mariadb -- \
  mariadb -uroot -p"$PASS" -e "CREATE DATABASE IF NOT EXISTS sbtest;"

# Prepare sysbench tables (4 tables x 50k rows)
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 --table-size=50000 \
  --threads=4 prepare
```

## 5. Insert Tracking Rows (for data integrity verification)

```bash
kubectl exec -n demo md-0 -c mariadb -- mariadb -uroot -p"$PASS" -e "
CREATE DATABASE IF NOT EXISTS chaos_track;
CREATE TABLE IF NOT EXISTS chaos_track.markers (
  id INT AUTO_INCREMENT PRIMARY KEY,
  label VARCHAR(100) NOT NULL,
  val INT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO chaos_track.markers (label, val) VALUES
  ('pre_chaos_1', 1),('pre_chaos_2', 2),('pre_chaos_3', 3),('pre_chaos_4', 4),('pre_chaos_5', 5),
  ('pre_chaos_6', 6),('pre_chaos_7', 7),('pre_chaos_8', 8),('pre_chaos_9', 9),('pre_chaos_10', 10),
  ('pre_chaos_11', 11),('pre_chaos_12', 12),('pre_chaos_13', 13),('pre_chaos_14', 14),('pre_chaos_15', 15),
  ('pre_chaos_16', 16),('pre_chaos_17', 17),('pre_chaos_18', 18),('pre_chaos_19', 19),('pre_chaos_20', 20),
  ('pre_chaos_21', 21),('pre_chaos_22', 22),('pre_chaos_23', 23),('pre_chaos_24', 24),('pre_chaos_25', 25);
SELECT COUNT(*) AS marker_count FROM chaos_track.markers;
"
```

Expected output: `marker_count = 25`

## 6. Baseline Sysbench Run (before any chaos)

```bash
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 --table-size=50000 \
  --threads=4 --time=15 --report-interval=5 run
```

Note down the baseline TPS (ours was ~1039 TPS).

---

## 7. Running Each Chaos Experiment

Every experiment follows the same workflow:

### Step A: Check pre-chaos state

```bash
kubectl get mariadb,pods -n demo -L kubedb.com/role
```

### Step B: Check Galera cluster health

```bash
for i in 0 1 2; do
  echo "=== md-$i ==="
  kubectl exec -n demo md-$i -c mariadb -- \
    mariadb -uroot -p"$PASS" -e "SHOW GLOBAL STATUS WHERE Variable_name IN (
      'wsrep_cluster_size','wsrep_cluster_status',
      'wsrep_local_state_comment','wsrep_ready',
      'wsrep_connected','wsrep_flow_control_paused');"
done
```

Expected: all 3 nodes `Synced`, `cluster_size=3`, `wsrep_ready=ON`.

### Step C: Apply the chaos

```bash
kubectl apply -f <chaos-yaml-file>
```

### Step D: Wait 10-15 seconds, then check status during chaos

```bash
# Pod and MariaDB status
kubectl get mariadb,pods -n demo -L kubedb.com/role

# Galera status on each node
for i in 0 1 2; do
  echo "=== md-$i ==="
  kubectl exec -n demo md-$i -c mariadb -- \
    mariadb -uroot -p"$PASS" --connect-timeout=3 -e \
    "SHOW GLOBAL STATUS WHERE Variable_name IN (
      'wsrep_cluster_size','wsrep_cluster_status',
      'wsrep_local_state_comment','wsrep_ready',
      'wsrep_flow_control_paused');" 2>&1
done
```

### Step E: Run sysbench during chaos

```bash
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 --table-size=50000 \
  --threads=4 --time=15 --report-interval=5 run
```

Key metrics to record:
- **TPS** (transactions per second)
- **err/s** (errors per second)
- **reconn/s** (reconnects per second)
- **95th percentile latency**

### Step F: Delete the chaos

```bash
kubectl delete -f <chaos-yaml-file>
```

### Step G: Wait for cluster to recover

```bash
# Wait until MariaDB is Ready
watch kubectl get mariadb,pods -n demo -L kubedb.com/role

# Or use this one-liner:
until [ "$(kubectl get mariadb md -n demo -o jsonpath='{.status.phase}')" = "Ready" ]; do
  sleep 5
done
echo "Cluster Ready"
```

### Step H: Verify data integrity

```bash
# Check tracking rows on all nodes
for i in 0 1 2; do
  echo -n "md-$i markers: "
  kubectl exec -n demo md-$i -c mariadb -- \
    mariadb -uroot -p"$PASS" -N -e "SELECT COUNT(*) FROM chaos_track.markers;"
done

# Check checksums match across all nodes
for i in 0 1 2; do
  echo "md-$i:"
  kubectl exec -n demo md-$i -c mariadb -- \
    mariadb -uroot -p"$PASS" -N -e \
    "CHECKSUM TABLE sbtest.sbtest1, sbtest.sbtest2, sbtest.sbtest3, sbtest.sbtest4;"
done
```

Expected: all nodes show `25` markers, all checksums match.

---

## 8. Experiment List

### From `1-single-experiments/`

| # | File | Chaos Type | What it tests |
|---|---|---|---|
| 1 | `pod-kill-primary.yaml` | PodChaos (pod-kill) | Kill one pod, test Galera rejoin |
| 2 | `stress-memory-primary.yaml` | StressChaos (memory 1200MB) | OOMKill under memory pressure |
| 3 | `network-partition-primary.yaml` | NetworkChaos (partition) | Isolate one node, test quorum |
| 4 | `io-latency-primary.yaml` | IOChaos (latency 100ms) | Slow disk on one node |
| 5 | `network-latency-primary-to-replicas.yaml` | NetworkChaos (delay 1s) | Slow network between nodes |
| 6 | `stress-cpu-primary.yaml` | StressChaos (CPU 98%) | CPU starvation on one node |
| 7 | `packet-loss.yaml` | NetworkChaos (loss 30%) | Packet loss across cluster |
| 8 | `stress-cpu-all.yaml` + inline pod-kill all | PodChaos (pod-kill mode:all) | Kill all 3 pods simultaneously |
| 9 | `dns-error-primary.yaml` | DNSChaos (error) | DNS failure on one node |
| 10 | `io-fault-primary.yaml` | IOChaos (fault errno 5) | IO errors on 50% of disk ops |
| 11 | `clock-skew-primary.yaml` | TimeChaos (-5m) | Clock shifted back 5 minutes |
| 12 | `bandwidth-throttle.yaml` | NetworkChaos (bandwidth 1mbps) | Throttle network to 1 mbps |

### From `tests/`

| # | File | Chaos Type | What it tests |
|---|---|---|---|
| 13 | `01-pod-failure.yaml` | PodChaos (pod-failure) | Freeze one pod (not kill) for 5 min |
| 14 | `04-kill-mariadb-process.yaml` | PodChaos (container-kill) | Kill only mariadb container, not pod |
| 15 | `09-network-duplicate.yaml` | NetworkChaos (duplicate 50%) | 50% packet duplication |
| 16 | `10-network-corrupt.yaml` | NetworkChaos (corrupt 50%) | 50% packet corruption |
| 17 | `15-io-attr-override.yaml` | IOChaos (attrOverride perm 444) | Make data files read-only |
| 18 | `16-io-mistake.yaml` | IOChaos (mistake random) | Random data corruption in IO |

### Full cluster kill (inline YAML)

For experiment #8, we used an inline YAML since there's no dedicated file:

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: mariadb-full-cluster-kill
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: all
  selector:
    namespaces:
      - demo
    labelSelectors:
      "app.kubernetes.io/instance": "md"
  gracePeriod: 0
```

---

## 9. Quick Status Check Scripts

These scripts are in `setup/`:

```bash
# Check Galera status on md-0
bash setup/gr-0.sh

# Check Galera status on md-1
bash setup/gr-1.sh

# Check Galera status on md-2
bash setup/gr-2.sh
```

## 10. Cleanup All Chaos

```bash
# Delete all active chaos experiments
kubectl delete podchaos,networkchaos,iochaos,stresschaos,dnschaos,timechaos --all -n chaos-mesh

# Verify no chaos is active
kubectl get podchaos,networkchaos,iochaos,stresschaos,dnschaos,timechaos -n chaos-mesh
```

## 11. Sysbench Cleanup (if needed)

```bash
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 cleanup
```

---

## Key Galera Status Variables to Monitor

| Variable | Healthy Value | During Chaos |
|---|---|---|
| `wsrep_cluster_size` | 3 | 2 (one node down) or 1 (isolated) |
| `wsrep_cluster_status` | Primary | non-Primary (lost quorum) |
| `wsrep_local_state_comment` | Synced | Initialized / Joined / Donor |
| `wsrep_ready` | ON | OFF (not accepting queries) |
| `wsrep_connected` | ON | OFF (disconnected) |
| `wsrep_flow_control_paused` | ~0 | >0 means cluster is throttling writes |

## KubeDB MariaDB Status Meanings

| Status | Meaning | Can read/write? |
|---|---|---|
| `Ready` | All nodes Synced, cluster healthy | Yes |
| `Critical` | Quorum maintained but node(s) down | Yes |
| `NotReady` | Lost quorum, no primary component | No |

## Notes

- **MariaDB Galera is multi-master**: all nodes have `kubedb.com/role: Primary`. There are no standby/secondary nodes.
- **Container name** is `mariadb` (not `mysql`).
- **CLI client** is `mariadb` (not `mysql`).
- **Secret name** follows the pattern `<instance-name>-auth` (e.g., `md-auth`).
- **Data path** is `/var/lib/mysql` (same as MySQL).
- **Galera ports**: 4567 (cluster), 4568 (IST), 4444 (SST). Client port is 3306.
- **wsrep_flow_control_paused** is a cumulative counter since last restart. A tiny value like `9.6e-05` is normal and means the node was paused for 0.0096% of uptime.
- Sysbench uses `--mysql-host=md` because KubeDB creates a Service named after the MariaDB resource.
