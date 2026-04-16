#!/bin/bash
PASS=$(kubectl get secret md-auth -n demo -o jsonpath='{.data.password}' | base64 -d)


kubectl exec -it -n demo pod/md-2 -c mariadb -- \
  mariadb -uroot -p"$PASS" -e "SHOW GLOBAL STATUS WHERE Variable_name IN (
                                 'wsrep_cluster_size',
                                 'wsrep_cluster_status',
                                 'wsrep_local_state_comment',
                                 'wsrep_ready',
                                 'wsrep_connected',
                                 'wsrep_flow_control_paused'
                             );"

