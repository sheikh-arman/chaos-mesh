#!/bin/bash
PASS=$(kubectl get secret my-auth -n demo -o jsonpath='{.data.password}' | base64 -d)


kubectl exec -it -n demo pod/my-1 -c mysql -- \
  mysql -uroot -p"$PASS" -e 'SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;'

