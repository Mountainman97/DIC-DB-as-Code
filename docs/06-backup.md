# 6 – Backup and rollback (optional)

Before a run, the toolkit can create a backup or a database snapshot. If an error occurs, it is restored
automatically; if everything succeeds, it is deleted at the end. The feature is **off by default**
(`BACKUP_MODE=none`) and is only used when you switch it on – nothing changes for users who do not need it.

## 6.1 Ways to switch it on

| Scope | How |
|---|---|
| Per call | `--backup backup\|snapshot` on `db-apply-diff.sh`, `db-apply-renames.sh`, `db-data-apply.sh`, `db-provision-dev.sh --if-exists update` |
| Per environment | `BACKUP_MODE=snapshot` in the env file (e.g. only in `prod.env`) |
| Several steps as one unit | `db-backup.sh run … -- <command>` |
| Separate pipeline jobs | `db-backup.sh create` / `restore` / `drop` with a state file |

## 6.2 Modes

| `BACKUP_MODE` | How it works | Suitable for |
|---|---|---|
| `backup` | `BACKUP DATABASE … WITH COPY_ONLY, CHECKSUM, COMPRESSION` to a `.bak` file; on error `RESTORE … WITH REPLACE`; on success the file is deleted | all editions; duration and space grow with database size |
| `snapshot` | Database snapshot (`CREATE DATABASE … AS SNAPSHOT OF`); on error `RESTORE … FROM DATABASE_SNAPSHOT`; on success the snapshot is dropped | large databases: created in seconds, fast rollback; Enterprise/Developer, or Standard from SQL Server 2016 SP1 |

`COPY_ONLY` ensures that the regular backup chain (differential/log backups) of the server is not affected.

## 6.3 Protect a single step

```bash
T=tools/dic-db-as-code/toolkit/scripts
$T/db-apply-diff.sh    --env-file config/prod.env -d DIZ_NET --script artifacts/diff/x.sql --backup snapshot
$T/db-apply-renames.sh --env-file config/prod.env --dir renames --backup backup   # backs up all affected DBs
$T/db-data-apply.sh    --env-file config/prod.env -d DIZ_NET --backup snapshot
```

Internally the script re-launches itself via `db-backup.sh run`. Checks and confirmation prompts run
before that, so the backup is only created when something will actually be executed.

## 6.4 Several steps as one unit – `db-backup.sh run`

Recommended for renames + change script (+ data), so that an error in the change script also rolls back
the renames:

```bash
$T/db-backup.sh run --env-file config/prod.env -d DIZ_NET -d DIZ_NET_stage --mode snapshot -- \
  bash -c "$T/db-apply-renames.sh --env-file config/prod.env --yes &&
           SCRIPT=\$($T/db-diff.sh --env-file config/prod.env -d DIZ_NET --project database/DIZ_NET) &&
           $T/db-apply-diff.sh --env-file config/prod.env -d DIZ_NET --script \"\$SCRIPT\" --yes &&
           $T/db-data-apply.sh --env-file config/prod.env -d DIZ_NET --yes"
```

`db-backup.sh run` creates one backup/snapshot per database, runs the command and

- restores all databases if the command fails (exit code ≠ 0), then exits with the command's exit code,
- drops the backups if it succeeds (unless `--keep`).

Scripts called inside `db-backup.sh run` do not create an additional backup.

## 6.5 Separate pipeline jobs – `create` / `restore` / `drop`

When backup, deployment and cleanup run in different jobs (e.g. a restore in an `on failure` job):

```bash
$T/db-backup.sh create  --env-file config/prod.env -d DIZ_NET -d DIZ_NET_stage --state-file artifacts/backup.state
# … deployment steps …
$T/db-backup.sh restore --env-file config/prod.env --state-file artifacts/backup.state   # only on failure
$T/db-backup.sh drop    --env-file config/prod.env --state-file artifacts/backup.state   # only on success
```

Pass the state file between jobs as a pipeline artifact.

## 6.6 Options of `db-backup.sh`

| Option | Meaning |
|---|---|
| `run` \| `create` \| `restore` \| `drop` | Sub-command (first argument) |
| `-d, --database NAME` | Database to back up (repeatable) |
| `--mode M` | `backup` \| `snapshot` (default `$BACKUP_MODE`, otherwise `backup`) |
| `--backup-dir PATH` | Directory **on the SQL Server host** (`BACKUP_DIR`) |
| `--no-compression` | Backup without compression (e.g. SQL Server Express) |
| `--keep` | Keep the backup after success (`BACKUP_KEEP=true`) |
| `--state-file FILE` | File listing the created backups (create/restore/drop) |
| `-- COMMAND …` | Command to protect (`run` only) |

## 6.7 Things to know

- **Location:** `BACKUP_DIR` is a path **on the SQL Server host**, not on the Linux agent. Without it,
  the default backup directory of the instance is used (for `snapshot`, the directory of the data files).
  There must be enough space.
- **Restore disconnects sessions:** before the restore the database is set to
  `SINGLE_USER WITH ROLLBACK IMMEDIATE`. Running ETL jobs are aborted.
- **Data written since the backup is lost:** everything written between backup and restore is gone –
  including entries in the history table (the log file of the run remains). Schedule deployments with
  backup in an ETL-free window.
- **Permissions:** `BACKUP DATABASE` requires `db_backupoperator`; restore and snapshots require
  `dbcreator` or `sysadmin`. The `.bak` file is deleted with `xp_delete_files` (SQL Server 2019+) or
  `xp_delete_file`. If this fails, only a warning is issued and the file remains.
- **Snapshot restrictions:** only this one snapshot may exist per database at restore time. Databases with
  FILESTREAM or memory-optimized filegroups cannot be reverted from a snapshot. A snapshot is no
  replacement for a real backup, because it depends on the source database.
- **SQL Server Express:** no snapshots, no compression – use `BACKUP_MODE=backup` with
  `BACKUP_COMPRESSION=false`.
- **`--keep`** / `BACKUP_KEEP=true` keeps the backup after success, e.g. as an extra safety net before
  large changes. Clean up manually afterwards.

Next: [7 – Configuration-data versioning](07-data-versioning.md)
