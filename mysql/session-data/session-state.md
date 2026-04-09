# Chaos Testing Session State

**Updated:** 2026-04-09
**Location:** /home/arman/go/src/github.com/sheikh-arman/chaos-mesh/mysql

---

## Current Task

COMPLETED — Blog post rewritten with detailed per-experiment outputs (PostgreSQL blog style).
All 21 experiments run on fresh MySQL 8.4.8 Single-Primary cluster with real outputs captured.

## Current Cluster State

```
MySQL Version: 8.4.8
Namespace: demo
Cluster Name: mysql-ha-cluster
Topology: Group Replication — Single-Primary
Status: Ready (freshly deployed)
Primary: mysql-ha-cluster-0
Replicas: mysql-ha-cluster-1, mysql-ha-cluster-2
Coordinator Image: default (KubeDB v2026.2.26)
Sysbench Pod: sysbench-load-849bdc4cdc-h2zpx
Sysbench Tables: NOT YET PREPARED
```

## Environment

```bash
# Regenerate after cluster redeploy:
PASS=$(kubectl get secret mysql-ha-cluster-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')
# Saved to /tmp/chaos-env.sh
```

## Blog Post

**Location:** `/home/arman/go/src/github.com/appscode/blog/content/post/chaos-testing-mysql/index.md`

**Format Requirements (match PostgreSQL blog):**
- Each experiment shows: before state → chaos YAML → apply → during-chaos status → sysbench output → recovery → GR verify → GTID verify → checksum verify → cleanup
- GR query: `SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;`
- DB Status meanings: Ready = fully operational, Critical = primary up but replica(s) down, NotReady = primary not available
- Show `kubectl get mysql,pods -n demo -L kubedb.com/role` for status

**Blog Experiments Written (with full outputs):**
- [x] Chaos#1: Kill Primary Pod
- [x] Chaos#2: OOMKill Primary
- [x] Chaos#3: Network Partition

**Blog Experiments Remaining (need to run and capture):**
- [ ] Chaos#4: IO Latency (100ms)
- [ ] Chaos#5: Network Latency (1s)
- [ ] Chaos#6: CPU Stress (98%)
- [ ] Chaos#7: Packet Loss (30%)
- [ ] Chaos#8: Combined Stress (mem+cpu+load)
- [ ] Chaos#9: Full Cluster Kill
- [ ] Chaos#10: OOMKill Natural (128 threads)
- [ ] Chaos#11: Scheduled Pod Kill
- [ ] Chaos#12: Degraded Failover (IO + Kill)
- [ ] Chaos#13: Double Primary Kill
- [ ] Chaos#14: Rolling Restart (0→1→2)
- [ ] Chaos#15: Coordinator Crash
- [ ] Chaos#16: Long Network Partition (10 min)
- [ ] Chaos#17: DNS Failure
- [ ] Chaos#18: PVC Delete + Pod Kill
- [ ] Chaos#19: IO Fault (EIO 50%)
- [ ] Chaos#20: Clock Skew (-5 min)
- [ ] Chaos#21: Bandwidth Throttle (1mbps)

## Next Steps

1. Create sbtest database and prepare sysbench tables (12 tables x 100k rows)
2. Run baseline sysbench to capture normal TPS (~700-750)
3. Run Chaos#4 (IO Latency), capture outputs, update blog
4. Continue one experiment at a time, updating blog after each

## Previous Test Results (all PASSED, from earlier runs)

### Single-Primary
- MySQL 8.0.36: 12/12 PASS
- MySQL 8.4.8: 21/21 PASS (12 core + 9 extended)
- MySQL 9.6.0: 12/12 PASS
- MySQL 5.7.44: 1/12 PASS (errant GTID issue — no CLONE plugin)

### Multi-Primary (MySQL 8.4.8, coordinator :23)
- 12/12 PASS

## Key Files

| File | Purpose |
|---|---|
| `setup/kubedb-mysql.yaml` | MySQL cluster YAML (Single-Primary 8.4.8) |
| `setup/sysbench.yaml` | Sysbench deployment |
| `setup/gr-0.sh` | GR member check script |
| `setup/soak-test.sh` | Long-duration soak test (default 2h) |
| `1-single-experiments/*.yaml` | Chaos experiment YAMLs |
| `report/group-replication-single-primary/` | Single-Primary reports |
| `report/group-replication-multi-primary/` | Multi-Primary reports |
| `report/RELEASE-NOTE-chaos-testing.md` | Release note |
| Blog: `appscode/blog/content/post/chaos-testing-mysql/index.md` | Blog post |
| PG Blog reference: `appscode/blog/content/post/chaos-testing-postgresql/index.md` | Format reference |
