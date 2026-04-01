# Chaos Testing Session State
# Saved: 2026-04-01 19:05
# Location: /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql

## Cluster State

```
MySQL Version: 8.0.36
Namespace: demo
Cluster Name: mysql-ha-cluster
Status: Ready
Primary: mysql-ha-cluster-1
Replicas: mysql-ha-cluster-0, mysql-ha-cluster-2
```

## Current Pod Status

```
NAME                 READY   STATUS    RESTARTS   AGE    ROLE
mysql-ha-cluster-0   2/2     Running   0          ~15m   standby
mysql-ha-cluster-1   2/2     Running   0          ~15m   primary
mysql-ha-cluster-2   2/2     Running   1          ~55m   standby
```

## MySQL Credentials

```
Password: rI3tQLX53C3oX_Zn
```

## Experiments Completed (10 total)

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

## Experiments Remaining

| Experiment | File | Notes |
|---|---|---|
| DNS Error | `1-single-experiments/dns-error-from-client.yaml` | Failed — Chaos Mesh DNS chaos injection issue |
| Packet Loss GR Port | `1-single-experiments/packet-loss-group-replication.yaml` | targetPort not supported |
| Packet Delay GR Port | `1-single-experiments/packet-delay-group-replication.yaml` | targetPort not supported |
| Scheduled CPU Stress | `2-scheduled-experiments/schedule-weekend-cpu-stress.yaml` | Not tested yet |

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
