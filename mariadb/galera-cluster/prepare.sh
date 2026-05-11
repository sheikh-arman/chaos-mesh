#!/bin/bash

# Get the MySQL root password
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)


kubectl exec -n demo svc/md -c mariadb -- \
  mariadb -uroot -p"$PASS" -hmd.demo.svc.cluster.local -e "DROP DATABASE IF EXISTS sbtest;"

# Create the sbtest database
kubectl exec -n demo svc/md -c mariadb -- \
  mariadb -uroot -p"$PASS" -h md.demo.svc.cluster.local -e "CREATE DATABASE IF NOT EXISTS sbtest;"

# Get the sysbench pod name
SBPOD=$(kubectl get pods -n demo -l app=sysbench -o jsonpath='{.items[0].metadata.name}')

# Standard write load (used during most experiments)
kubectl exec -n demo $SBPOD -- sysbench oltp_write_only \
  --mysql-host=md.demo.svc.cluster.local --mysql-port=3306 \
  --mysql-user=root --mysql-password="$PASS" \
  --mysql-db=sbtest --tables=12 --table-size=1000000 \
  --threads=8 prepare
