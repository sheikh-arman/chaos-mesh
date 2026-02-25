# Chaos Engineering for KubeDB MySQL

This directory contains [Chaos Mesh](https://chaos-mesh.org/) experiments for testing the resilience and high-availability of a [KubeDB](https://kubedb.com/)-managed MySQL cluster (Group Replication) on Kubernetes.

## Directory Structure

```
mysql/
├── setup/
│   ├── kubedb-mysql.yaml          # 3-node MySQL HA cluster (Group Replication)
│   └── client-pod.yaml            # Busybox client pod for connectivity tests
├── 1-single-experiments/
│   ├── pod-kill-primary.yaml                  # Kill primary pod → test failover
│   ├── network-partition-primary.yaml         # Isolate primary from replicas
│   ├── network-latency-primary-to-replicas.yaml  # Add 1s replication lag
│   ├── io-latency-primary.yaml                # Slow disk on primary
│   ├── stress-cpu-primary.yaml                # High CPU on primary
│   ├── stress-memory-replica.yaml             # High memory on a replica
│   ├── dns-error-from-client.yaml             # DNS failure from client pod
│   ├── packet-loss.yaml                       # 30% packet loss across cluster
│   ├── packet-loss-group-replication.yaml     # Packet loss on GR port (33061)
│   └── packet-delay-group-replication.yaml    # Packet delay across all nodes
├── 2-scheduled-experiments/
│   ├── schedule-nightly-replica-kill.yaml     # Kill a replica every night at 1 AM
│   └── schedule-weekend-cpu-stress.yaml       # CPU stress on primary every weekend
└── 3-workflows/
    ├── workflow-degraded-failover.yaml        # IO latency + kill primary in parallel
    └── workflow-flaky-network-failover.yaml   # Packet loss to replica, then kill primary
```

## Prerequisites

1. A running Kubernetes cluster.
2. `kubectl` configured to connect to your cluster.
3. [KubeDB Operator](https://kubedb.com/docs/latest/setup/) installed.
4. [Helm](https://helm.sh/docs/intro/install/) installed.

## Getting Started

### 0. Install Chaos Mesh

Chaos Mesh must be installed before applying any experiment files. Without it, you will get:
> `no matches for kind "PodChaos" in version "chaos-mesh.org/v1alpha1"`

```bash
# Add the Chaos Mesh Helm repo
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

# Install Chaos Mesh into the chaos-mesh namespace
helm upgrade -i chaos-mesh chaos-mesh/chaos-mesh \
    -n chaos-mesh \
    --create-namespace \
    --set dashboard.create=true \
    --set dashboard.securityMode=false \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set chaosDaemon.privileged=true
```

Wait for all Chaos Mesh pods to be running:

```bash
kubectl get pods -n chaos-mesh -w
```

Verify the CRDs are registered:

```bash
kubectl get crd | grep chaos-mesh
```

You should see CRDs like `podchaos.chaos-mesh.org`, `networkchaos.chaos-mesh.org`, etc.

> **Note:** If your cluster uses Docker instead of containerd, change `--set chaosDaemon.runtime=docker` and `--set chaosDaemon.socketPath=/var/run/docker.sock`.

### 1. Deploy the MySQL Cluster

```bash
# Create the namespace
kubectl create namespace demo

# Deploy the 3-node MySQL cluster
kubectl apply -f setup/kubedb-mysql.yaml

# Deploy the client pod
kubectl apply -f setup/client-pod.yaml

# Add label for DNSChaos targeting
kubectl label pod client-pod -n demo pod-name=client-pod
```

Wait for all pods to be running:

```bash
kubectl get pods -n demo -w
```

### 2. Verify Roles

```bash
# Find the primary
kubectl get pods -n demo -l app.kubernetes.io/instance=mysql-ha-cluster,kubedb.com/role=primary

# Find the replicas
kubectl get pods -n demo -l app.kubernetes.io/instance=mysql-ha-cluster,kubedb.com/role=replica
```

### 3. Run an Experiment

Apply any experiment file:

```bash
kubectl apply -f 1-single-experiments/pod-kill-primary.yaml
```

Monitor the pods during the experiment:

```bash
kubectl get pods -n demo -w
```

Check Group Replication status from inside a pod:

```bash
kubectl exec -it <pod-name> -n demo -- mysql -u root -p \
  -e "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"
```

Clean up the experiment when done:

```bash
kubectl delete -f 1-single-experiments/pod-kill-primary.yaml
```

---

## Experiment Reference

### Single Experiments (`1-single-experiments/`)

| File | Chaos Type | What It Tests |
|---|---|---|
| `pod-kill-primary.yaml` | PodChaos | Automatic primary failover via Group Replication |
| `network-partition-primary.yaml` | NetworkChaos | Split-brain prevention when primary is isolated |
| `network-latency-primary-to-replicas.yaml` | NetworkChaos | Replication lag tolerance (1s delay + 50ms jitter) |
| `io-latency-primary.yaml` | IOChaos | Slow disk on primary — query performance degradation |
| `stress-cpu-primary.yaml` | StressChaos | High CPU load (80%) on primary — throughput impact |
| `stress-memory-replica.yaml` | StressChaos | Memory pressure (512MB) on replica — OOMKill recovery |
| `dns-error-from-client.yaml` | DNSChaos | Client cannot resolve the MySQL service DNS name |
| `packet-loss.yaml` | NetworkChaos | 30% packet loss across entire cluster |
| `packet-loss-group-replication.yaml` | NetworkChaos | Packet loss specifically on GR port 33061 |
| `packet-delay-group-replication.yaml` | NetworkChaos | Network delay across all cluster nodes |

### Scheduled Experiments (`2-scheduled-experiments/`)

| File | Schedule | What It Tests |
|---|---|---|
| `schedule-nightly-replica-kill.yaml` | Every night at 1 AM | Replica recovery and re-join to group |
| `schedule-weekend-cpu-stress.yaml` | Saturdays and Sundays at 4 AM | Sustained CPU stress (90% for 30 min) on primary |

### Workflow Experiments (`3-workflows/`)

| File | Pattern | What It Tests |
|---|---|---|
| `workflow-degraded-failover.yaml` | Parallel: IO latency + kill primary | Failover under storage duress |
| `workflow-flaky-network-failover.yaml` | Serial: packet loss to replica → kill primary | Ensures the healthy replica is elected, not the degraded one |

---

## Key Differences vs PostgreSQL Chaos Tests

| | PostgreSQL | MySQL |
|---|---|---|
| Role labels | `kubedb.com/role: standby` | `kubedb.com/role: replica` |
| Cluster HA mechanism | Patroni + etcd (Raft) | Group Replication |
| HA port | 2379, 2380 (etcd) | 33061 (GR) |
| Data volume path | `/var/lib/postgresql/data` | `/var/lib/mysql` |
| Check replication status | `SELECT pg_is_in_recovery()` | `SELECT ... FROM performance_schema.replication_group_members` |
| Process name | `postgres` | `mysqld` |

---

## Monitoring During Tests

```bash
# Watch pod restarts and status
kubectl get pods -n demo -w

# Check Group Replication member states
kubectl exec -it <pod-name> -n demo -- mysql -u root -p \
  -e "SELECT * FROM performance_schema.replication_group_members\G"

# Check replication applier status
kubectl exec -it <pod-name> -n demo -- mysql -u root -p \
  -e "SELECT * FROM performance_schema.replication_group_member_stats\G"

# Watch events in the demo namespace
kubectl get events -n demo --sort-by='.lastTimestamp' -w

# Check active chaos experiments
kubectl get podchaos,networkchaos,iochaos,stresschaos,dnschaos -n chaos-mesh
```

## Cleanup

To remove all MySQL chaos experiments:

```bash
kubectl delete podchaos,networkchaos,iochaos,stresschaos,dnschaos,schedule,chaosworkflow \
  -n chaos-mesh -l app.kubernetes.io/instance=mysql-ha-cluster
```

To tear down the cluster:

```bash
kubectl delete -f setup/kubedb-mysql.yaml
kubectl delete -f setup/client-pod.yaml
```
