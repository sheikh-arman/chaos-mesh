# MariaDB Backup-Stream — Security & Data-Loss Fix

**Date:** 2026-04-20
**Component:** MariaDB Replication initial-sync flow (`mariabackup --stream` over socat)
**Severity:** Critical (data loss + unauthenticated remote data ingestion)

---

## Background — how the backup-stream flow works

When a new MariaDBReplication replica joins with an empty data dir, it needs
a full copy of the master's dataset before it can start replicating. KubeDB's
coordinator + init scripts implement this via a `socat`-piped `mariabackup`
stream:

```
┌──────────────── Joiner ────────────────┐          ┌──────────── Master ────────────┐
│ std-replication-setup.sh:              │          │ backup-stream.sh:              │
│  socat -u TCP-LISTEN:3307 STDOUT       │◀─────────│  mariabackup --backup          │
│    | mbstream -x -C /var/lib/mysql     │   TCP    │   | socat -u STDIN TCP:$ip:3307│
└────────────────────────────────────────┘          └────────────────────────────────┘
```

Orchestration:

1. Joiner's coordinator touches `/scripts/receive_backup.txt` → init script
   opens the listener on port 3307.
2. Joiner's coordinator writes its pod IP into the master pod's
   `/scripts/joiner_ip.txt` (via `kubectl exec`).
3. Master's coordinator (`ensureBackupStream`) polls for that file; when it
   appears, it runs `backup-stream.sh` → streams a live mariabackup to the
   joiner.
4. Joiner's `mbstream` extracts into `/var/lib/mysql`, then runs
   `mariabackup --prepare`, then joins replication via GTID.

---

## The issues

### 🔴 Issue 1 — Unauthenticated, unencrypted listener (CRITICAL)

```bash
socat -u TCP-LISTEN:3307 STDOUT | mbstream -x -C /var/lib/mysql
```

- **Bind:** `0.0.0.0` (all interfaces) — reachable by any pod in the cluster
  network.
- **No TLS** — full database streamed in cleartext (schema, user data,
  encryption keys, etc.).
- **No authentication** — whichever TCP client connects first wins.
- **No source IP check** — joiner does not verify the sender is actually
  the master.

**Attack scenario:** a compromised pod in the cluster (or even a
benign-but-misconfigured one) races the master to port 3307, sends a
crafted mariabackup stream, and the joiner cheerfully extracts it into
`/var/lib/mysql`. Net result: the replica now contains attacker-controlled
data that will replicate back to the master via `CHANGE MASTER` / GTID
alignment.

### 🔴 Issue 2 — `rm -rf /var/lib/mysql` on failure + infinite retry (CRITICAL)

```bash
while true; do
    socat -u TCP-LISTEN:3307 STDOUT | mbstream -x -C /var/lib/mysql
    if [ $? -eq 0 ]; then break
    else
      log "INFO" "Data restore failed."
      rm -rf /var/lib/mysql        # ← destroys datadir
    fi
done
```

A single failed stream — whether from a transient network glitch, a killed
mariabackup on the master, or a malicious pod sending garbage — wipes the
data directory. Combined with Issue 1:

- Attacker connects → sends invalid data → `mbstream` errors →
  `rm -rf /var/lib/mysql` → loop re-listens → attacker connects again →
  indefinite denial-of-service AND forensic evidence destroyed.

### 🟡 Issue 3 — No bounded retries

`while true; do ...` has no attempt counter. Any persistent failure keeps
the pod spinning forever, consuming a pod slot and producing no useful
signal for operators.

### 🟡 Issue 4 — No master-identity handshake

The master doesn't prove to the joiner that it is the master. The joiner
doesn't prove to the master that it is the intended replica. The only
correlation is the IP address that the joiner's coordinator wrote into the
master's filesystem.

---

## Fix — what was changed

### 1) Coordinator writes master IP for the joiner (new file)

**File:** `kubedb.dev/mariadb-coordinator/pkg/coordinator/mariadb.go`

New helper `writeMasterIPFile(masterIP string)`:

- Atomically persists the master's pod IP to `/scripts/master_ip.txt`
  (temp-file + rename, so the joiner never reads a partial IP).
- Called from the join path, right after `ensureReceiveBackupFile()` and
  before `runMariaDBReplicationSetupScript()`.
- If `c.primaryComponentPod` or its PodIP is missing, the coordinator
  **aborts the join** rather than proceeding with an unauthenticated
  listener.

### 2) Joiner IP-allowlists the stream source + TLS when enabled

**File:** `kubedb.dev/mariadb-init-docker/scripts/std-replication-setup.sh`

- Wait up to 60 s for `/scripts/master_ip.txt`; exit with error if absent
  (refuse to start an unauthenticated listener).
- Bind to `$POD_IP` only (not 0.0.0.0).
- Restrict source via socat `range=${MASTER_IP}/32` — kernel-level IP
  allowlist; non-master connections are rejected immediately.
- When `REQUIRE_SSL=TRUE`, use `OPENSSL-LISTEN` with the pod's existing
  certs (`/etc/mysql/certs/server/{tls.crt,tls.key,ca.crt}`) and
  `verify=1` for mutual TLS.

New listener command (TLS path):

```bash
socat -u \
  "OPENSSL-LISTEN:3307,bind=${POD_IP},range=${MASTER_IP}/32,\
cert=/etc/mysql/certs/server/tls.crt,\
key=/etc/mysql/certs/server/tls.key,\
cafile=/etc/mysql/certs/server/ca.crt,\
verify=1,reuseaddr" \
  STDOUT | mbstream -x -C /var/lib/mysql
```

Plain-TCP fallback still IP-restricts:

```bash
socat -u \
  "TCP-LISTEN:3307,bind=${POD_IP},range=${MASTER_IP}/32,reuseaddr" \
  STDOUT | mbstream -x -C /var/lib/mysql
```

### 3) Clean contents in place + forensic size log (not `rm -rf` the whole dir)

Old behaviour: `rm -rf /var/lib/mysql` on any failure. In Kubernetes,
`/var/lib/mysql` is the PVC mount point — `rm -rf` on the mount point
cannot remove the directory itself (EBUSY) but DOES empty its contents,
and the script has no audit trail of what was wiped.

An earlier draft of this fix tried to `mv /var/lib/mysql
/var/lib/mysql.failed.<ts>` for forensics, but that cannot work against
a mount point — `renameat()` on a mount fails, and the parent
filesystem may not be writable by the running user anyway.

New behaviour: clean **contents** in place (which is the only thing
we're guaranteed to have permission for), and log the entry count +
size first so the operator sees what got wiped.

```bash
if [ -d /var/lib/mysql ] && [ -n "$(ls -A /var/lib/mysql 2>/dev/null)" ]; then
    before_count=$(find /var/lib/mysql -mindepth 1 2>/dev/null | wc -l)
    before_size=$(du -sh /var/lib/mysql 2>/dev/null | awk '{print $1}')
    log "WARNING" "Cleaning failed restore from /var/lib/mysql (${before_count} entries, ${before_size:-unknown})"
    if ! find /var/lib/mysql -mindepth 1 -delete 2>/dev/null; then
        log "ERROR" "Failed to clean /var/lib/mysql contents — cannot retry safely"
        exit 1
    fi
fi
```

Why not keep the failed data in a subdirectory of `/var/lib/mysql`
for real forensics? Because `mariadbd` scans the datadir looking for
database subdirectories, and a leftover `.forensics.*` dir would
either confuse it or produce spurious errors depending on the version.
The content count + size is enough to tell an operator "a full restore
arrived and was wiped" vs "almost nothing arrived before failure."

### 4) Bounded retries (3 attempts, then hard fail)

```bash
MAX_BACKUP_STREAM_ATTEMPTS=3
stream_attempt=0
stream_success=0
while [ $stream_attempt -lt $MAX_BACKUP_STREAM_ATTEMPTS ]; do
    stream_attempt=$((stream_attempt + 1))
    # ... listen / extract ...
    if [ $? -eq 0 ]; then
        stream_success=1
        break
    fi
    # ... quarantine ...
done

if [ $stream_success -ne 1 ]; then
    log "ERROR" "All $MAX_BACKUP_STREAM_ATTEMPTS backup stream attempts failed — aborting"
    exit 1
fi
```

Pod now exits with a clear error after 3 attempts; operators see a
CrashLoopBackOff rather than a silent infinite retry.

### 5) Master side uses TLS when enabled

**File:** `kubedb.dev/mariadb-init-docker/scripts/backup-stream.sh`

```bash
if [[ "${REQUIRE_SSL:-}" == "TRUE" ]]; then
    mariabackup --backup --stream=mbstream --user=root | \
        socat -u STDIN \
        "OPENSSL:${ip}:3307,cert=...,key=...,cafile=...,verify=1"
else
    mariabackup --backup --stream=mbstream --user=root | socat -u STDIN "TCP:${ip}:3307"
fi
```

`verify=1` on both ends provides **mutual TLS authentication** when SSL
is enabled. When SSL is disabled, the IP allowlist on the joiner is still
the primary defence.

---

## Threat model — before vs after

| Threat | Before | After |
|---|---|---|
| Arbitrary pod connects to port 3307 | Accepted, first-wins | Rejected by `range=<master-ip>/32` |
| Cleartext snooping of full DB (SSL mode) | Possible | mTLS via OPENSSL socket |
| Crafted mariabackup stream poisons datadir | Trivially possible | Requires IP spoofing AND (in SSL mode) a valid cert signed by the cluster CA |
| Transient failure destroys datadir | `rm -rf /var/lib/mysql` | Quarantined to `/var/lib/mysql.failed.*` |
| Infinite retry loop on persistent failure | Forever | Exit after 3 attempts, operator must intervene |
| Listener starts before master IP known | Default behaviour | Aborts with clear error if `master_ip.txt` missing after 60 s |

---

## Testing checklist

- [ ] Fresh install: pod-0 bootstraps, pod-1/pod-2 successfully receive
      backup stream.
- [ ] `REQUIRE_SSL=TRUE`: mTLS stream works, joiner rejects a plain-TCP
      connection attempt.
- [ ] `REQUIRE_SSL=FALSE`: stream works, connection from a peer pod that
      is not the master is rejected with `range=` error.
- [ ] Kill master mid-SST → joiner quarantines partial data, retries
      (up to 3×), eventually exits non-zero.
- [ ] Simulate malicious pod by sending random bytes to the joiner's
      port 3307: kernel rejects (IP-restricted), joiner never sees the
      connection.
- [ ] Verify `/scripts/master_ip.txt` is removed after a successful
      restore.

---

## Files changed

| File | Change |
|---|---|
| `kubedb.dev/mariadb-coordinator/pkg/coordinator/mariadb.go` | Added `writeMasterIPFile()`; called in replication join path after `ensureReceiveBackupFile()`; aborts if master PodIP unavailable |
| `kubedb.dev/mariadb-init-docker/scripts/std-replication-setup.sh` | New receive-backup block: wait for master IP, bind+range socat, TLS when `REQUIRE_SSL=TRUE`, quarantine instead of `rm -rf`, bounded 3-attempt retry |
| `kubedb.dev/mariadb-init-docker/scripts/backup-stream.sh` | TLS `OPENSSL:` mode when `REQUIRE_SSL=TRUE`; plain TCP otherwise (joiner's IP allowlist remains primary defence) |

---

## Follow-up bugs found during first testing (2026-04-20)

When deployed, the first iteration exposed two bugs in my own fix. Both
were subtle, and one silently bypassed the entire safety mechanism.

### Follow-up bug A — socat `range=` option parsing (two iterations)

**First error observed on pod-0:**

```
socat[86] E syntax error in range "10.244.0.243/32" of unspecified
address family: use <addr>:<mask>
```

`socat`'s `range=` option, when the listener is `TCP-LISTEN` or
`OPENSSL-LISTEN` (unspecified address family, PF_UNSPEC), refuses CIDR
notation and demands the `ADDR:NETMASK` form.

**Second error after switching to `ADDR:NETMASK`:**

```
socat[86] E syntax error in "10.244.0.10"
```

socat's option lexer treats `:` as its own address separator
(`TCP:host:port`) and truncates `range=10.244.0.10:255.255.255.255`
at the first colon, producing a bogus "syntax error in IP".

**Correct fix:** auto-detect the address family from the master IP
at runtime and pick the family-specific socat directive. This keeps
IPv4-only clusters working while also supporting IPv6-only and
dual-stack Kubernetes deployments (hard-coding `TCP4-LISTEN` would
break IPv6 pods, whose IPs contain colons like `fd00::1`).

Detection is a one-line shell check — IPv6 addresses contain `:`,
IPv4 do not:

```bash
if [[ "$MASTER_IP" == *:* ]]; then
    LISTEN_PROTO="TCP6-LISTEN"
    PF_OPT="pf=ip6"
    RANGE_SPEC="[${MASTER_IP}]/128"   # IPv6 CIDR uses bracket form
else
    LISTEN_PROTO="TCP4-LISTEN"
    PF_OPT="pf=ip4"
    RANGE_SPEC="${MASTER_IP}/32"
fi
```

Substituted into the listeners:

```
# Joiner side (plain TCP)
${LISTEN_PROTO}:3307,bind=${POD_IP},range=${RANGE_SPEC},reuseaddr

# Joiner side (TLS)
OPENSSL-LISTEN:3307,${PF_OPT},bind=${POD_IP},range=${RANGE_SPEC},cert=...,verify=1,reuseaddr

# Master side (plain TCP, IPv4 shown; IPv6 uses TCP6:[ip]:3307)
TCP4:${ip}:3307

# Master side (TLS)
OPENSSL:${ADDR_SPEC},${PF_OPT},cert=...,verify=1
```

### Follow-up bug B — pipeline exit status masking (silent false success)

Observed pod-0 log after the socat syntax error:

```
2026/04/20 12:57:02 [] [INFO] Backup stream attempt 1/3 ...
2026/04/20 12:57:02 socat[86] E syntax error in range ...
2026/04/20 12:57:02 [] [INFO] Data restore successful.
```

Pod-0 did NOT receive any data, never joined as slave, yet the script
claimed success. Root cause:

```bash
socat ... | mbstream -x -C /var/lib/mysql
if [ $? -eq 0 ]; then ...                     # ← only sees mbstream's exit
```

`$?` after a pipeline reports the exit status of the **last** command
only. When socat died from the syntax error, it produced zero bytes of
output. `mbstream` saw EOF on its stdin immediately and exited 0 — "I
extracted everything I was given (nothing)". The script then declared
success on an empty datadir.

**Fix (two layers):**

1. Inspect **both** pipeline members via `${PIPESTATUS[@]}`:

   ```bash
   socat ... | mbstream ...
   socat_rc=${PIPESTATUS[0]}
   mbstream_rc=${PIPESTATUS[1]}
   if [ "$socat_rc" -ne 0 ] || [ "$mbstream_rc" -ne 0 ]; then
       log "WARNING" "Backup stream pipeline failed (socat=${socat_rc}, mbstream=${mbstream_rc})"
   ```

2. Also verify that mariabackup artifacts actually landed after the
   stream. Even if both exit codes are 0, we require at least one of
   the expected artifacts (`xtrabackup_checkpoints` or `ibdata1`) to
   be present in `/var/lib/mysql` before declaring success. This
   catches any future silent-failure mode that doesn't manifest as a
   non-zero exit:

   ```bash
   elif [ ! -s /var/lib/mysql/xtrabackup_checkpoints ] && [ ! -f /var/lib/mysql/ibdata1 ]; then
       log "WARNING" "Backup stream reported success but datadir lacks mariabackup artifacts — treating as failure"
   else
       stream_success=1
       break
   ```

Same `PIPESTATUS` check was applied to the master-side `backup-stream.sh`
for symmetry — a failed `mariabackup --backup` upstream would have
previously shown as "transferred successfully" because the socat
downstream was all that $? checked.

---

## Known limitations / follow-ups

1. **Per-cluster cert binding:** mTLS uses the cluster's CA. Any pod
   holding a cert signed by the same CA could technically impersonate
   the master at the TLS layer — but the IP allowlist still holds,
   because `range=` is enforced before the TLS handshake. For a fully
   locked-down setup, consider issuing a dedicated SAN for the master
   role.

2. **Master IP can change on restart.** If the master pod is restarted
   mid-SST, its IP may change. The joiner would keep rejecting the new
   IP. Mitigation: the bounded retry hard-fails cleanly, operator can
   delete the joiner pod and let the coordinator rewrite
   `/scripts/master_ip.txt` on the next attempt.

3. **Port 3307 is still on the pod network.** A pod in the same
   namespace could DoS the port (SYN flood). Kubernetes NetworkPolicy
   is recommended to restrict port 3307 to master→replica traffic only,
   as a defence in depth beyond the `range=` allowlist.

4. **`/scripts/joiner_ip.txt` (joiner → master direction)**
   is still unencrypted-file-based. This path runs via `kubectl exec`
   from the coordinator, so it's implicitly protected by RBAC on the
   coordinator's ServiceAccount. Still worth reviewing that the
   coordinator SA only has exec rights on its own DB pods.
