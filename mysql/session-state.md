# Chaos Testing Session State
# Saved: 2026-04-02 18:10
# Location: /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql

## Cluster State

```
MySQL Version: 9.6.0
Namespace: demo
Cluster Name: mysql-ha-cluster
Status: Ready
Primary: mysql-ha-cluster-1
Replicas: mysql-ha-cluster-0, mysql-ha-cluster-2
```

## Current Pod Status

```
NAME                 READY   STATUS    RESTARTS   AGE    ROLE
mysql-ha-cluster-0   2/2     Running   1          16m    standby
mysql-ha-cluster-1   2/2     Running   0          16m    primary
mysql-ha-cluster-2   2/2     Running   1          15m    standby
```

## MySQL Credentials

```
Password: rI3tQLX53C3oX_Zn
```

## Experiments Completed

### MySQL 8.0.36 (12 tests)

| # | Experiment | Status | Data Loss | Verdict |
|---|---|---|---|---|
| 1 | Pod Kill Primary | ✅ DONE | Zero | PASS |
| 2 | OOMKill Primary (Memory Stress 1600MB) | ✅ DONE | Zero | PASS |
| 3 | Network Partition (3 min) | ✅ DONE | Zero | PASS |
| 4 | IO Latency (100ms, 3 min) | ✅ DONE | Zero | PASS |
| 5 | Network Latency (1s + 50ms, 2 min) | ✅ DONE | Zero | PASS |
| 6 | CPU Stress (98%, 3 min) | ✅ DONE | Zero | PASS |
| 7 | Packet Loss (30%, 3 min) | ✅ DONE | Zero | PASS |
| 8 | Degraded Failover Workflow (IO + Kill) | ✅ DONE | Zero | PASS |
| 9 | Flaky Network Failover Workflow (Loss + Kill) | ✅ DONE | Zero | PASS (auto-recovered) |
| 10 | Scheduled Replica Kill (every 30s, 5 min) | ✅ DONE | Zero | PASS |
| 11 | Scheduled CPU Stress (95%, every 1 min, 5 min) | ✅ DONE | Zero | PASS |
| 12 | OOMKill + Continuous Load (1600MB, load during & after) | ✅ DONE | Zero | PASS |

### MySQL 8.4.8 (9 tests)

| # | Experiment | Status | Data Loss | Verdict |
|---|---|---|---|---|
| 1 | Pod Kill Primary | ✅ DONE | Zero | PASS |
| 2 | OOMKill Primary | ✅ DONE | Zero | PASS |
| 3 | Network Partition | ✅ DONE | Zero | PASS |
| 4 | IO Latency (100ms) | ✅ DONE | Zero | PASS |
| 5 | Network Latency (1s) | ✅ DONE | Zero | PASS |
| 6 | CPU Stress (98%) | ✅ DONE | Zero | PASS |
| 7 | Packet Loss (30%) | ✅ DONE | Zero | PASS |
| 8 | Degraded Failover Workflow | ✅ DONE | Zero | PASS (after fix) |
| 9 | Flaky Network Failover Workflow | ✅ DONE | Zero | PASS |

### MySQL 9.6.0 (2 tests)

| # | Experiment | Status | Data Loss | Verdict |
|---|---|---|---|---|
| 1 | Pod Kill Primary | ✅ DONE | Zero | PASS |
| 2 | OOMKill Primary | ✅ DONE | Zero | PASS |

## Experiments Remaining

| Experiment | File | Notes |
|---|---|---|
| DNS Error | `1-single-experiments/dns-error-from-client.yaml` | Failed — Chaos Mesh DNS chaos injection issue |
| Packet Loss GR Port | `1-single-experiments/packet-loss-group-replication.yaml` | targetPort not supported |
| Packet Delay GR Port | `1-single-experiments/packet-delay-group-replication.yaml` | targetPort not supported |

## Issues Found

### MySQL 8.4.8 — Degraded Failover Recovery Failure

**Severity:** HIGH
**Status:** Fixed by user

After IO latency + pod kill workflow, the killed pod stuck in ping loop and could not rejoin the cluster for 14+ minutes.

**Logs:**
```
[run.sh] [INFO] Attempt 430: Pinging 'mysql-ha-cluster-1.mysql-ha-cluster-pods.demo' has returned: ''
E0402 05:39:02.385822 mysql.go:73] stat /scripts/ready.txt: no such file or directory
```

### MySQL 9.6.0 — check_member_list_updated() Failure

**Severity:** MEDIUM
**Status:** Fixed

MySQL 9.6.0 changed behavior — joining node sees itself as OFFLINE in member list immediately. This caused the function to fail with `Expected: 1, Found: 0`.

**Fix:** Allow `cluster_size <= 1` to pass (node still joining, sees only self as OFFLINE).

### MySQL 9.6.0 — kubedb_write_check Duplicate Key

**Severity:** MEDIUM
**Status:** Documented

During recovery, replica replays binlog with `Write_rows` into `kubedb_write_check` table. ROW-based replication doesn't preserve `INSERT IGNORE` clause, causing duplicate key error.

**Fix suggestion:** Use `REPLACE INTO` or `INSERT ... ON DUPLICATE KEY UPDATE`.

## Report Files

- **Main Report:** `setup/chaos-test-report-full.md` (700 lines, 9 experiments)
- **Old Report:** `setup/chaos-test-report.md` (original, incomplete)
- **Old Report 2:** `setup/chaos-test-report-2-scheduled-workflows.md`

## Key Findings

### Strengths
1. Automatic failover in 2-3 seconds
2. Split-brain prevention via quorum
3. Zero data loss across all experiments
4. Auto-recovery after flaky network (verified)
5. Coordinator handles recovery correctly
6. Scheduled kills don't impact primary TPS

### Weaknesses Found
1. Network latency 1s → 99.9% TPS reduction
2. IO latency 100ms → 99% TPS reduction
3. Packet loss 30% → complete write stall
4. Application needs reconnection (ProxySQL recommended)

### No Issues Found
- Coordinator works correctly
- No split-brain in verified tests
- Auto-recovery confirmed
- Scheduled chaos handled gracefully

## What To Do Next Time

1. **Start fresh:**
   ```bash
   cd /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql
   kubectl get mysql -n demo
   kubectl get pods -n demo -l app.kubernetes.io/instance=mysql-ha-cluster -L kubedb.com/role
   ```

2. **If cluster is down, check:**
   ```bash
   kubectl get mysql -n demo
   kubectl describe mysql mysql-ha-cluster -n demo
   kubectl logs -n demo mysql-ha-cluster-0 -c mysql-coordinator --tail=50
   ```

3. **To continue testing:**
   - Read `setup/chaos-test-report-full.md` for what's done
   - Run new experiments from `1-single-experiments/`, `2-scheduled-experiments/`, or `3-workflows/`
   - Always update the report after each test

4. **Load generator:**
   - Pod: `sysbench-load-849bdc4cdc-h2zpx` in namespace `demo`
   - Command template:
     ```bash
     kubectl exec -n demo sysbench-load-849bdc4cdc-h2zpx -- sysbench oltp_write_only \
       --mysql-host=mysql-ha-cluster.demo.svc.cluster.local \
       --mysql-port=3306 \
       --mysql-user=root \
       --mysql-password='rI3tQLX53C3oX_Zn' \
       --mysql-db=sbtest \
       --tables=12 --table-size=100000 \
       --threads=8 --time=180 --report-interval=2 \
       --percentile=99 run
     ```

## Quick Commands

```bash
# Check cluster
kubectl get mysql -n demo
kubectl get pods -n demo -l app.kubernetes.io/instance=mysql-ha-cluster -L kubedb.com/role

# GR state
kubectl exec -n demo <primary-pod> -- mysql -u root -p'rI3tQLX53C3oX_Zn' \
  -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"

# GTID
kubectl exec -n demo <pod> -- mysql -u root -p'rI3tQLX53C3oX_Zn' \
  -e "SELECT @@gtid_executed\G"

# Apply chaos
kubectl apply -f <chaos-file>.yaml

# Watch chaos
kubectl get podchaos,networkchaos,iochaos,stresschaos,workflow -n chaos-mesh

# Delete chaos
kubectl delete <chaos-type> <name> -n chaos-mesh

# Cleanup tables
kubectl exec -n demo sysbench-load-849bdc4cdc-h2zpx -- sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster.demo.svc.cluster.local --mysql-port=3306 \
  --mysql-user=root --mysql-password='rI3tQLX53C3oX_Zn' --mysql-db=sbtest \
  --tables=12 cleanup

# Prepare tables
kubectl exec -n demo sysbench-load-849bdc4cdc-h2zpx -- sysbench oltp_write_only \
  --mysql-host=mysql-ha-cluster.demo.svc.cluster.local --mysql-port=3306 \
  --mysql-user=root --mysql-password='rI3tQLX53C3oX_Zn' --mysql-db=sbtest \
  --tables=12 --table-size=100000 --threads=4 prepare
```

## Important Notes

1. **DO NOT restart pods** to fix issues — wait for auto-recovery
2. **Always check data integrity** after each experiment (GTID, row counts, checksums)
3. **Update the report** after each experiment
4. **Wait at least 5 minutes** before considering manual intervention
5. The cluster auto-recovers — trust the coordinator
