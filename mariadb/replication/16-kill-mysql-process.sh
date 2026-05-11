#!/bin/bash
# Forcefully kill mysqld inside the primary pod (no Chaos Mesh CRD — direct exec).
# Usage: ./16-kill-mysql-process.sh <primary-pod-name> [namespace]
# e.g.   ./16-kill-mysql-process.sh mysql-ha-cluster-0 demo

POD=${1:?primary pod name required}
NS=${2:-demo}

echo "ps aux|grep -E '[m]ysqld'|awk '{print \$2}'|xargs kill -9" \
  | kubectl exec -i "$POD" -n "$NS" -- bash
