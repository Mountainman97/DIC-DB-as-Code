# 7 – Configuration-data versioning

In a DIC, many tables do not hold clinical data but **configuration and control data** that drive the ETL
processes – parameters, source system definitions, job schedules, mappings. Changes to these rows are as
important as schema changes and must be promoted together with them. DIC-DB-as-Code versions the
**rows** of selected tables (e.g. all tables in the schemas `conf` and `pc`) in the repository.

| Script | Purpose |
|---|---|
| `db-data-init.sh` | Set up versioning for a database: write `data.conf` and export the selected tables for the first time |
| `db-data-refresh.sh` | Re-export the versioned tables from a database (changes become visible with `git diff`) |
| `db-data-apply.sh` | Apply the versioned (possibly edited) rows to a database |

## 7.1 File format

For each table there is one file `data/<Database>/<Schema>.<Table>.sql`. It contains a `MERGE` script
with **one line per record**, ordered by primary key:

```sql
-- Tabelle: [pc].[Job]
-- Schluessel: [JobId]
...
MERGE INTO [pc].[Job] AS t
USING (
    SELECT
        CAST(v.[JobId] AS int) AS [JobId],
        CAST(v.[Name] AS nvarchar(100)) AS [Name],
        ...
    FROM (VALUES
    (10, N'KIS-Import nachts', N'0 2 * * *', 1, 3600),
    (20, N'LIS-Import', N'*/15 * * * *', 1, 600),
    (30, N'Pseudonymisierung', N'30 3 * * *', 0, NULL)
    ) AS v ([JobId], [Name], [Cron], [Aktiv], [TimeoutSek])
) AS s
ON t.[JobId] = s.[JobId]
WHEN MATCHED AND EXISTS (SELECT s.… EXCEPT SELECT t.…) THEN UPDATE SET …
WHEN NOT MATCHED BY TARGET THEN INSERT …
WHEN NOT MATCHED BY SOURCE THEN DELETE   -- @@DELETE@@
...
```

Why this format:

- **Every changed record is one changed line** in a pull request – reviewers see exactly which
  parameter or mapping was changed.
- The file can be **edited directly**: change, add or remove lines.
- On apply, the table is brought **exactly** to the state of the file (`INSERT`, `UPDATE`, `DELETE`).
  Only rows that actually differ are updated (`EXISTS … EXCEPT …`).
- The marker `-- @@DELETE@@` lets `db-data-apply.sh --no-delete` disable the delete branch.
- The files live outside the SQL project folders and are therefore not compiled.

## 7.2 Set up and export for the first time – `db-data-init.sh`

```bash
T=tools/dic-db-as-code/toolkit/scripts

$T/db-data-init.sh --env-file config/prod.env -d DIZ_NET \
    --include pc --include conf \
    --exclude-column '*.GeaendertAm'

git add data/ && git commit -m "Version configuration data pc/conf"
```

This writes `data/DIZ_NET/data.conf` and one file per table.

| Option | Meaning |
|---|---|
| `-d, --database NAME` | Source database (**required**) |
| `--include PATTERN` | Schema (e.g. `conf`) or `Schema.Table`; `*` and `?` allowed (repeatable) |
| `--exclude PATTERN` | Exclude tables, e.g. `conf.Log*` (repeatable) |
| `--exclude-column T.COL` | Do not version a column, e.g. `*.GeaendertAm` (repeatable) |
| `--max-rows N` | Abort for tables with more rows (default 50 000) |
| `--dir DIR` | Base folder (default `data`) → `DIR/<DB>/` |
| `--force` | Overwrite an existing `data.conf` |

### `data.conf`

```
include pc                       # schema (all tables) or schema.table, * and ? allowed
include conf
exclude conf.Log*                # exclude tables
exclude-column *.GeaendertAm     # do not version columns (table pattern.column)
max-rows 50000                   # safety limit per table
```

`data.conf` is the single source of truth for *which* tables are versioned. Edit it by hand to add or
remove tables, then run `db-data-refresh.sh`.

`exclude-column` is meant for columns that differ per environment, e.g. timestamps or host names.
Excluded columns are filled with their default on insert and left unchanged on update.

## 7.3 Re-export from a database – `db-data-refresh.sh`

When configuration was changed directly in a database (e.g. by an administrator in PROD), bring the
change back into the repository:

```bash
$T/db-data-refresh.sh --env-file config/prod.env              # all databases with a data.conf
$T/db-data-refresh.sh --env-file config/prod.env -d DIZ_NET
git diff data/                                                # what has changed?
```

New tables in the configured schemas are picked up automatically. Files of tables that no longer exist
(or are no longer selected) are reported as *orphaned* and deleted with `--prune`.

| Option | Meaning |
|---|---|
| `-d, --database NAME` | Only this database (default: every folder below `--dir` with a `data.conf`) |
| `--dir DIR` | Base folder (default `data`) |
| `--prune` | Delete files of tables that are no longer versioned |
| `--fail-on-changes` | Exit code 3 if data changed (drift check). Note: the files in the working tree are overwritten. |

## 7.4 Apply to a database – `db-data-apply.sh`

```bash
$T/db-data-apply.sh --env-file config/test.env -d DIZ_NET --dry-run                    # preview
$T/db-data-apply.sh --env-file config/test.env -d DIZ_NET                              # all tables
$T/db-data-apply.sh --env-file config/prod.env -d DIZ_NET --changed-since origin/main  # only changed files
$T/db-data-apply.sh --env-file config/dev.env  -d DIZ_NET_DEV_1234 --dir data/DIZ_NET   # other target name
```

What happens:

1. All files run in **one transaction**. On any error everything is rolled back.
2. Foreign keys **between** the involved tables are temporarily disabled, so the order of the tables does
   not matter. At the end they are re-enabled `WITH CHECK` and **validated** – invalid references cause a
   rollback. Foreign keys to tables outside the data versioning stay active.
3. For each table the number of inserted, updated and deleted rows is reported. `--dry-run` executes
   everything and rolls back at the end – useful as preview and as drift check ("does TEST differ from
   the data in the repository?").

| Option | Meaning |
|---|---|
| `-d, --database NAME` | Target database (**required**) |
| `--dir DIR` | Data folder (default `data/<DB>`); e.g. apply `data/DIZ_NET` to `DIZ_NET_DEV_1234` |
| `--file FILE` | Only specific file(s) (repeatable) |
| `--changed-since REF` | Only files changed since a Git reference (`origin/main`, `HEAD~1`, a tag), including new uncommitted files |
| `--no-delete` | Do not delete rows that only exist in the target database |
| `--dry-run` | Execute and roll back |
| `--backup MODE` | Optional backup ([6 – Backup](06-backup.md)) |
| `--log-file FILE` | Log file (default: console only) |
| `--yes` | No confirmation for protected databases |

**Order in the deployment:** renames → schema (diff/apply) → **data**. Tables and columns must already
exist in the target. `db-provision-dev.sh … --data data/DIZ_NET` applies the data right after
provisioning a DEV database.

## 7.5 Typical workflows

**Change configuration via pull request (recommended)**

1. Edit `data/DIZ_NET/pc.Job.sql` in the feature branch (e.g. set job 30 active, add job 40).
2. Test on the DEV database: `db-data-apply.sh --env-file config/dev.env -d DIZ_NET_DEV_1234 --dir data/DIZ_NET`.
3. Pull request → review of the changed lines.
4. Pipeline: `db-data-apply.sh --dry-run` as preview, after approval apply on TEST and PROD.

**Change made directly in PROD**

1. `db-data-refresh.sh --env-file config/prod.env -d DIZ_NET`
2. `git diff data/` → commit on a branch → pull request.
3. The pipeline promotes the change to TEST/DEV like any other change.

**Drift check (scheduled pipeline)**

```bash
$T/db-data-apply.sh --env-file config/test.env -d DIZ_NET --dry-run     # rows that would change
$T/db-data-refresh.sh --env-file config/prod.env --fail-on-changes      # exit 3 if PROD differs
```

## 7.6 Editing tips

- Each value list line ends with a comma, **except the last** line before `) AS v (…)`.
- Strings are `N'…'`; a single quote inside a string is doubled (`N'O''Brien'`).
- Line breaks in texts are stored as `+ NCHAR(10) +` so that every record stays on one line.
- `IDENTITY` columns are exported with their values (`SET IDENTITY_INSERT`). New rows added by hand
  need a unique value in the identity column.
- Run a modified file once with `--dry-run` before committing – syntax errors show up immediately.

## 7.7 Requirements and limitations

- Every versioned table needs a **primary key**. Tables without one are skipped with an error message.
- **SQL Server 2017+** for the export (`STRING_AGG`).
- Supported data types: numbers, date/time, strings, `xml`, `uniqueidentifier`, binary. Computed columns
  and `rowversion` are skipped. Columns of type `sql_variant`, `hierarchyid`, `geography` or `geometry`
  must be excluded with `exclude-column`.
- Intended for configuration and reference data; the export aborts above `max-rows` (default 50 000).
  **Never version clinical or personal data this way.**
- Applying requires `INSERT`/`UPDATE`/`DELETE` and `ALTER` on the tables (foreign keys,
  `IDENTITY_INSERT`).
- Files are executed with sqlcmd variables disabled (`-x`), so texts like `$(…)` in the data cause no
  problems. When running a file manually with `sqlcmd`, also use `-x`.

Next: [8 – Pipelines](08-pipelines.md)
