# Chaos Engineering for KubeDB MariaDB

This directory contains [Chaos Mesh](https://chaos-mesh.org/) experiments for testing the resilience and high-availability of a [KubeDB](https://kubedb.com/)-managed MariaDB cluster (Galera Cluster) on Kubernetes.

## Directory Structure

```
mariadb/
├── setup/
│   ├── kubedb-mariadb.yaml               # 3-node MariaDB HA cluster (Galera Cluster)
│   ├── sysbench.yaml                     # Sysbench deployment for load testing
│   ├── client-pod.yaml                   # Busybox client pod for connectivity tests
│   ├── secret.yaml                       # Galera wsrep config secret
│   ├── gr-0.sh / gr-1.sh / gr-2.sh      # Galera status check scripts per node
│   ├── soak-test.sh                      # Long-duration soak test
│   ├── insert.sh                         # Insert test data
│   └── insert-eks.sh                     # Insert test data (EKS)
├── 1-single-experiments/
│   ├── pod-kill-primary.yaml                     # Kill a pod → test recovery
│   ├── network-partition-primary.yaml            # Isolate a node from the cluster
│   ├── network-partition-long.yaml               # Long network partition (10 min)
│   ├── network-latency-primary-to-replicas.yaml  # Add 1s replication lag
│   ├── io-latency-primary.yaml                   # Slow disk on a node
│   ├── io-fault-primary.yaml                     # IO errors (EIO) on a node
│   ├── stress-cpu-primary.yaml                   # High CPU on one node
│   ├── stress-cpu-all.yaml                       # High CPU on all nodes
│   ├── stress-memory-primary.yaml                # Memory pressure on one node
│   ├── stress-memory-replica.yaml                # Memory pressure on a node
│   ├── dns-error-primary.yaml                    # DNS failure on a cluster node
│   ├── dns-error-from-client.yaml                # DNS failure from client pod
│   ├── packet-loss.yaml                          # 30% packet loss across cluster
│   ├── packet-loss-galera.yaml                   # Packet loss on Galera port (4567)
│   ├── packet-delay-galera.yaml                  # Packet delay across all nodes
│   ├── clock-skew-primary.yaml                   # Clock skew (-5 min) on a node
│   └── bandwidth-throttle.yaml                   # Bandwidth throttle (1 mbps)
├── 2-scheduled-experiments/
│   ├── schedule-nightly-replica-kill.yaml         # Kill a node every night at 1 AM
│   └── schedule-weekend-cpu-stress.yaml          # CPU stress every weekend
├── 3-workflows/
│   ├── workflow-degraded-failover.yaml           # IO latency + kill node in parallel
│   └── workflow-flaky-network-failover.yaml      # Packet loss → kill node
└── tests/
    ├── 01-pod-failure[-a-e].yaml                 # Pod failure variants
    ├── 02-pod-kill[-a-e].yaml                    # Pod kill variants
    ├── 03-pod-oom[-a-e].yaml                     # OOM kill variants
    ├── 04-kill-mariadb-process[-a-e].yaml        # Container kill variants
    ├── 05-network-partition[-a-e].yaml           # Network partition variants
    ├── 06-network-bandwidth[-a-e].yaml           # Bandwidth limit variants
    ├── 07-network-delay[-a-e].yaml               # Network delay variants
    ├── 08-network-loss[-a-e].yaml                # Packet loss variants
    ├── 09-network-duplicate[-a-e].yaml           # Packet duplicate variants
    ├── 10-network-corrupt[-a-e].yaml             # Packet corruption variants
    ├── 11-time-offset[-a-e].yaml                 # Clock skew variants
    ├── 12-dns-error[-a-e].yaml                   # DNS error variants
    ├── 13-io-latency[-a-e].yaml                  # IO latency variants
    ├── 14-io-fault[-a-e].yaml                    # IO fault variants
    ├── 15-io-attr-override[-a-e].yaml            # IO attribute override variants
    ├── 16-io-mistake[-a-e].yaml                  # IO mistake variants
    ├── 17-node-reboot[-a-e].yaml                 # Node reboot variants
    ├── 18-stress-cpu-primary[-a-e].yaml          # CPU stress variants
    └── 19-stress-memory-replica[-a-e].yaml       # Memory stress variants
```

## Prerequisites

1. A running Kubernetes cluster.
2. `kubectl` configured to connect to your cluster.
3. [KubeDB Operator](https://kubedb.com/docs/latest/setup/) installed.
4. [Helm](https://helm.sh/docs/intro/install/) installed.

## Getting Started

### 0. Install Chaos Mesh

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

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

### 1. Deploy the MariaDB Cluster

```bash
kubectl create namespace demo

# Deploy the 3-node MariaDB Galera cluster
kubectl apply -f setup/kubedb-mariadb.yaml

# Deploy the sysbench load generator
kubectl apply -f setup/sysbench.yaml

# Deploy the client pod
kubectl apply -f setup/client-pod.yaml

# Add label for DNSChaos targeting
kubectl label pod client-pod -n demo pod-name=client-pod
```

Wait for all pods to be running:

```bash
kubectl get pods -n demo -w
```

### 2. Verify Galera Cluster Status

```bash
# Get password
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)

# Check Galera status on each node
for i in 0 1 2; do
  echo "=== md-$i ==="
  kubectl exec -n demo md-$i -c mariadb -- \
    mariadb -uroot -p"$PASS" -e \
    "SHOW GLOBAL STATUS WHERE Variable_name IN (
      'wsrep_cluster_size',
      'wsrep_cluster_status',
      'wsrep_local_state_comment',
      'wsrep_ready',
      'wsrep_connected'
    );"
done
```

Expected output: `wsrep_cluster_size=3`, `wsrep_cluster_status=Primary`, `wsrep_local_state_comment=Synced`, `wsrep_ready=ON`.

### 3. Prepare Sysbench Data

```bash
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Prepare test tables
kubectl exec -n demo $SBPOD -- sysbench oltp_write_only \
    --mysql-host=md --mysql-port=3306 \
    --mysql-user=root --mysql-password="$PASS" \
    --mysql-db=sbtest --tables=4 --table-size=50000 --threads=8 prepare
```

### 4. Run an Experiment

```bash
# Apply a chaos experiment
kubectl apply -f 1-single-experiments/pod-kill-primary.yaml

# Monitor pods
kubectl get pods -n demo -w

# Check Galera status during chaos
bash setup/gr-0.sh

# Clean up
kubectl delete -f 1-single-experiments/pod-kill-primary.yaml
```

---

## Key Differences: MariaDB Galera vs MySQL Group Replication

| | MySQL Group Replication | MariaDB Galera Cluster |
|---|---|---|
| HA mechanism | Group Replication (GR) | Galera (wsrep) |
| Topology | Single-Primary or Multi-Primary | Multi-Master (all nodes read-write) |
| HA port | 33061 (GR) | 4567 (Galera), 4568 (IST), 4444 (SST) |
| Data volume path | `/var/lib/mysql` | `/var/lib/mysql` |
| Check cluster status | `SELECT ... FROM performance_schema.replication_group_members` | `SHOW GLOBAL STATUS LIKE 'wsrep_%'` |
| Container name | `mysql` | `mariadb` |
| CLI client | `mysql` | `mariadb` |
| GTID format | `server_uuid:txn_id` | `domain_id-server_id-seq_no` |

## Galera Status Variables

| Variable | Meaning |
|---|---|
| `wsrep_cluster_size` | Number of nodes in the cluster |
| `wsrep_cluster_status` | `Primary` = cluster is operational |
| `wsrep_local_state_comment` | `Synced` / `Joined` / `Donor` / `Desynced` |
| `wsrep_ready` | `ON` = node accepts queries |
| `wsrep_connected` | `ON` = node connected to cluster |
| `wsrep_flow_control_paused` | Fraction of time paused for flow control (0.0 = good) |

---

## Monitoring During Tests

```bash
# Watch pod restarts and status
kubectl get pods -n demo -w

# Check Galera cluster status
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n demo md-0 -c mariadb -- \
  mariadb -uroot -p"$PASS" -e \
  "SHOW GLOBAL STATUS LIKE 'wsrep_%';"

# Check GTIDs
kubectl exec -n demo md-0 -c mariadb -- \
  mariadb -uroot -p"$PASS" -N -e "SELECT @@gtid_current_pos;"

# Watch events
kubectl get events -n demo --sort-by='.lastTimestamp' -w

# Check active chaos experiments
kubectl get podchaos,networkchaos,iochaos,stresschaos,dnschaos,timechaos -n chaos-mesh
```

## Cleanup

To remove all MariaDB chaos experiments:

```bash
kubectl delete podchaos,networkchaos,iochaos,stresschaos,dnschaos,timechaos,schedule,chaosworkflow \
  -n chaos-mesh --all
```

To tear down the cluster:

```bash
kubectl delete -f setup/kubedb-mariadb.yaml
kubectl delete -f setup/sysbench.yaml
kubectl delete -f setup/client-pod.yaml
```
