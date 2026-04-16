# Chaos Engineering KubeDB MariaDB on Kubernetes — Testing Galera Cluster Resilience

## Overview

We conducted **12 chaos experiments** on a **MariaDB 11.8.5** Galera Cluster managed by KubeDB on Kubernetes. The goal: validate that KubeDB MariaDB delivers **zero data loss**, **automatic recovery**, and **self-healing** under realistic failure conditions with production-level read-write loads.

## Why Chaos Testing?

Running databases on Kubernetes introduces failure modes that traditional infrastructure does not have — pods can be evicted, nodes can go down, network policies can partition traffic, and resource limits can trigger OOMKills at any time. Chaos engineering deliberately injects these failures to verify that the system recovers correctly **before** they happen in production.

For a MariaDB Galera Cluster managed by KubeDB, we needed to answer:

- Does the cluster **lose data** when a node is killed mid-transaction?
- Does the cluster **survive** network partitions without split-brain?
- Can the cluster **self-heal** after a full outage with no manual intervention?
- Are **checksums consistent** across all nodes after recovery?
- Does the cluster survive **combined failures** (CPU stress, IO faults, clock skew)?

## Test Environment

| Component | Details |
|---|---|
| Kubernetes | kind (local cluster) |
| KubeDB Version | 2026.2.26 |
| Cluster Topology | 3-node Galera Cluster (all nodes read-write) |
| MariaDB Version | 11.8.5 |
| Storage | 500Mi PVC per node (Durable, ReadWriteOnce) |
| Memory Limit | 1.5Gi per MariaDB pod |
| CPU Request | 500m per pod |
| Chaos Engine | Chaos Mesh |
| Load Generator | sysbench `oltp_read_write`, 4 tables x 50k rows, 4 threads |
| Baseline TPS | ~1,039 |

All experiments were run under **sustained sysbench read-write load** to simulate production traffic during failures.

## Setup Guide

### Step 1: Create a kind Cluster

```bash
kind create cluster --name chaos-test
```

### Step 2: Install KubeDB

```bash
helm install kubedb oci://ghcr.io/appscode-charts/kubedb \
  --version v2026.2.26 \
  --namespace kubedb --create-namespace \
  --set-file global.license=/path/to/license.txt \
  --wait --burst-limit=10000 --debug
```

### Step 3: Install Chaos Mesh

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update chaos-mesh

helm upgrade -i chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh --create-namespace \
  --set dashboard.create=true \
  --set dashboard.securityMode=false \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set chaosDaemon.privileged=true
```

### Step 4: Deploy MariaDB Galera Cluster

Create the namespace:

```bash
kubectl create namespace demo
```

```yaml
apiVersion: kubedb.com/v1
kind: MariaDB
metadata:
  name: md
  namespace: demo
spec:
  deletionPolicy: Delete
  replicas: 3
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 500Mi
  storageType: Durable
  podTemplate:
    spec:
      containers:
        - name: mariadb
          resources:
            limits:
              memory: 1.5Gi
            requests:
              cpu: 500m
              memory: 1.5Gi
  topology:
    mode: GaleraCluster
  version: 11.8.5
```

Deploy and wait for Ready:

```bash
kubectl apply -f kubedb-mariadb.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Ready mariadb/md -n demo --timeout=5m
```

### Step 5: Deploy sysbench Load Generator

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sysbench-load
  namespace: demo
  labels:
    app: sysbench
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sysbench
  template:
    metadata:
      labels:
        app: sysbench
    spec:
      containers:
        - name: sysbench
          image: perconalab/sysbench:latest
          command: ["/bin/sleep", "infinity"]
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
          env:
            - name: MYSQL_HOST
              value: "md.demo.svc.cluster.local"
            - name: MYSQL_PORT
              value: "3306"
            - name: MYSQL_USER
              value: "root"
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: md-auth
                  key: password
            - name: MYSQL_DB
              value: "sbtest"
```

```bash
kubectl apply -f sysbench.yaml
```

### Step 6: Prepare sysbench Tables

```bash
# Get the MariaDB root password
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)

# Create the sbtest database
kubectl exec -n demo md-0 -c mariadb -- \
  mariadb -uroot -p"$PASS" -e "CREATE DATABASE IF NOT EXISTS sbtest;"

# Get the sysbench pod name
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Prepare tables (4 tables x 50k rows)
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 --table-size=50000 \
  --threads=4 prepare
```

### Step 7: Run sysbench During Chaos

```bash
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 --table-size=50000 \
  --threads=4 --time=60 --report-interval=10 run
```

## Galera Cluster Key Concepts

Unlike MySQL Group Replication which has a single primary and secondaries, MariaDB Galera Cluster is **multi-master** — all nodes accept reads and writes simultaneously. Key status variables:

| Variable | Meaning |
|---|---|
| `wsrep_cluster_size` | Number of nodes in the cluster |
| `wsrep_cluster_status` | `Primary` = cluster has quorum and is operational |
| `wsrep_local_state_comment` | `Synced` / `Joined` / `Donor` / `Desynced` |
| `wsrep_ready` | `ON` = node accepts queries |
| `wsrep_connected` | `ON` = node connected to cluster |
| `wsrep_flow_control_paused` | Fraction of time paused for flow control (0.0 = healthy) |

> **Important Notes on Database Status:**
> - **`Ready`** — Database is fully operational. All pods are Synced.
> - **`Critical`** — Cluster has quorum but one or more nodes may be down or desynced.
> - **`NotReady`** — Cluster has lost quorum. No writes can be accepted.
>
> You can read/write in your database in both **`Ready`** and **`Critical`** states. Even if your db is in `Critical` state, your uptime is not compromised.

## Chaos Testing

We will run chaos experiments to see how our Galera cluster behaves under failure scenarios. We use sysbench to simulate high read-write load during each experiment.

### Verify Cluster is Ready

Before starting chaos experiments, verify the cluster is healthy:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    68m

NAME                                 READY   STATUS    RESTARTS      AGE    ROLE
pod/md-0                             2/2     Running   1 (34m ago)   68m    Primary
pod/md-1                             2/2     Running   0             12m    Primary
pod/md-2                             2/2     Running   0             68m    Primary
```

Note: In Galera Cluster, **all nodes have role `Primary`** because every node accepts reads and writes.

Inspect the Galera cluster status:

```shell
➤ kubectl exec -n demo md-0 -c mariadb -- \
    mariadb -uroot -p"$PASS" -e "SHOW GLOBAL STATUS WHERE Variable_name IN (
      'wsrep_cluster_size','wsrep_cluster_status',
      'wsrep_local_state_comment','wsrep_ready',
      'wsrep_connected','wsrep_flow_control_paused');"
Variable_name              Value
wsrep_flow_control_paused  0
wsrep_local_state_comment  Synced
wsrep_cluster_size         3
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON
```

All 3 nodes Synced, cluster_size=3, wsrep_ready=ON. With the cluster ready and sysbench tables prepared, we are ready to run chaos experiments.

---

### Chaos#1: Kill a Pod

We kill one MariaDB pod and see how fast the Galera cluster recovers. In Galera, since all nodes are equal, killing any node should be handled gracefully.

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: mariadb-primary-pod-kill
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - demo
    labelSelectors:
      "app.kubernetes.io/instance": "md"
      "kubedb.com/role": "Primary"
  gracePeriod: 0
```

**What this chaos does:** Terminates one MariaDB pod abruptly with `grace-period=0`, forcing the remaining 2 nodes to handle all traffic while the killed pod recovers.

Before running:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    68m

NAME       READY   STATUS    RESTARTS      AGE   ROLE
pod/md-0   2/2     Running   1 (34m ago)   68m   Primary
pod/md-1   2/2     Running   0             12m   Primary
pod/md-2   2/2     Running   0             68m   Primary
```

Apply the chaos:

```shell
➤ kubectl apply -f 1-single-experiments/pod-kill-primary.yaml
podchaos.chaos-mesh.org/mariadb-primary-pod-kill created
```

Within seconds, one pod is killed and recreated. The database goes `Critical` briefly:

```shell
➤ kubectl get mariadb,pods -n demo
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    68m

NAME       READY   STATUS    RESTARTS   AGE
pod/md-0   2/2     Running   0          8s
pod/md-1   2/2     Running   0          12m
pod/md-2   2/2     Running   0          68m
```

md-0 was killed and recreated (age=8s). After about 5 seconds, the pod rejoins the Galera cluster and syncs via IST (Incremental State Transfer). Check Galera status:

```shell
➤ SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status',
    'wsrep_local_state_comment','wsrep_ready','wsrep_connected');

md-0:
Variable_name              Value
wsrep_local_state_comment  Synced
wsrep_cluster_size         3
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON

md-1:
Variable_name              Value
wsrep_local_state_comment  Synced
wsrep_cluster_size         3
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON

md-2:
Variable_name              Value
wsrep_local_state_comment  Synced
wsrep_cluster_size         3
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON
```

All 3 nodes Synced. Run sysbench to verify the cluster is fully operational:

```shell
➤ sysbench oltp_read_write ... --time=15 --report-interval=5 run
[ 5s ] thds: 4 tps: 1063.05 qps: 21272.82 (r/w/o: 14891.32/2327.87/4053.63) lat (ms,95%): 5.00 err/s: 0.00 reconn/s: 0.00
[ 10s ] thds: 4 tps: 1059.67 qps: 21198.98 (r/w/o: 14840.36/2343.15/4015.46) lat (ms,95%): 4.91 err/s: 0.20 reconn/s: 0.00
[ 15s ] thds: 4 tps: 1060.19 qps: 21202.99 (r/w/o: 14841.86/2407.58/3953.56) lat (ms,95%): 4.91 err/s: 0.00 reconn/s: 0.00

SQL statistics:
    transactions:                        15919  (1060.99 per sec.)
    queries:                             318397 (21220.87 per sec.)
    ignored errors:                      1      (0.07 per sec.)
    reconnects:                          0      (0.00 per sec.)
```

Verify data integrity:

```shell
➤ # Tracking rows — all match
md-0 markers: 25
md-1 markers: 25
md-2 markers: 25

➤ # Checksums — all match
md-0: sbtest1=2941988609, sbtest2=1454430013, sbtest3=496174579, sbtest4=1322761405
md-1: sbtest1=2941988609, sbtest2=1454430013, sbtest3=496174579, sbtest4=1322761405
md-2: sbtest1=2941988609, sbtest2=1454430013, sbtest3=496174579, sbtest4=1322761405
```

**Result: PASS** — Zero data loss. Pod recreated in ~5 seconds, auto-rejoined via IST. All 25 tracking rows preserved, checksums match across all 3 nodes. Post-recovery throughput: 1061 TPS (back to baseline).

Clean up:

```shell
➤ kubectl delete -f 1-single-experiments/pod-kill-primary.yaml
podchaos.chaos-mesh.org "mariadb-primary-pod-kill" deleted
```

---

### Chaos#2: OOMKill (Memory Stress)

We stress-test memory on one node to see if the cluster survives under extreme memory pressure.

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: mariadb-primary-memory-stress
  namespace: chaos-mesh
spec:
  mode: one
  selector:
    namespaces:
      - demo
    labelSelectors:
      "app.kubernetes.io/instance": "md"
      "kubedb.com/role": "Primary"
  stressors:
    memory:
      workers: 2
      size: "1200MB"
  duration: "10m"
```

**What this chaos does:** Allocates 1200MB of extra memory on one pod. With MariaDB's memory usage, this approaches the 1.5Gi limit.

Apply the chaos:

```shell
➤ kubectl apply -f 1-single-experiments/stress-memory-primary.yaml
stresschaos.chaos-mesh.org/mariadb-primary-memory-stress created
```

After 20 seconds, check pods — no OOMKill triggered:

```shell
➤ kubectl get mariadb,pods -n demo
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    76m

NAME       READY   STATUS    RESTARTS   AGE
pod/md-0   2/2     Running   0          7m54s
pod/md-1   2/2     Running   0          20m
pod/md-2   2/2     Running   0          76m
```

MariaDB survived at 1200MB stress — no OOMKill. Run sysbench during stress:

```shell
➤ sysbench oltp_read_write ... --time=15 --report-interval=5 run
[ 5s ] thds: 4 tps: 1051.05 qps: 21032.31 (r/w/o: 14723.04/2446.84/3862.43) lat (ms,95%): 4.91 err/s: 0.00 reconn/s: 0.00
[ 10s ] thds: 4 tps: 1046.48 qps: 20930.60 (r/w/o: 14652.32/2489.19/3789.09) lat (ms,95%): 5.00 err/s: 0.00 reconn/s: 0.00
[ 15s ] thds: 4 tps: 1052.99 qps: 21064.27 (r/w/o: 14745.71/2533.78/3784.78) lat (ms,95%): 4.91 err/s: 0.20 reconn/s: 0.00

SQL statistics:
    transactions:                        15757  (1050.21 per sec.)
    queries:                             315156 (21005.21 per sec.)
    ignored errors:                      1      (0.07 per sec.)
    reconnects:                          0      (0.00 per sec.)
```

Verify data integrity:

```shell
➤ # Tracking rows — all match
md-0 markers: 25
md-1 markers: 25
md-2 markers: 25

➤ # Checksums — all match
md-0: sbtest1=3400554968, sbtest2=1909458598
md-1: sbtest1=3400554968, sbtest2=1909458598
md-2: sbtest1=3400554968, sbtest2=1909458598
```

**Result: PASS** — MariaDB survived 1200MB memory stress without OOMKill. Cluster fully operational at 1050 TPS (no degradation). All 25 tracking rows preserved, checksums match.

Clean up:

```shell
➤ kubectl delete -f 1-single-experiments/stress-memory-primary.yaml
stresschaos.chaos-mesh.org "mariadb-primary-memory-stress" deleted
```

---

### Chaos#3: Network Partition

We isolate one Galera node from the other two for 2 minutes. This tests whether the remaining nodes maintain quorum and continue serving traffic, and whether the isolated node rejoins cleanly.

```yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: mariadb-primary-network-partition
  namespace: chaos-mesh
spec:
  action: partition
  mode: one
  selector:
    namespaces:
      - demo
    labelSelectors:
      "app.kubernetes.io/instance": "md"
      "kubedb.com/role": "Primary"
  target:
    mode: all
    selector:
      namespaces:
        - demo
      labelSelectors:
        "kubedb.com/role": "Primary"
  direction: both
  duration: "2m"
```

**What this chaos does:** Creates a complete network partition between one node and the rest of the cluster for 2 minutes. The isolated node loses quorum and becomes `non-Primary`. The remaining 2 nodes maintain quorum and continue accepting writes.

Before running:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                    VERSION   STATUS   AGE
mariadb.kubedb.com/md   11.8.5    Ready    82m

NAME       READY   STATUS    RESTARTS   AGE   ROLE
pod/md-0   2/2     Running   0          13m   Primary
pod/md-1   2/2     Running   0          25m   Primary
pod/md-2   2/2     Running   0          82m   Primary

➤ SHOW GLOBAL STATUS ...
wsrep_flow_control_paused  0.0277989
wsrep_local_state_comment  Synced
wsrep_cluster_size         3
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON
```

Apply the chaos:

```shell
➤ kubectl apply -f 1-single-experiments/network-partition-primary.yaml
networkchaos.chaos-mesh.org/mariadb-primary-network-partition created
```

Within ~15 seconds, the isolated node loses quorum. The database goes `Critical`:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                    VERSION   STATUS     AGE
mariadb.kubedb.com/md   11.8.5    Critical   82m

NAME       READY   STATUS    RESTARTS   AGE   ROLE
pod/md-0   2/2     Running   0          14m   Primary
pod/md-1   2/2     Running   0          26m   Primary
pod/md-2   2/2     Running   0          82m   non-Primary
```

Note: md-2 is `non-Primary` — it's the isolated node. Let's check Galera status from each node:

```shell
➤ # md-0 (in quorum):
wsrep_flow_control_paused  0.0257333
wsrep_local_state_comment  Synced
wsrep_cluster_size         2
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON

➤ # md-1 (in quorum):
wsrep_flow_control_paused  0.0209364
wsrep_local_state_comment  Synced
wsrep_cluster_size         2
wsrep_cluster_status       Primary
wsrep_connected            ON
wsrep_ready                ON

➤ # md-2 (ISOLATED):
wsrep_flow_control_paused  0.00670716
wsrep_local_state_comment  Initialized
wsrep_cluster_size         1
wsrep_cluster_status       non-Primary
wsrep_connected            ON
wsrep_ready                OFF
```

The isolated node (md-2) shows `wsrep_cluster_size=1`, `wsrep_cluster_status=non-Primary`, `wsrep_ready=OFF` — it cannot accept queries. The remaining 2 nodes still have quorum (`wsrep_cluster_status=Primary`) and accept both reads and writes.

Run sysbench during the partition:

```shell
➤ sysbench oltp_read_write ... --time=15 --report-interval=5 run
[ 5s ] thds: 4 tps: 1435.24 qps: 28715.89 (r/w/o: 20102.42/3503.22/5110.25) lat (ms,95%): 3.49 err/s: 0.20 reconn/s: 0.00
[ 10s ] thds: 4 tps: 1437.64 qps: 28756.01 (r/w/o: 20129.37/3626.70/4999.94) lat (ms,95%): 3.43 err/s: 0.00 reconn/s: 0.00
[ 15s ] thds: 4 tps: 1416.81 qps: 28336.92 (r/w/o: 19836.08/3607.82/4893.02) lat (ms,95%): 3.55 err/s: 0.00 reconn/s: 0.00

SQL statistics:
    transactions:                        21453  (1429.89 per sec.)
    queries:                             429076 (28598.90 per sec.)
    ignored errors:                      1      (0.07 per sec.)
    reconnects:                          0      (0.00 per sec.)
```

TPS **increased from 1039 to 1430** during partition — a 37% improvement! This is because with only 2 nodes, Galera certification has less overhead (fewer nodes to coordinate with).

After the 2-minute partition expires, the isolated node automatically rejoins:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                    VERSION   STATUS   AGE
mariadb.kubedb.com/md   11.8.5    Ready    85m

NAME       READY   STATUS    RESTARTS   AGE   ROLE
pod/md-0   2/2     Running   0          17m   Primary
pod/md-1   2/2     Running   0          29m   Primary
pod/md-2   2/2     Running   0          85m   Primary
```

All 3 nodes back to `Primary`, cluster `Ready`. Verify:

```shell
➤ # Galera status — all Synced
md-0: wsrep_cluster_size=3, Synced, wsrep_ready=ON, wsrep_flow_control_paused=0.0208
md-1: wsrep_cluster_size=3, Synced, wsrep_ready=ON, wsrep_flow_control_paused=0.0186
md-2: wsrep_cluster_size=3, Synced, wsrep_ready=ON, wsrep_flow_control_paused=0.0064

➤ # Tracking rows — all match
md-0 markers: 25
md-1 markers: 25
md-2 markers: 25

➤ # Checksums — all match
md-0: sbtest1=3192592587, sbtest2=1620218475, sbtest3=827673677, sbtest4=2199205073
md-1: sbtest1=3192592587, sbtest2=1620218475, sbtest3=827673677, sbtest4=2199205073
md-2: sbtest1=3192592587, sbtest2=1620218475, sbtest3=827673677, sbtest4=2199205073
```

**Result: PASS** — Network partition handled correctly. Isolated node became `non-Primary` and stopped accepting queries (no split-brain). Remaining 2 nodes maintained quorum at 1430 TPS. After partition expired, isolated node auto-rejoined and synced. Zero data loss — all 25 tracking rows preserved, checksums match.

Clean up:

```shell
➤ kubectl delete -f 1-single-experiments/network-partition-primary.yaml
networkchaos.chaos-mesh.org "mariadb-primary-network-partition" deleted
```

---

