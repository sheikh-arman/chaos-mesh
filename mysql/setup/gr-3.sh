#!/bin/bash
PASS=$(kubectl get secret my-innodb-auth -n demo -o jsonpath='{.data.password}' | base64 -d)


kubectl exec -it -n demo pod/my-innodb-3 -c mysql -- \
  mysql -uroot -p"$PASS" -e 'SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;'

Our plan behind the chaos test was to check the kubedb operator's ability to recover from a failure. We wanted to see if the operator could detect the failure, create a new pod to replace the failed one, and restore the cluster to its previous state.
from our blog post are we highlinting this? is our requirement full fill?
