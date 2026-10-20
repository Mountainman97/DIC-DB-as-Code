# 10 – Troubleshooting

Start with more output: `DEBUG=1 <script> …`. For SqlPackage details add
`SQLPACKAGE_EXTRA_ARGS="/DiagnosticsFile:sqlpackage.log"`.

## 10.1 Installation and connection

| Symptom | Cause / solution |
|---|---|
| `sqlpackage nicht gefunden` / `sqlcmd nicht gefunden` | Tool not installed or not on the `PATH` → [1 – Installation](01-installation.md), or set `SQLPACKAGE_BIN` / `SQLCMD_BIN` |
| `SSL Provider: certificate verify failed` / *The certificate chain was issued by an authority that is not trusted* | Install the corporate CA certificate on the agent, or use `--trust-server-cert` / `DB_TRUST_SERVER_CERT=true` |
| `Login failed for user` | Check user and password (is `DB_PASSWORD` mapped into this step? does the env file overwrite it?); with `integrated`, check the Kerberos ticket (`klist`) |
| `Env-Datei nicht gefunden` | Path of `--env-file` is relative to the current directory – run from the repository root |
| Connection timeout | Firewall/port (default 1433), named instance needs SQL Browser (UDP 1434) or an explicit port `host,port`; raise `--connect-timeout` |
| `Sqlcmd: The -h and the -y 0 options are mutually exclusive` | Fixed in the current version of `lib/data.sh` (export uses `-y 0` without `-h`). Update the toolkit (submodule). |

## 10.2 Extraction and build

| Symptom | Cause / solution |
|---|---|
| Build: `SQL71561` / `SQL71501` *unresolved reference* | Missing cross-database reference → `--reference` ([4.1](04-schema-deployment.md#cross-database-references)) or add an `ArtifactReference` to the `.sqlproj`. References to `master`/`msdb` via the NuGet packages `Microsoft.SqlServer.Dacpacs.Master` / `.Msdb` |
| Build: `Unable to find package Microsoft.Build.Sql` | No access to nuget.org → internal feed or offline folder ([1 – Installation §3.4](01-installation.md#34-offline--internal-nuget-feed)) |
| Build compiles change/rename/data scripts | They are inside the project folder – move them out (`renames/`, `data/`, `artifacts/` belong to the repository root) |
| `db-extract.sh` refuses the folder | It already contains `.sql` files – use `--force` for a deliberate re-import |
| Publish: referenced DACPAC not found | Use `db-build.sh` (copies references next to the output) or put referenced DACPACs next to the DACPAC passed with `--dacpac` |

## 10.3 Diff and apply

| Symptom | Cause / solution |
|---|---|
| `Could not read profile xml` / *Error parsing connection string from profile* | Invalid publish profile (e.g. `--` inside an XML comment, wrong path). Validate with `xmllint --noout file.xml`; check `PUBLISH_PROFILE` in the env file |
| *TargetConnectionString cannot be used with other Target database arguments* | Old toolkit version or `SQLPACKAGE_EXTRA_ARGS` contains `/TargetDatabaseName` – remove it; the database is part of the connection string |
| `*** The column … is being dropped, data loss could occur` / *Rows were detected* | Protection by `BlockOnPossibleDataLoss`. Is it a rename? → add a rename script ([5 – Renames](05-renames.md)). Otherwise back up the data and generate deliberately with `--property BlockOnPossibleDataLoss=False` |
| `db-apply-diff.sh`: script was generated for database/server X | Change script generated against another target – regenerate it, or (deliberately) `--ignore-target-mismatch` |
| `db-apply-diff.sh`: checksum differs from `.meta` | The script was edited after generation – regenerate or review the change consciously |
| Script is skipped "already executed" | Same SHA-256 already in the history table with `SUCCESS` – intended; use `--force-rerun` to run again |
| Diff wants to drop the history table | `DropObjectsNotInSource=True` – keep it `False` on TEST/PROD or add the table to the project |
| Timeout on large tables | `SQLPACKAGE_EXTRA_ARGS="/p:CommandTimeout=0"` or `--query-timeout` for `db-apply-diff.sh` |
| Diff always shows changes to users/permissions | Security objects should be excluded – check `ExcludeObjectTypes` in the profile |

## 10.4 Renames

| Symptom | Cause / solution |
|---|---|
| `THROW 50001` – object not found | Neither old nor new name exists in the target: wrong schema/table in the script, or the database was not yet on the expected state. Check the script variables |
| Warning "ambiguous" | File name matches several databases – add the header `-- Datenbank: <Name>` |
| Rename script skipped "database does not exist" | Database not on this instance (e.g. empty TEST) – intended; `--strict` makes it an error |
| Renames in wrong order | Order follows the Git add time. Commit dependent renames in the right order, or use `--file` to run them explicitly |

## 10.5 Backup

| Symptom | Cause / solution |
|---|---|
| `Database snapshot … not supported` | Edition without snapshots (Express, older Standard) → `BACKUP_MODE=backup` |
| `BACKUP DATABASE is terminating abnormally` / path not found | `BACKUP_DIR` must exist **on the SQL Server host** and be writable by the SQL Server service account |
| Restore fails: *exclusive access could not be obtained* | Other sessions hold the database; the toolkit uses `SINGLE_USER WITH ROLLBACK IMMEDIATE` – check for jobs that reconnect immediately (SQL Agent) |
| `.bak` file remains after success | `xp_delete_files`/`xp_delete_file` not permitted – warning only; delete manually or grant the permission |

## 10.6 Data versioning

| Symptom | Cause / solution |
|---|---|
| Table skipped: no primary key | Add a primary key or exclude the table in `data.conf` |
| Export aborts: too many rows | Table exceeds `max-rows` – not a configuration table? Exclude it, or raise `max-rows` deliberately |
| Unsupported data type | Exclude the column with `exclude-column` (`sql_variant`, `hierarchyid`, `geography`, `geometry`) |
| Apply fails with a foreign-key violation | A row references a key that does not exist in the target – fix the data file (everything was rolled back) |
| Syntax error after manual edit | Typically a missing/extra comma before `) AS v` or an unescaped `'` – run with `--dry-run` |
| `Invalid object name` on apply | Schema not deployed yet – order is renames → schema → data |
| Different values in every environment show up as changes | Exclude environment-specific columns with `exclude-column` |
| Text with `$(` breaks a manual `sqlcmd` run | Use `sqlcmd -x` (disable variable substitution) as the toolkit does |

## 10.7 Getting help

When opening an issue, please include: the command line (without passwords), the output with `DEBUG=1`,
`sqlpackage /Version`, `sqlcmd -?` (first lines), the SQL Server version (`SELECT @@VERSION`) and, for
SqlPackage errors, the diagnostics file.
