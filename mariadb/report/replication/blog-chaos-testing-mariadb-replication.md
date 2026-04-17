---
title: "Chaos Testing KubeDB MariaDB Replication with MaxScale: Building Resilience with Chaos Mesh"
date: "2026-04-17"
weight: 25
authors:
- SK Ali Arman
tags:
- chaos-engineering
- chaos-mesh
- database
- high-availability
- kubedb
- kubernetes
- mariadb
- maxscale
- replication
---

> New to KubeDB? Please start [here](https://kubedb.com/docs/v2026.2.26/welcome/).

# Chaos Testing KubeDB Managed MariaDB Replication with MaxScale

## Setup Cluster

To follow along with this tutorial, you will need:

1. A running Kubernetes cluster.
2. KubeDB [installed](https://kubedb.com/docs/v2026.2.26/setup/install/kubedb/) in your cluster.
3. kubectl command-line tool configured to communicate with your cluster.
4. Chaos-Mesh [installed](https://chaos-mesh.org/docs/production-installation-using-helm/) in your cluster.
    ```shell
    helm upgrade -i chaos-mesh chaos-mesh/chaos-mesh \
     -n chaos-mesh \
    --create-namespace \
    --set dashboard.create=true \
    --set dashboard.securityMode=false \
    --set chaosDaemon.runtime=containerd \
    --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
    --set chaosDaemon.privileged=true
    ```
> Note: Make sure to set correct path to your container runtime socket and runtime in the above command.

## Introduction to Chaos Engineering

**Chaos Engineering** is a disciplined approach to testing distributed systems by deliberately introducing controlled failure scenarios to discover vulnerabilities and weaknesses before they impact your users.

This methodology is particularly crucial for database systems, where failures can lead to data loss, service downtime, and compromised data consistency.

### What This Blog Covers

In this comprehensive guide, we will:

1. **Deploy a MariaDB Replication cluster with MaxScale** on Kubernetes using KubeDB
2. **Run 18 Chaos Engineering Experiments** using Chaos Mesh to simulate real-world failure scenarios
3. **Observe Cluster Behavior** during failures — all traffic routed through MaxScale proxy
4. **Measure Resilience** by tracking data consistency, failover speed, and recovery capabilities

You can see the [`Chaos Testing Results Summary`](#chaos-testing-results-summary) for a quick view.

## Test Environment

| Component | Details |
|---|---|
| Kubernetes | kind (local cluster) |
| KubeDB Version | 2026.2.26 |
| Cluster Topology | MariaDB Replication (1 Master + 2 Slaves) |
| Proxy | MaxScale (3 replicas) |
| MariaDB Version | 11.8.5 |
| Storage | 2Gi PVC per node (Durable, ReadWriteOnce) |
| Memory Limit | 1.5Gi per MariaDB pod |
| CPU Request | 500m per pod |
| Chaos Engine | Chaos Mesh |
| Load Generator | sysbench `oltp_read_write` via MaxScale, 4 tables x 50k rows, 4 threads |
| Baseline TPS | ~926 |

All experiments were run under **sustained sysbench read-write load routed through MaxScale** to simulate production traffic during failures.

## Create a MariaDB Replication Cluster with MaxScale

Unlike Galera Cluster (multi-master), MariaDB Replication uses a **Master-Slave** topology. One node (Master) accepts writes, and 2 Slaves replicate asynchronously. **MaxScale** acts as a proxy that routes writes to Master and reads to Slaves automatically.

Save the following YAML as `setup/kubedb-mariadb.yaml`:

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
        storage: 2Gi
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
    mode: MariaDBReplication
    maxscale:
      replicas: 3
      enableUI: true
      storage:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 100Mi
      storageType: Durable
  version: 11.8.5
```

> **Important Notes:**
> - You can read/write in your database in both **`Ready`** and **`Critical`** states.
> - **MaxScale** automatically routes writes to Master and reads to Slaves. On Master failover, MaxScale detects the new Master and re-routes traffic.
> - `kubedb.com/role: Master` = primary node, `kubedb.com/role: Slave` = replica nodes.

Deploy:

```shell
kubectl create ns demo
kubectl apply -f setup/kubedb-mariadb.yaml
```

Verify the cluster is ready:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    3m

NAME       READY   STATUS    RESTARTS   AGE   ROLE
pod/md-0   2/2     Running   0          3m    Master
pod/md-1   2/2     Running   0          3m    Slave
pod/md-2   2/2     Running   0          3m    Slave
pod/md-mx-0   1/1  Running   0          3m
pod/md-mx-1   1/1  Running   0          3m
pod/md-mx-2   1/1  Running   0          3m
```

Check replication status:

```shell
➤ # Master binlog position:
SHOW MASTER STATUS\G
File: mariadb-bin.000002
Position: 10179

➤ # Slave status (md-1 and md-2):
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

### Prepare sysbench via MaxScale

```bash
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Create database
kubectl exec -n demo md-0 -c mariadb -- mariadb -uroot -p"$PASS" -e "CREATE DATABASE IF NOT EXISTS sbtest;"

# Prepare via MaxScale
kubectl exec -n demo $SBPOD -- sysbench oltp_read_write \
  --mysql-host=md-mx --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=4 --table-size=50000 --threads=4 prepare
```

### Baseline via MaxScale

```shell
➤ sysbench oltp_read_write --mysql-host=md-mx ... --time=15 --report-interval=5 run
[ 5s ] thds: 4 tps: 925.90 qps: 18535.24 (r/w/o: 12976.23/3706.01/1853.00) lat (ms,95%): 6.09 err/s: 0.40 reconn/s: 0.00
[ 10s ] thds: 4 tps: 919.23 qps: 18396.80 (r/w/o: 12879.22/3678.52/1839.06) lat (ms,95%): 6.21 err/s: 0.60 reconn/s: 0.00
[ 15s ] thds: 4 tps: 934.40 qps: 18687.38 (r/w/o: 13081.98/3736.40/1869.00) lat (ms,95%): 5.88 err/s: 0.20 reconn/s: 0.00

SQL statistics:
    transactions:                        13902  (926.35 per sec.)
    queries:                             278140 (18533.75 per sec.)
    ignored errors:                      6      (0.40 per sec.)
    reconnects:                          0      (0.00 per sec.)
```

Baseline: ~926 TPS via MaxScale, 0 reconnects.

## Chaos Testing

We will run chaos experiments to see how our MariaDB Replication + MaxScale cluster behaves under failure scenarios. All traffic goes through `md-mx` (MaxScale service).

### Replication Status Check

```bash
# Check replication on slaves
for i in 1 2; do
  echo "=== md-$i ==="
  kubectl exec -n demo md-$i -c mariadb -- mariadb -uroot -p"$PASS" -e \
    "SHOW SLAVE STATUS\G" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'
done
```

### Chaos#1: Kill the Master Pod

We kill the Master pod and see how fast MaxScale detects the failover and re-routes traffic to the new Master.

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
      "kubedb.com/role": "Master"
  gracePeriod: 0
```

**What this chaos does:** Terminates the Master pod abruptly, forcing MaxScale to detect the failover and route traffic to the new Master.

Before running:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    11m

NAME       READY   STATUS    RESTARTS   AGE   ROLE
pod/md-0   2/2     Running   0          10m   Master
pod/md-1   2/2     Running   0          10m   Slave
pod/md-2   2/2     Running   0          10m   Slave
```

Apply the chaos:

```shell
➤ kubectl apply -f 1-single-experiments/pod-kill-primary.yaml
podchaos.chaos-mesh.org/mariadb-primary-pod-kill created
```

Within 10 seconds, md-0 is killed and md-1 is promoted to Master. The old Master rejoins as Slave:

```shell
➤ kubectl get mariadb,pods -n demo -L kubedb.com/role
NAME                       VERSION   STATUS   AGE
mariadb.kubedb.com/md      11.8.5    Ready    11m

NAME       READY   STATUS    RESTARTS   AGE   ROLE
pod/md-0   2/2     Running   0          49s   Slave
pod/md-1   2/2     Running   0          11m   Master
pod/md-2   2/2     Running   0          11m   Slave
```

Check replication — both Slaves point to new Master (md-1):

```shell
➤ # md-0 (old master, now slave):
Master_Host: md-1.md-pods.demo.svc.cluster.local
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0

➤ # md-2:
Master_Host: md-1.md-pods.demo.svc.cluster.local
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

Sysbench via MaxScale — MaxScale automatically re-routed to new Master:

```shell
➤ sysbench oltp_read_write --mysql-host=md-mx ... --time=15 --report-interval=5 run
[ 5s ] thds: 4 tps: 949.30 qps: 18999.28 lat (ms,95%): 5.67 err/s: 0.20 reconn/s: 0.00
[ 10s ] thds: 4 tps: 962.82 qps: 19259.55 lat (ms,95%): 5.00 err/s: 0.20 reconn/s: 0.00
[ 15s ] thds: 4 tps: 961.61 qps: 19234.06 lat (ms,95%): 5.09 err/s: 0.00 reconn/s: 0.00

SQL statistics:
    transactions:                        14373  (957.94 per sec.)
    queries:                             287492 (19161.02 per sec.)
    ignored errors:                      2      (0.13 per sec.)
    reconnects:                          0      (0.00 per sec.)
```

Verify data integrity:

```shell
➤ # Tracking rows — all match
md-0 markers: 25
md-1 markers: 25
md-2 markers: 25

➤ # Checksums — all match
md-0: sbtest1=4015924050, sbtest2=1308768244, sbtest3=1319613445, sbtest4=4197169928
md-1: sbtest1=4015924050, sbtest2=1308768244, sbtest3=1319613445, sbtest4=4197169928
md-2: sbtest1=4015924050, sbtest2=1308768244, sbtest3=1319613445, sbtest4=4197169928
```

**Result: PASS** — Master killed, failover to md-1 within ~10s. MaxScale detected the new Master and re-routed all traffic automatically. Old Master rejoined as Slave. 958 TPS via MaxScale, 0 reconnects. Zero data loss — 25/25 markers, all checksums match.

Clean up:

```shell
➤ kubectl delete -f 1-single-experiments/pod-kill-primary.yaml
podchaos.chaos-mesh.org "mariadb-primary-pod-kill" deleted
```

---

