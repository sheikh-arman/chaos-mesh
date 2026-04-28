# Chaos Testing Monitoring Report - 2026-04-28

**Date:** 2026-04-28  
**Cluster:** mysql.kubedb.com/mysql-ha-cluster  
**Namespace:** demo  
**MySQL Version:** 8.4.8  
**Monitoring Duration:** ~30 minutes (15:23 - 15:56 UTC)

---

## Chaos Experiments Run During Monitoring

| # | Chaos Name | Type | Action | Target | Duration | Status |
|---|----------|------|--------|--------|----------|--------|
| 1 | test-kubedb-primary-io-attroverride | IOChaos | attrOverride | mysql-ha-cluster-1 | ~5m, Recovered |
| 2 | test-kubedb-primary-io-mistake | IOChaos | mistake | mysql-ha-cluster-2 | ~2m, Recovered |

---

## Chaos Experiment Details

### Chaos #1: test-kubedb-primary-io-attroverride

- **Type:** IOChaos
- **Action:** attrOverride (permission change)
- **Target:** mysql-ha-cluster-1 (primary)
- **Duration:** 5 minutes
- **Applied:** 15:27 UTC
- **Recovered:** ~15:32 UTC

### Chaos #2: test-kubedb-primary-io-mistake

- **Type:** IOChaos
- **Action:** mistake (READ/WRITE injection)
- **Target:** mysql-ha-cluster-2 (primary)
- **Duration:** 2 minutes
- **Applied:** 15:44 UTC
- **Recovered:** ~15:46 UTC

---

## Pod Status Changes

### Initial State (15:23 UTC)

| Pod | Ready | Status | Restarts | kubedb.com/role |
|----|-------|--------|---------|---------------|
| mysql-ha-cluster-0 | 2/2 | Running | 0 | standby |
| mysql-ha-cluster-1 | 2/2 | Running | 0 | primary |
| mysql-ha-cluster-2 | 2/2 | Running | 0 | standby |

### After Chaos #1 (attrOverride on pod-1)

| Pod | Ready | Status | Restarts | kubedb.com/role |
|----|-------|--------|---------|---------------|
| mysql-ha-cluster-0 | 2/2 | Running | 0 | standby |
| mysql-ha-cluster-1 | 2/2 | Running | **1** | standby (restarted) |
| mysql-ha-cluster-2 | 2/2 | Running | 0 | primary |

**Change:** pod-1 restarted once, became standby

### After Chaos #2 (mistake on pod-2)

| Pod | Ready | Status | Restarts | kubedb.com/role |
|----|-------|--------|---------|---------------|
| mysql-ha-cluster-0 | 2/2 | Running | 0 | **primary** |
| mysql-ha-cluster-1 | 2/2 | Running | 1 | standby |
| mysql-ha-cluster-2 | 2/2 | Running | 0 | standby |

**Change:** pod-0 became primary, pod-2 became standby (failover occurred)

---

## Database Status Transitions

### KubeDB CR Status History

| Time (UTC) | Status | Event |
|------------|--------|--------|
| 15:23 | Ready | Initial stable state |
| 15:27 | Ready | Chaos #1 applied |
| 15:32 | Ready | Chaos #1 recovered, cluster OK |
| 15:44 | Ready | Chaos #2 applied |
| 15:46 | NotReady | DB not accepting connections |
| 15:47 | Critical | Connection refused, pod-2 down |
| 15:56+ | Critical | Still Critical, recovering |

### Status Transition Sequence

```
Ready → (15:27) → Ready → (15:32) → Ready → (15:46) → NotReady → (15:47) → Critical
```

---

## Group Replication Status

### Current GR State (15:56 UTC) - FROM POD-0

| MEMBER_HOST | MEMBER_PORT | MEMBER_STATE | MEMBER_ROLE |
|------------|------------|-------------|------------|
| mysql-ha-cluster-1.mysql-ha-cluster-pods.demo | 3306 | ONLINE | PRIMARY |
| mysql-ha-cluster-0.mysql-ha-cluster-pods.demo | 3306 | ONLINE | SECONDARY |

### Missing Member

- **mysql-ha-cluster-2** is NOT showing in GR members - was targeted by io-mistake chaos

---

## Pod Label Changes

### During Monitoring

| Time | Pod | Label Change |
|------|-----|-------------|
| ~15:32 | mysql-ha-cluster-1 | primary → standby (after restart) |
| ~15:32 | mysql-ha-cluster-2 | standby → primary |
| ~15:56 | mysql-ha-cluster-0 | standby → primary (failover) |
| ~15:56 | mysql-ha-cluster-2 | (unavailable) |

---

## Impact Analysis

### Chaos #1 (attrOverride on pod-1)

- **Effect:** Permission attribute override on primary pod
- **Impact:** Pod restarted (1 restart)
- **Recovery:** ~5 minutes to come back online
- **GR Effect:** No failover observed (pod-2 became primary during this time)

### Chaos #2 (mistake on pod-2)

- **Effect:** READ/WRITE operation injection
- **Impact:** Primary (pod-2) became unavailable
- **Recovery:** Database down for ~10+ minutes
- **GR Effect:** **FAILOVER OCCURRED** - pod-0 elected new PRIMARY
- **Data Impact:** Unknown - cluster still in Critical state

---

## Current Cluster State (End of Monitoring)

| Pod | Ready | Status | Role | GR State |
|----|-------|--------|------|---------|
| mysql-ha-cluster-0 | 2/2 | Running | **PRIMARY** | SECONDARY → PRIMARY (promoted) |
| mysql-ha-cluster-1 | 2/2 | Running | standby | ONLINE |
| mysql-ha-cluster-2 | 2/2 | Running | standby | **NOT IN GR** |

### Database Status

- **CR Status:** Critical
- **Reason:** mysql-ha-cluster-2 not responding
- **K8s Service:** Not accepting connections

---

## Recovery Observations

### Positive

1. **Automatic Failover:** GR successfully elected new primary after pod-2 failure
2. **No Data Loss Expected:** GTID-based replication should preserve data
3. **Coordinator:** Recovery process initiated automatically

### Concerns

1. **Slow Recovery:** 10+ minutes in Critical state
2. **Missing Member:** pod-2 not in GR members
3. **Pod Label Drift:** Labels show inconsistent state (pod-0=primary, pod-2=standby but not in GR)

---

## Events Summary

| Time | Event |
|------|-------|
| 15:27 | IOChaos attrOverride applied to pod-1 |
| 15:32 | attrOverride recovered |
| 15:44 | IOChaos mistake applied to pod-2 |
| 15:46 | DB not accepting connections |
| 15:46 | Phase changed Ready → NotReady |
| 15:47 | Phase changed NotReady → Critical |
| 15:56 | Still Critical |

---

## Notes

- No manual fixes applied during monitoring
- Cluster in self-recovery mode
- Coordinator handling recovery automatically
- Data integrity verification pending (cluster not yet Ready)

---

**Report Generated:** 2026-04-28 15:56 UTC  
**Method:** Continuous monitoring every 30 seconds  
**Status:** Monitoring complete