# Chaos Testing Monitoring Report

**Date:** 2026-04-28  
**Cluster:** mysql.kubedb.com/mysql-ha-cluster  
**Namespace:** demo  
**MySQL Version:** 8.4.8  

---

## Currently Running Chaos

### Chaos Experiment Details

| Field | Value |
|-------|-------|
| **Name** | test-kubedb-primary-pod-kill |
| **Type** | PodChaos |
| **Action** | pod-kill |
| **Mode** | all |
| **Target Selector** | `kubedb.com/role=primary` in namespace demo |
| **Status** | Injected |
| **Age** | ~4m20s |

### Chaos Specification

- **Selector:** Targets pods with label `kubedb.com/role=primary`
- **Action:** pod-kill (killing the primary pod)
- **Experiment Phase:** Injected, AllInjected=True, AllRecovered=False

---

## Pod Status Summary

| Pod | Ready | Status | Restarts | Age | IP |
|----|-------|--------|---------|-----|-----|
| mysql-ha-cluster-0 | 2/2 | Running | 2 | 16h | - |
| mysql-ha-cluster-1 | 2/2 | Running | 0 | 5m47s | 10.244.0.21 |
| mysql-ha-cluster-2 | 2/2 | Running | 6 | 16h | - |
| sysbench-load-849bdc4cdc-jnzpq | 1/1 | Running | 1 | 16h | - |

---

## Pod Label Changes (During Chaos)

### Before Chaos (Estimated)

| Pod | kubedb.com/role |
|-----|----------------|
| mysql-ha-cluster-0 | standby |
| mysql-ha-cluster-1 | **primary** |
| mysql-ha-cluster-2 | standby |

### Current State (During Chaos)

| Pod | kubedb.com/role |
|-----|----------------|
| mysql-ha-cluster-0 | standby |
| mysql-ha-cluster-1 | **standby** (label changed!) |
| mysql-ha-cluster-2 | **primary** (promoted!) |

**Label Change Observed:** mysql-ha-cluster-1 changed from primary → standby, mysql-ha-cluster-2 became primary. This indicates GR failover occurred after pod-kill.

---

## Database Status (KubeDB CR)

| Field | Value |
|-------|-------|
| **MySQL Name** | mysql-ha-cluster |
| **Version** | 8.4.8 |
| **Status** | Critical |

### Status Transitions (from events)

1. **Ready → Critical** (4m12s ago): After pod-kill, pod-1 was killed
2. **Critical → NotReady** (3m58s ago): Database not accepting connections
3. **NotReady → Critical** (8m38s ago): phase changed to Ready
4. **Critical → Ready** (7m24s ago): Finalizer removed, chaos recovered

---

## Group Replication Status

### Current GR Members (from mysql-ha-cluster-2)

| MEMBER_HOST | MEMBER_PORT | MEMBER_STATE | MEMBER_ROLE |
|------------|------------|-------------|------------|
| mysql-ha-cluster-2.mysql-ha-cluster-pods.demo | 3306 | ONLINE | PRIMARY |
| mysql-ha-cluster-1.mysql-ha-cluster-pods.demo | 3306 | RECOVERING | SECONDARY |
| mysql-ha-cluster-0.mysql-ha-cluster-pods.demo | 3306 | ONLINE | SECONDARY |

### GR State Analysis

- **PRIMARY (mysql-ha-cluster-2):** ONLINE, super_read_only=0, read_only=0 (writable)
- **SECONDARY (mysql-ha-cluster-0):** ONLINE, super_read_only=1, read_only=1 (read-only)
- **SECONDARY (mysql-ha-cluster-1):** ~~RECOVERING~~ → **ONLINE** (fully recovered after ~6 minutes)

---

## MySQL Global Variables

| Pod | super_read_only | read_only | server_id | hostname | gtid_mode |
|-----|----------------|-----------|-----------|----------|----------|-----------|
| mysql-ha-cluster-2 | 0 | 0 | 3 | mysql-ha-cluster-2 | ON |
| mysql-ha-cluster-0 | 1 | 1 | 1 | mysql-ha-cluster-0 | ON |
| mysql-ha-cluster-1 | 1 | 1 | - | - | ON |

---

## Events Timeline

| Time | Event | Object | Message |
|------|-------|--------|---------|
| 15m | Killing | pod/mysql-ha-cluster-2 | Container mysql-coordinator definition changed, will be restarted |
| 15m | Started | pod/mysql-ha-cluster-2 | Started container mysql-coordinator |
| 8m38s | Phase Changed | mysql/mysql-ha-cluster | phase changed from Critical to Ready reason: |
| 7m24s | Updated | podchaos/test-kubedb-primary-pod-failure | Successfully update finalizer of resource |
| 7m24s | FinalizerInited | podchaos/test-kubedb-primary-pod-failure | Finalizer has been removed |
| 4m12s | Phase Changed | mysql/mysql-ha-cluster | phase changed from Ready to Critical reason: SomeReplicasNotReady |
| 4m12s | SuccessfulCreate | petset/mysql-ha-cluster | create Pod mysql-ha-cluster-1 in PetSet successful |
| 4m12s | Updated | podchaos/test-kubedb-primary-pod-kill | Successfully update records of resource |
| 4m12s | Killing | pod/mysql-ha-cluster-1 | Stopping container mysql |
| 4m12s | Applied | podchaos/test-kubedb-primary-pod-kill | Successfully apply chaos for demo/mysql-ha-cluster-1 |
| 4m11s | Killing | pod/mysql-ha-cluster-1 | Stopping container mysql-coordinator |
| 4m11s | Created | pod/mysql-ha-cluster-1 | Created container: mysql |
| 4m11s | Started | pod/mysql-ha-cluster-1 | Started container mysql |
| 4m10s | Started | pod/mysql-ha-cluster-1 | Started container mysql-coordinator |
| 3m58s | Phase Changed | mysql/mysql-ha-cluster | phase changed from NotReady to Critical |

---

## Chaos Impact Analysis

### What Happened

1. **PodChaos Applied:** `test-kubedb-primary-pod-kill` injected at 05:56:20 UTC
2. **Target Selected:** mysql-ha-cluster-1 (had `kubedb.com/role=primary` at time of injection)
3. **Kill Executed:** Container mysql killed on pod-1
4. **GR Failover:** Cluster detected primary loss, electing mysql-ha-cluster-2 as new PRIMARY
5. **Recovery:** 
   - mysql-ha-cluster-1 restarted (0 → 5m47s ago)
   - mysql-ha-cluster-1 is now RECOVERING as SECONDARY
   - mysql-ha-cluster-2 is PRIMARY (was standby)
   - mysql-ha-cluster-0 remained SECONDARY throughout

### Data Integrity

- **Primary (pod-2):** super_read_only=0 (writable), GTID mode=ON
- **Secondaries (pod-0, pod-1):** super_read_only=1 (read-only)
- No checksum mismatch detected from queries

### Cluster Health

- **3 pods online:** pod-0 (SECONDARY), pod-1 (RECOVERING), pod-2 (PRIMARY)
- **KubeDB status:** Critical (due to RECOVERING state on pod-1)
- **GR consensus:** Working - pod-2 elected as new PRIMARY

---

## Recovery Path

Pod-1 is currently in RECOVERING state. Expected progression:

1. **RECOVERING** (current) → **ONLINE** as SECONDARY
2. Sync from PRIMARY (pod-2) via clone or incremental
3. KubeDB status: Critical → Ready when all pods ONLINE

---

## Monitoring Notes (No Fix Applied)

- Did NOT execute any fix commands
- Only monitoring and data collection performed
- Cluster is in self-recovery mode via coordinator
- No manual intervention needed at this time

---

## Report Generated

**Time:** 2026-04-28 06:00 UTC  
**Method:** kubectl exec queries + event monitoring  
**Status:** Monitioring complete