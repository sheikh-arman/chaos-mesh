#!/usr/bin/env bash
# =============================================================================
# insert-random-mysql-k8s.sh
#   - Finds MySQL pod automatically
#   - Creates database + table if missing
#   - Inserts random 'evt_XXXXXX' rows
# =============================================================================

set -u

# ── Configuration ────────────────────────────────────────────────────────────
HOST="mysql-ha-cluster"
NAMESPACE="demo"
CONTAINER="mysql"
MYSQL_USER="root"
MYSQL_PASS="6GfN4lYvCwFArGQo"          # ← change if wrong
DATABASE="myapp"
TABLE="events"
COUNT=50                               # how many rows to insert
DELAY=0.3                              # seconds between inserts

# ── Pod discovery ────────────────────────────────────────────────────────────
echo "Searching for MySQL pod in namespace ${NAMESPACE}..."

# Try common label selectors (Bitnami-style, MySQL Operator, etc.)
POD_NAME="svc/mysql-ha-cluster"

if [ -z "${POD_NAME}" ]; then
  echo "ERROR: Could not find any MySQL pod."
  echo "Please run these commands manually and tell me the pod name:"
  echo "  kubectl get pods -n ${NAMESPACE}"
  echo "  kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=mysql"
  echo "  kubectl get statefulset -n ${NAMESPACE}"
  exit 1
fi

echo "Using pod: ${POD_NAME}"
echo "───────────────────────────────────────────────"

# ── Helper function to run mysql command ─────────────────────────────────────
run_mysql() {
  local sql="$1"
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER}" -- \
    mysql -h "${HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e "${sql}" 2>&1
}

# ── Step 1: Test basic connection ────────────────────────────────────────────
echo "Step 1: Testing connection (SELECT 1)..."
TEST=$(run_mysql "SELECT 1")

if echo "${TEST}" | grep -qi "not found"; then
  echo "Pod disappeared — check 'kubectl get pods -n ${NAMESPACE}'"
  exit 1
elif echo "${TEST}" | grep -qi "access denied"; then
  echo "ERROR: Authentication failed (wrong password or auth plugin restriction)."
  echo "Try interactive login to confirm:"
  echo "  kubectl exec -it -n ${NAMESPACE} ${POD_NAME} -c ${CONTAINER} -- bash"
  echo "  Then run: mysql -u root -p'${MYSQL_PASS}'   or just mysql -u root"
  exit 1
elif echo "${TEST}" | grep -q "1"; then
  echo "Connection OK ✓"
else
  echo "Unexpected connection result:"
  echo "${TEST}"
  exit 1
fi

# ── Step 2: Create database + table if not exists ────────────────────────────
echo
echo "Step 2: Ensuring database '${DATABASE}' and table '${TABLE}' exist..."
SCHEMA_RESULT=$(run_mysql "
  CREATE DATABASE IF NOT EXISTS ${DATABASE};
  USE ${DATABASE};
  CREATE TABLE IF NOT EXISTS ${TABLE} (
      id   INT AUTO_INCREMENT PRIMARY KEY,
      name VARCHAR(100) NOT NULL,
      time DATETIME DEFAULT CURRENT_TIMESTAMP
  );
  SELECT 'Schema ready' AS status;
")

echo "${SCHEMA_RESULT}" | tail -n 5   # show last few lines

if echo "${SCHEMA_RESULT}" | grep -qi "access denied"; then
  echo "Schema creation failed due to permissions/password."
  exit 1
fi

# ── Step 3: Insert random rows ───────────────────────────────────────────────
echo
echo "Step 3: Inserting ${COUNT} random rows into ${DATABASE}.${TABLE} ..."
success=0
failed=0

for ((i=1; i<=COUNT; i++)); do
  random_part=$(head -c 180 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 9 2>/dev/null || echo "fallback${i}")
  name="evt_${random_part}"

  RESULT=$(kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER}" -- \
    mysql -h "${HOST}" -u"${MYSQL_USER}" -p"${MYSQL_PASS}" -e \
    "INSERT INTO ${DATABASE}.${TABLE} (name) VALUES ('${name}');" 2>&1)

  if echo "${RESULT}" | grep -qi "ERROR"; then
    echo " FAIL  ${i}/${COUNT}   ${name}"
    ((failed++))
  else
    echo "  OK   ${i}/${COUNT}   ${name}"
    ((success++))
  fi

  sleep "${DELAY}"
done

echo
echo "───────────────────────────────────────────────"
echo "Finished"
echo "Successful inserts : ${success}"
echo "Failed inserts     : ${failed}"

if [ ${success} -gt 0 ]; then
  echo
  echo "Count row:"
  kubectl exec -n "${NAMESPACE}" "${POD_NAME}" -c "${CONTAINER}" -- \
    mysql -u"${MYSQL_USER}" -p"${MYSQL_PASS}" "${DATABASE}" -e \
    "SELECT count(*) FROM ${TABLE};"
fi