# 4 – Schema deployment

This document describes the five scripts of the state-based core:

| Script | Purpose |
|---|---|
| [`db-extract.sh`](#41-db-extractsh--initial-extraction) | Existing database → `.sql` files + `.sqlproj` + initial DACPAC |
| [`db-build.sh`](#42-db-buildsh--build-a-project) | SQL project → DACPAC |
| [`db-provision-dev.sh`](#43-db-provision-devsh--provision-a-database) | Create/update a database from the repository (e.g. per feature branch) |
| [`db-diff.sh`](#44-db-diffsh--generate-a-change-script) | Target database vs. repository → change script + report + metadata |
| [`db-apply-diff.sh`](#45-db-apply-diffsh--execute-a-change-script) | Execute exactly one verified change script |

In all examples, `T=tools/dic-db-as-code/toolkit` and the working directory is the root of the
database repository. Connection options (`--env-file`, `-S`, `-U`, …) are described in
[3 – Configuration](03-configuration.md) and are accepted by every script.

---

## 4.1 `db-extract.sh` – initial extraction

**Purpose:** one-time import of an existing database into the repository.

**What it does:**

1. `sqlpackage /Action:Extract` → **initial DACPAC** (`artifacts/<name>.dacpac`).
2. `sqlpackage /Action:Extract /p:ExtractTarget=SchemaObjectType` → one `.sql` file per object,
   organised as `<Schema>/<ObjectType>/<Object>.sql`.
3. Reads the target platform (e.g. `Sql160`) and collation from the DACPAC and creates an **SDK-style
   `.sqlproj`**, so the folder can be built back into a DACPAC with `dotnet build` – on Linux, without
   Visual Studio. A `.gitignore` (`bin/`, `obj/`) is added.
4. Optional (`--build`): test build to verify that the project compiles.

**Example:**

```bash
$T/scripts/db-extract.sh \
    --env-file config/prod.env \
    --database DIZ_NET \
    --output-dir database/DIZ_NET \
    --dacpac artifacts/DIZ_NET.dacpac \
    --build
```

**Options:**

| Option | Meaning |
|---|---|
| `-o, --output-dir DIR` | Project folder for the `.sql` files (**required**) |
| `--dacpac FILE` | Path of the initial DACPAC (default `artifacts/<project name>.dacpac`) |
| `--project-name NAME` | Name of the project/`.sqlproj` (default: database name) |
| `--structure TYPE` | `SchemaObjectType` (default), `Schema`, `ObjectType`, `Flat` or `SqlProject` (SqlPackage creates the `.sqlproj` itself; requires a recent SqlPackage) |
| `--project-sdk SDK` | `microsoft-build-sql` (default, [Microsoft.Build.Sql](https://www.nuget.org/packages/Microsoft.Build.Sql)), `msbuild-sdk-sqlproj` ([MSBuild.Sdk.SqlProj](https://www.nuget.org/packages/MSBuild.Sdk.SqlProj)) or `none` |
| `--sdk-version VERSION` | Version of the project SDK |
| `--reference DACPAC[=DB]` | Reference to another database (repeatable), see below |
| `--include-permissions` | Also extract `GRANT`/`DENY` (default: no) |
| `--verify` | Let SqlPackage validate the extraction |
| `--property NAME=VALUE` | Additional extract property, e.g. `CommandTimeout=600` (repeatable) |
| `--build` | Test-build the project after creating it |
| `--force` | Extract into a folder that already contains `.sql` files (e.g. to re-import after changes made directly in PROD) |

**Result:** project folder with `.sql` files, `.sqlproj` and `.gitignore` – ready to commit.
STDOUT: path of the initial DACPAC.

### Cross-database references

If a database accesses another one with three-part names (`[DIZ_NET].[core].[Patient]`), the project
can only be built when the model of the other database is known. Extract the referenced database first
and pass its DACPAC as a reference:

```bash
$T/scripts/db-extract.sh --env-file config/prod.env -d DIZ_NET       -o database/DIZ_NET
$T/scripts/db-extract.sh --env-file config/prod.env -d DIZ_NET_stage -o database/DIZ_NET_stage \
    --reference artifacts/DIZ_NET.dacpac=DIZ_NET --build
```

The DACPAC is copied to `database/DIZ_NET_stage/references/` and registered as an `ArtifactReference`
with a fixed database name (`DatabaseVariableLiteralValue`). With mutual references, keep the reference
as a DACPAC file in one direction only (or as files in both directions) to avoid build cycles.

When the referenced database changes structurally, refresh the copy in `references/` (e.g. by building
`DIZ_NET` and copying the DACPAC) so that the referencing project builds against the current model.

### Notes

- **Security objects** (users, logins, role memberships, permissions) are environment-specific and are
  neither extracted nor deployed by default. Maintain them in a separate post-deployment script if needed.
- **Database options** (recovery model, compatibility level, …) are not stored as files with
  `--structure SchemaObjectType`. Use `--structure SqlProject` to version them completely.
- **Two extraction passes:** the source is read twice (DACPAC and files). If the schema changes in
  between, both states may differ slightly – extract during a quiet period.

---

## 4.2 `db-build.sh` – build a project

Builds the SQL project with `dotnet build` and copies the DACPAC to a defined location. Referenced
DACPACs (`ArtifactReference`) are copied into the same folder – SqlPackage looks for them next to the
source DACPAC during publish/script. Used internally by `db-provision-dev.sh` and `db-diff.sh` with
`--project`, and typically the first step of a pipeline.

```bash
$T/scripts/db-build.sh --project database/DIZ_NET --output artifacts/DIZ_NET.dacpac
```

| Option | Meaning |
|---|---|
| `-p, --project PATH` | Project folder (with exactly one `.sqlproj`) or `.sqlproj` file (**required**) |
| `-o, --output FILE` | Target DACPAC (default `artifacts/build/<project>.dacpac`) |
| `-c, --configuration CONF` | Build configuration (default `Release`) |
| `--dotnet-arg ARG` | Additional argument for `dotnet build` (repeatable), e.g. `--dotnet-arg --source --dotnet-arg /opt/nuget-offline` |

> If you pass `--dacpac` instead of `--project` to other scripts, place referenced DACPACs next to the
> source DACPAC yourself (or build with `db-build.sh`, which does it for you).

---

## 4.3 `db-provision-dev.sh` – provision a database

**Purpose:** create a database on a target instance and deploy the repository state – for example one
DEV database per feature branch (`DIZ_NET_DEV_1234`), or the initial state of an empty TEST instance.

**What it does:**

1. Provides the source: an existing DACPAC (`--dacpac`) or builds the project (`--project`).
2. Checks whether the target database exists and, depending on `--if-exists`, aborts, updates or
   recreates it.
3. Optionally (with `update`): runs rename scripts for this database (`--renames`) and creates a backup
   (`--backup`).
4. `sqlpackage /Action:Publish` – creates the database (if missing) and all objects.
5. Optionally: applies versioned configuration data (`--data`) and executes post-scripts
   (`--post-script`, e.g. test data).

**Examples:**

```bash
# New DEV database from the current project state
$T/scripts/db-provision-dev.sh \
    --env-file config/dev.env \
    --database DIZ_NET_DEV_1234 \
    --project database/DIZ_NET \
    --profile $T/config/dev.publish.xml

# Keep an existing DEV database up to date, including renames and configuration data
$T/scripts/db-provision-dev.sh --env-file config/dev.env -d DIZ_NET_DEV_1234 \
    --project database/DIZ_NET --if-exists update \
    --renames renames --data data/DIZ_NET

# Rebuild a DEV database from scratch and load test data
$T/scripts/db-provision-dev.sh --env-file config/dev.env -d DIZ_NET_DEV \
    --dacpac artifacts/DIZ_NET.dacpac \
    --if-exists recreate --yes \
    --post-script testdata/01_master_data.sql --post-script testdata/02_cases.sql
```

**Options:**

| Option | Meaning |
|---|---|
| `--dacpac FILE` \| `--project PATH` | Source (exactly one) |
| `--if-exists fail\|update\|recreate` | Behaviour if the database exists (default `fail`) |
| `--profile FILE` | Publish profile (default: `$PUBLISH_PROFILE`) |
| `--var NAME=VALUE` | SqlCmd variable, e.g. for references: `--var DIZ_NET=DIZ_NET_DEV_1234` |
| `--property NAME=VALUE` | Additional publish property |
| `--allow-data-loss` | `BlockOnPossibleDataLoss=False` (useful with `update`) |
| `--renames DIR` | With `--if-exists update`: run rename scripts for this database first ([5 – Renames](05-renames.md)) |
| `--data DIR` | Apply versioned data after the deployment, e.g. `data/DIZ_NET` ([7 – Data versioning](07-data-versioning.md)) |
| `--post-script FILE` | Execute after the deployment (repeatable, order is kept) |
| `--backup MODE` | With `--if-exists update`: back up first, restore on failure, drop on success (`none`/`backup`/`snapshot`, [6 – Backup](06-backup.md)) |
| `--allow-protected` | Also allow databases listed in `PROTECTED_DATABASES` |
| `--yes` | No confirmation prompt for `recreate` (pipelines) |

**Safety:** by default an existing database is never changed (`--if-exists fail`). `recreate` asks
interactively or requires `--yes`. Databases in `PROTECTED_DATABASES` are always refused unless
`--allow-protected` is given.

**Order with references:** provision referenced databases first (`DIZ_NET` before `DIZ_NET_stage`).

**Naming per branch:** a common pattern in pipelines is `-d "DIZ_NET_DEV_${BRANCH_ID}"` together with
`--var DIZ_NET=DIZ_NET_DEV_${BRANCH_ID}` for the referencing project, and a cleanup job that drops the
database when the branch is merged.

---

## 4.4 `db-diff.sh` – generate a change script

**Purpose:** compare the current state of a target database with the repository and generate an SQL
script that brings the database to the repository state. Also usable as a **drift check**
("does PROD differ from the repository?").

**What it does:**

1. Builds the project (`--project`) or uses a DACPAC (`--dacpac`).
2. `sqlpackage /Action:DeployReport` → `<name>.deployreport.xml` (all changes, data-loss warnings).
3. `sqlpackage /Action:Script` → `<name>.sql` (executable SQLCMD script).
4. Writes `<name>.meta` with target server/database, Git commit, SHA-256 of DACPAC and script, and the
   SqlPackage version.

**Example:**

```bash
$T/scripts/db-diff.sh \
    --env-file config/test.env \
    --database DIZ_NET \
    --project database/DIZ_NET \
    --profile $T/config/default.publish.xml \
    --output-dir artifacts/diff
# STDOUT: /…/artifacts/diff/DIZ_NET_20261016T101500Z.sql
```

Drift check in a pipeline (exit code 3 if there are differences):

```bash
$T/scripts/db-diff.sh --env-file config/prod.env -d DIZ_NET --project database/DIZ_NET \
    --skip-empty --fail-on-changes
```

**Options:**

| Option | Meaning |
|---|---|
| `--project PATH` \| `--dacpac FILE` | Source (exactly one) |
| `--output-dir DIR` | Output location (default `artifacts/diff`; **not** inside the project folder) |
| `--name NAME` | File name without extension (default `<DB>_<UTC timestamp>`) |
| `--profile FILE` | Publish profile (default: `$PUBLISH_PROFILE`) |
| `--var NAME=VALUE` | SqlCmd variable |
| `--property NAME=VALUE` | Additional property |
| `--drop-objects-not-in-source` | Drop objects that only exist in the target database |
| `--portable` | Comment out `:setvar` declarations; the database name is set at execution time |
| `--no-report` | Do not create a deployment report |
| `--skip-empty` | Do not keep files if there are no changes |
| `--fail-on-changes` | Exit code **3** if changes were found |

**Output files** (for `--name DIZ_NET_feature1`):

| File | Content |
|---|---|
| `DIZ_NET_feature1.sql` | Change script (review this) |
| `DIZ_NET_feature1.deployreport.xml` | List of operations and warnings (e.g. `DataIssue`) |
| `DIZ_NET_feature1.meta` | Target, Git commit, checksums, SqlPackage version |

**Important:** a change script describes the difference to the state of the target database **at the
time it was generated**. Execute it promptly and only on exactly this database. `db-apply-diff.sh`
checks this via `:setvar DatabaseName` and the `.meta` file. In pipelines, generate the script in the
same job that executes it (after rename scripts, see [5 – Renames](05-renames.md)); a script generated
earlier serves as preview.

**Reading the report:** look for `<Operation Name="Drop">`, `<Operation Name="TableRebuild">` and
`<Alert Name="DataIssue">`. With `BlockOnPossibleDataLoss=True`, the generated script contains a guard
that aborts if an affected table contains rows.

---

## 4.5 `db-apply-diff.sh` – execute a change script

**Purpose:** execute one specific (ideally reviewed and approved) change script on a target database.

**What it does:**

1. **Checks:** the target database in the script (`:setvar DatabaseName`) and in the `.meta` file must
   match `--database`/`--server`; modified scripts (SHA-256 differs from `.meta`) are reported.
2. Checks that the target database exists; optionally creates the history table and checks whether the
   script (same SHA-256) already ran successfully – if so, nothing is done.
3. Executes the script with `sqlcmd` (SQLCMD mode, stop at the first error `-b`); output is also
   written to a log file.
4. Records the result (SUCCESS/FAILED, duration, host, login) in the history table.

**Example:**

```bash
# Check first …
$T/scripts/db-apply-diff.sh --env-file config/test.env \
    -d DIZ_NET --script artifacts/diff/DIZ_NET_20261016T101500Z.sql --dry-run

# … then execute
$T/scripts/db-apply-diff.sh --env-file config/test.env \
    -d DIZ_NET --script artifacts/diff/DIZ_NET_20261016T101500Z.sql \
    --history-table dbo.__SchemaDeployHistory
```

**Options:**

| Option | Meaning |
|---|---|
| `-i, --script FILE` | Change script to execute (**required**) |
| `--var NAME=VALUE` | Additional SqlCmd variable |
| `--history-table S.T` | History table in the target database (created if needed), prevents double execution (default `$DEPLOY_HISTORY_TABLE`) |
| `--force-rerun` | Execute again despite a history entry |
| `--query-timeout SEC` | Timeout per batch (default 0 = unlimited) |
| `--log-file FILE` | Log file (default `<script>.<timestamp>.log`) |
| `--ignore-target-mismatch` | Ignore a different target database/server |
| `--dry-run` | Only check, do not execute |
| `--backup MODE` | Back up first, restore on failure, drop on success (`none`/`backup`/`snapshot`, [6 – Backup](06-backup.md)) |
| `--yes` | No confirmation prompts (e.g. protected databases in pipelines) |

**Transactions:** with `IncludeTransactionalScripts=True` (set in `default.publish.xml`), SqlPackage
generates a script that is rolled back on error. Some statements (e.g. full-text indexes) cannot run in a
transaction; for these, use `--backup` as safety net.

**History table:** the table is not part of the SQL project. With `DropObjectsNotInSource=True` a diff
would drop it. Either add it to the project or keep `DropObjectsNotInSource=False` (default in
`default.publish.xml`). Its structure:

| Column | Content |
|---|---|
| `Id` | Identity, primary key |
| `ScriptName`, `ScriptSha256` | File name and SHA-256 of the script |
| `Status` | `SUCCESS` or `FAILED` |
| `AppliedAtUtc`, `DurationSec` | Execution time (UTC) and duration |
| `AppliedBy`, `ClientHost` | Login and agent host |

---

## 4.6 Putting it together

```bash
T=tools/dic-db-as-code/toolkit/scripts

# 1. Build once
$T/db-build.sh --project database/DIZ_NET --output artifacts/DIZ_NET.dacpac

# 2. Preview against TEST
SCRIPT=$($T/db-diff.sh --env-file config/test.env -d DIZ_NET --dacpac artifacts/DIZ_NET.dacpac)
less "$SCRIPT"

# 3. Execute after review
$T/db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script "$SCRIPT" --yes

# 4. Verify: TEST now equals the repository (exit code 0)
$T/db-diff.sh --env-file config/test.env -d DIZ_NET --dacpac artifacts/DIZ_NET.dacpac \
    --skip-empty --fail-on-changes
```

If the change contains renamed columns or tables, run the rename scripts before step 2 –
see [5 – Renames](05-renames.md).

Next: [5 – Renames without data loss](05-renames.md)
