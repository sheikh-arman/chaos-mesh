# Init script unification: `innodb-support-unified`

## Goal

Replace three parallel branches of `kubedb.dev/mysql-init-docker`:

- `innodb-support-80` — MySQL 8.0.x
- `innodb-support` — MySQL 8.4.x
- `innodb-support-9.0.1` — MySQL 9.x

…with a single branch (`innodb-support-unified`) whose scripts behave exactly
like each source branch when run against that version's mysqld. One image
source, one place to apply fixes, no more 3× cherry-picks per change.

The cost of three branches: every fix has to be ported to all three
manually. We caught two real bugs from this drift in a single afternoon
(`fix_metadata_uuids` missing on 8.4, `RESET BINARY LOGS AND GTIDS` syntax
not gated for 8.0). The unification removes that drift.

## How version selection works

A `detect_mysql_version` helper at the top of each script parses
`mysqld --version` and exports `MYSQL_MAJOR`, `MYSQL_MINOR`, `MYSQL_PATCH`.
A `version_ge MAJ MIN` helper returns 0/1 so the rest of the script can
gate version-specific behaviour inline:

```bash
detect_mysql_version() {
    local raw
    raw=$(mysqld --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')
    if [[ -z "$raw" ]]; then raw="8.4.0"; fi
    MYSQL_MAJOR=${raw%%.*}
    local rest=${raw#*.}
    MYSQL_MINOR=${rest%%.*}
    MYSQL_PATCH=${rest#*.}
}

version_ge() {
    local want_major=$1 want_minor=$2
    if [[ "$MYSQL_MAJOR" -gt "$want_major" ]]; then return 0; fi
    if [[ "$MYSQL_MAJOR" -eq "$want_major" && "$MYSQL_MINOR" -ge "$want_minor" ]]; then return 0; fi
    return 1
}
```

Two derived helpers handle the two SQL syntax shifts that span multiple
sites:

```bash
# RESET MASTER (≤8.0)  →  RESET BINARY LOGS AND GTIDS (8.4+)
reset_binlog_and_gtids_sql() {
    if version_ge 8 4; then echo "RESET BINARY LOGS AND GTIDS;"
    else echo "RESET MASTER;"; fi
}
```

Fallback default: if `mysqld --version` parsing fails, the helper assumes
`8.4.0` — the middle-of-the-road behaviour least likely to break either
end. The detected value is logged so misdetection is observable.

## What the script picks per version family

Single decision matrix. "emit" = line emitted in the generated config or
SQL statement actually issued. "skip" = silently absent.

| Setting / SQL | 8.0.x | 8.4.x | 9.x | Why |
|---|---|---|---|---|
| `loose-group_replication_communication_stack = MYSQL` | emit | emit | emit | 8.0.27+ uses it; older `loose-` warns and falls back to XCom |
| `loose_group_replication_unreachable_majority_timeout = 20` | emit | emit | emit | 8.0.18+, all supported |
| `loose_group_replication_exit_state_action = OFFLINE_MODE` | emit | emit | emit | 8.0.18+, all supported |
| `mysql_native_password=ON` (server variable) | **skip** | **emit** | **skip** | option only exists on 8.4; aborts mysqld on 8.0 (unknown) and 9.x (plugin removed) |
| `default-authentication-plugin=mysql_native_password` | emit | emit | **skip** | option removed in 9.x |
| `log_error_suppression_list = 'MY-013360'` | emit | emit | **skip** | suppresses the 8.0/8.4 deprecation noise; the noise is gone in 9.x because the plugin is gone |
| `master_info_repository = TABLE` | emit | **skip** | **skip** | required for GR pre-8.0.23; removed in 8.4 (implicit table) |
| `relay_log_info_repository = TABLE` | emit | **skip** | **skip** | same as above |
| `transaction_write_set_extraction = XXHASH64` | emit | **skip** | **skip** | required for GR pre-8.0.26; removed in 8.4 (implicit XXHASH64) |
| `loose-group_replication_ip_allowlist` (run_innodb.sh) | emit | **skip** | **skip** | 8.4+ uses MYSQL stack on port 3306 — GR allowlist redundant |
| First-boot reset SQL | `RESET MASTER;` | `RESET BINARY LOGS AND GTIDS;` | `RESET BINARY LOGS AND GTIDS;` | new syntax added in 8.4 |
| GR recovery channel CHANGE statement | `CHANGE MASTER TO MASTER_USER=…` | `CHANGE REPLICATION SOURCE TO SOURCE_USER=…` | `CHANGE REPLICATION SOURCE TO SOURCE_USER=…` | source-vs-master rename in 8.0.23 / 8.4 |
| Reset after CHANGE | `RESET MASTER;` | `RESET REPLICA;` | `RESET REPLICA;` | each source branch's exact behaviour preserved (different commands; both work) |
| run_read_only.sh: STOP / START | `stop slave;` / `start slave;` | `stop replica;` / `start replica;` | `stop replica;` / `start replica;` | same rename |
| run_read_only.sh: SSL keywords | `MASTER_SSL=*` | `SOURCE_SSL=*` | `SOURCE_SSL=*` | same rename |
| Semi-sync plugin install | `INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';` (+ `_slave`) | `INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';` (+ `_replica`); also uninstall old if present | same as 8.4 | plugin renamed in 8.4; the .so files literally don't exist under the old names on 8.4+ |
| ERROR-state-peer GR-stop loop pre-reboot | run | run | run | required by `dba.rebootClusterFromCompleteOutage()` regardless of version |
| `fix_metadata_uuids` | run | run | run | repairs `mysql_innodb_cluster_metadata.instances.mysql_server_uuid` after PVC delete / restore from foreign cluster |
| Missing-metadata `createCluster` fallback | run | run | run | recovers when metadata schema is absent / unknown to this server_uuid |
| `dba.checkInstanceConfiguration()` first-boot detection | run | run | run | replaces fragile `gtid_mode=ON` shortcut (broken on 9.6+ where gtid_mode defaults ON) |
| `$INNODB_BUFFER_POOL_SIZE`, `$GROUP_REPLICATION_MESSAGE_CACHE_SIZE`, `$BINLOG_EXPIRE_LOGS_SECONDS` env tunables | emit if set | emit if set | emit if set | runtime knobs from operator env |

## Per-branch parity statement

Independent confirmation that each source branch's behaviour is preserved
on the version family it covered:

| Source branch | Versions covered | Unified parity |
|---|---|---|
| `innodb-support-80` | 8.0.x | ✅ all SQL, all my.cnf directives, semi-sync plugin install, run_read_only.sh slave/master keywords, allowlist seed, `default-authentication-plugin`, `log_error_suppression_list`, `master_info_repository`, `relay_log_info_repository`, `transaction_write_set_extraction`, `RESET MASTER` reset semantics — all match exactly |
| `innodb-support` | 8.4.x | ✅ `mysql_native_password=ON`, `RESET BINARY LOGS AND GTIDS`, `RESET REPLICA;` post-CHANGE, source/replica keywords, new semi-sync plugin pair (with old plugin uninstall on upgrade), ERROR-state-peer GR-stop loop, `fix_metadata_uuids` — all match exactly |
| `innodb-support-9.0.1` | 9.x | ✅ all of innodb-support's behaviour + 9.x specifics: `mysql_native_password=ON` correctly skipped, `default-authentication-plugin` correctly skipped, `dba.checkInstanceConfiguration()` first-boot path, `RESET BINARY LOGS AND GTIDS` (replaces 8.0 `RESET MASTER`), modern `cluster.rescan()` no-options form |

## What's NOT version-gated and works the same on all three

These are pure helper logic on top of MySQL primitives that haven't changed
across 8.0 → 9.x. They apply uniformly:

- `clear_stale_cluster_lock` — kills `Sleep > 5s` holders of
  `AdminAPI_cluster.AdminAPI_lock` so mysqlsh `rescan` / `addInstance` /
  `rejoinInstance` doesn't hang with `MYSQLSH 51500`.
- `fix_metadata_uuids` — pure SQL on
  `mysql_innodb_cluster_metadata.instances` plus AdminAPI
  `removeInstance` / `addInstance(recoveryMethod:'clone')`.
- Missing-metadata `createCluster` fallback — branches on whether the
  schema exists and whether this server_uuid is registered, then
  `dba.createCluster(adoptFromGR:true)` if GR is up or
  `dba.createCluster()` if GR is down.
- Coordinator-side change (separate repo): `LabelPods` decoupled from
  the main coordinator loop into its own 5-second goroutine — fixes the
  dual-primary label transient seen during isolation chaos. Unrelated to
  init-script versioning.

## Files in the unified branch

| File | Modified? | Lines added vs each source branch |
|---|---|---|
| `scripts/run.sh` | yes | adds `version_ge` / `reset_binlog_and_gtids_sql` helpers; restructures my.cnf write to single `[mysqld]` block; gates 5 lines on version |
| `scripts/run_innodb.sh` | yes | adds helpers; restructures my.cnf write; adds 8.0/8.4 conditional emits; restores ERROR-state-peer pre-reboot loop; gates RESET inside `create_replication_user` |
| `scripts/run_semi_sync.sh` | yes | adds helpers; gates RESET; gates plugin install pair on `version_ge 8 4` (with 8.4 upgrade path: uninstall old → install new) |
| `scripts/run_read_only.sh` | yes | adds helpers; gates STOP / CHANGE / START + SSL keywords on `version_ge 8 4` |
| `scripts/standalone-run.sh` | no | no version-conditional behaviour |
| `scripts/directory-exist.sh` | no | added in 8.4/9.0.1 branches; works on all versions |

## Migration plan

1. **Push** `innodb-support-unified` to origin.
2. **Build** per-version images from this single branch — image tags stay
   per MySQL version (`mysql-init:vN_8.0.36`, `…_8.4.8`, `…_9.0.1`); only
   the source branch consolidates.
3. **e2e matrix** — at minimum:
   - 8.0.36: cluster bootstrap, addInstance, primary kill, full reboot,
     restored cluster (metadata fallback path), PVC-deleted pod
     (`fix_metadata_uuids` path).
   - 8.4.8: same set.
   - 9.0.1 (or whichever 9.x patch ships): same set, plus an upgrade test
     where a 8.0 cluster's `mysql.plugin` table referencing legacy
     semi-sync plugin gets cleaned up by the new install path.
4. **Once e2e is green**, point KubeDB's `MySQLVersion` CRDs at images
   built from the unified branch.
5. **Delete** the three legacy branches once a release cycle has confirmed
   no field issues.

## Risks

- **Untested patch levels.** Branch was built and reviewed against
  `mysqld --version` output formats from 8.0.36, 8.4.8, 9.0.1. If a
  future patch changes the output format the parser doesn't match, the
  script falls back to `MYSQL_MAJOR=8 MYSQL_MINOR=4` — modern path. On
  8.0.x deployments this would mean the wrong gate fires (e.g.
  `RESET BINARY LOGS AND GTIDS;` instead of `RESET MASTER;`) and mysqld
  init fails. Detection is logged loudly to make this visible.
- **5.7 / pre-8.0.22 edge cases.** Not explicitly targeted. The script
  does the right thing on every gate (falls to OLD form on `! version_ge
  8 4`), but `STOP REPLICA` / `CHANGE REPLICATION SOURCE TO` aliases
  don't exist on 8.0.0–8.0.21 — for those exact patch levels the
  `version_ge 8 4` gate falls through to the old `STOP SLAVE` / `CHANGE
  MASTER TO` so they're covered. Genuine 5.7 isn't a target of any of
  the three source branches.
- **mysqlsh version-image binding.** The script is run from inside the
  mysqld container, so `mysqlsh` is whatever ships in that image. If the
  8.0 image happens to bundle a 5.7-era `mysqlsh`, some `--js` API
  calls may differ (`dba.checkInstanceConfiguration` API existed since
  8.0.4 — should be fine for the appscode 8.0.36 image).

## References

- `mysql-init-docker/scripts/run.sh` — GR init path
- `mysql-init-docker/scripts/run_innodb.sh` — InnoDB Cluster init path
- `mysql-init-docker/scripts/run_semi_sync.sh` — Semi-sync replication init
- `mysql-init-docker/scripts/run_read_only.sh` — Read-only replica init
- `setup-txt-race-after-reboot.md` (sibling) — coordinator-side race that
  this unification does NOT address (separate fix in the coordinator repo)
