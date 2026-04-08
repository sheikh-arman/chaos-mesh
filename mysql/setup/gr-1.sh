#!/bin/bash
PASS=$(kubectl get secret mysql-ha-cluster-auth -n demo -o jsonpath='{.data.password}' | base64 -d)


kubectl exec -it -n demo pod/mysql-ha-cluster-1 -c mysql -- \
  mysql -uroot -p"$PASS" -e 'SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE FROM performance_schema.replication_group_members;'

