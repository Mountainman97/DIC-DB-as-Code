# 9 – Lab walkthrough (Docker)

The lab in [`lab/`](../lab) is a local test environment with three SQL Server instances and a Linux tools
container in which the toolkit scripts run. It lets you try the complete workflow – extraction,
provisioning, change deployment, renames, backup and configuration-data versioning – in about an hour,
without touching real systems.

| Container | Role | Content |
|---|---|---|
| **DIZPROD** | "production" | `DIZ_NET` and `DIZ_NET_stage` with test schemas and test data |
| **DIZTEST** | test instance | empty |
| **DIZDEV** | development instance | empty |
| **DIZTOOLS** | Linux tools container | sqlpackage, sqlcmd, .NET SDK 8, git; toolkit under `/toolkit`, working folder `/workspace` |
| DIZPROD-INIT | one-off job | seeds DIZPROD on first start, then exits |

## 9.1 Credentials

| Instance | from the host | from DIZTOOLS (Docker network) | Login | Password |
|---|---|---|---|---|
| DIZPROD | `localhost,14331` | `dizprod,1433` | `sa` | `DizProd_2026!` |
| DIZTEST | `localhost,14332` | `diztest,1433` | `sa` | `DizTest_2026!` |
| DIZDEV  | `localhost,14333` | `dizdev,1433`  | `sa` | `DizDev_2026!`  |

- The passwords are defined in [`lab/.env`](../lab/.env) and can be changed there before the first start.
- The instances use self-signed certificates → enable "Trust Server Certificate" in clients (sqlcmd: `-C`).
- Edition: SQL Server 2022 Developer. **For local testing only** – never reuse these passwords.

## 9.2 Prerequisites

- Docker Desktop (or OrbStack / Colima / Docker Engine on Linux) with **at least 8 GB memory** for Docker
  (each SQL Server instance is limited to 2 GB).
- **Apple Silicon (M1–M4):** the SQL Server image only exists for x86_64. In Docker Desktop enable
  *Settings → General → "Use Rosetta for x86_64/amd64 emulation on Apple Silicon"*. The containers then
  run emulated – this works but is noticeably slower than native.
- Internet access on first start (images and NuGet packages are downloaded).
- The lab mounts `../toolkit` into the tools container, so keep the repository structure as it is.

## 9.3 Start

```bash
cd lab
docker compose up -d --build
docker compose ps                    # wait until DIZPROD/DIZTEST/DIZDEV are "healthy"
docker compose logs dizprod-init     # should end with "DIZPROD erfolgreich initialisiert."
```

The first start takes a few minutes: the SQL Server image (~1.5 GB) is downloaded and the tools
container is built.

Open a shell in the tools container:

```bash
docker exec -it DIZTOOLS bash
```

All following commands run **inside DIZTOOLS** in `/workspace`. This folder is `lab/workspace` on the
host, so all results are visible there too. The toolkit scripts are on the `PATH`; the environment files
are in `/workspace/config/` (`prod.env`, `test.env`, `dev.env`) and read the passwords from the container
environment.

Quick connection test:

```bash
sqlcmd -S dizprod -U sa -P "$DIZPROD_SA_PASSWORD" -C -Q "SELECT name FROM sys.databases"
```

## 9.4 Test data on DIZPROD

**DIZ_NET** (core data)

| Schema | Objects |
|---|---|
| `ref` | `Fachabteilung` (5), `ICD10Katalog` (10), `LoincCode` (5) |
| `core` | `Patient` (25), `Fall` (40), `Diagnose` (~60), `Laborwert` (~100); view `vFallUebersicht`, function `fn_AlterBeiAufnahme` |
| `etl` | `Ladelauf` (3); procedures `usp_LadelaufStarten`, `usp_LadelaufBeenden` |
| `conf` | `Parameter` (IDENTITY), `Quellsystem`, `QuellsystemTabelle` (composite key, foreign key) |
| `pc` | `Job`, `JobSchritt` (multi-line JSON text), `Mapping` (GUID, float, decimal) |

**DIZ_NET_stage** (raw/staging data)

| Schema | Objects |
|---|---|
| `kis` | `Patient_raw` (30, two with invalid birth date), `Fall_raw` (10) |
| `lis` | `Befund_raw` (20) |
| `stage` | `Patient` (cleaned); view `vPatientAbgleich` and procedure `usp_PatientUebernehmen` with **cross-database access to `[DIZ_NET]`**; procedure `usp_PatientBereinigen` |

All data are fictitious. The scripts are in [`lab/init/prod/`](../lab/init/prod). Object names are German,
as in our production system.

---

## 9.5 Step 1 – initial extraction from DIZPROD

```bash
git init -b main          # optional: simulate the workspace as a repository

# DIZ_NET first (it is referenced by DIZ_NET_stage)
db-extract.sh --env-file config/prod.env -d DIZ_NET \
    -o database/DIZ_NET --dacpac artifacts/DIZ_NET.dacpac --build

# Then DIZ_NET_stage with a reference to DIZ_NET
db-extract.sh --env-file config/prod.env -d DIZ_NET_stage \
    -o database/DIZ_NET_stage --dacpac artifacts/DIZ_NET_stage.dacpac \
    --reference artifacts/DIZ_NET.dacpac=DIZ_NET --build

find database -name '*.sql' | sort
git add . && git commit -m "Initial import DIZ_NET / DIZ_NET_stage"
```

## 9.6 Step 2 – build the DEV instance from the repository

```bash
db-provision-dev.sh --env-file config/dev.env -d DIZ_NET       --project database/DIZ_NET
db-provision-dev.sh --env-file config/dev.env -d DIZ_NET_stage --project database/DIZ_NET_stage
```

The order matters because `DIZ_NET_stage` references objects in `DIZ_NET`. Only the structure is
transferred, no data. Check:

```bash
sqlcmd -S dizdev -U sa -P "$DIZDEV_SA_PASSWORD" -C -d DIZ_NET \
  -Q "SELECT s.name AS [Schema], t.name AS [Table] FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id ORDER BY 1,2"
```

## 9.7 Step 3 – first rollout to TEST

DIZTEST is empty, so the initial state is also created by provisioning (with the conservative
`default.publish.xml` configured in `test.env`):

```bash
db-provision-dev.sh --env-file config/test.env -d DIZ_NET       --project database/DIZ_NET
db-provision-dev.sh --env-file config/test.env -d DIZ_NET_stage --project database/DIZ_NET_stage
```

## 9.8 Step 4 – develop a change

Example: a new column in `core.Patient` and a new table `core.Einwilligung` (consent).

```bash
# Add a column (after the PLZ column)
sed -i 's/\(\[PLZ\][^,]*\),/\1,\n    [Sterbedatum] DATE NULL,/' database/DIZ_NET/core/Tables/Patient.sql
cat database/DIZ_NET/core/Tables/Patient.sql

# New table
cat > database/DIZ_NET/core/Tables/Einwilligung.sql <<'SQL'
CREATE TABLE [core].[Einwilligung] (
    [EinwilligungId] INT IDENTITY (1, 1) NOT NULL,
    [PatientId]      INT           NOT NULL,
    [Modul]          VARCHAR (50)  NOT NULL,
    [Status]         VARCHAR (20)  NOT NULL,
    [GueltigAb]      DATE          NOT NULL,
    [GueltigBis]     DATE          NULL,
    CONSTRAINT [PK_Einwilligung] PRIMARY KEY CLUSTERED ([EinwilligungId] ASC),
    CONSTRAINT [FK_Einwilligung_Patient] FOREIGN KEY ([PatientId]) REFERENCES [core].[Patient] ([PatientId])
);
SQL

# Update DEV
db-provision-dev.sh --env-file config/dev.env -d DIZ_NET --project database/DIZ_NET --if-exists update
git add . && git commit -m "Consent table + date of death"
```

> Check the structure of `Patient.sql` after extraction. If the `sed` does not match, insert the line
> `[Sterbedatum] DATE NULL,` by hand.

## 9.9 Step 5 – generate and execute a change script for TEST

```bash
db-diff.sh --env-file config/test.env -d DIZ_NET --project database/DIZ_NET --name DIZ_NET_feature1

less artifacts/diff/DIZ_NET_feature1.sql              # change script
less artifacts/diff/DIZ_NET_feature1.deployreport.xml # planned operations
cat  artifacts/diff/DIZ_NET_feature1.meta

# Check first, then execute
db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script artifacts/diff/DIZ_NET_feature1.sql --dry-run
db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script artifacts/diff/DIZ_NET_feature1.sql

# Second call: skipped thanks to the history table
db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script artifacts/diff/DIZ_NET_feature1.sql

# Verify: TEST now equals the repository (exit code 0)
db-diff.sh --env-file config/test.env -d DIZ_NET --project database/DIZ_NET --skip-empty --fail-on-changes; echo "Exit: $?"
```

## 9.10 Step 6 – drift check and rollout to PROD

```bash
# PROD differs from the repository -> exit code 3
db-diff.sh --env-file config/prod.env -d DIZ_NET --project database/DIZ_NET --name DIZ_NET_prod_feature1 --fail-on-changes
echo "Exit: $?"

# Execute (DIZ_NET is marked as protected in prod.env -> confirmation prompt)
db-apply-diff.sh --env-file config/prod.env -d DIZ_NET --script artifacts/diff/DIZ_NET_prod_feature1.sql
```

## 9.11 Step 7 – safety checks (optional)

- **Data-loss protection:** remove a column with data from a `.sql` file, e.g. `[PLZ]` in `Patient.sql`,
  and run `db-diff.sh` against PROD. The report warns about data loss, and the generated script aborts on
  execution because the table contains rows.
- **Target verification:** execute a change script generated for TEST with `--env-file config/dev.env`
  → aborted because of the different server.
- **Protected database:** `db-provision-dev.sh --env-file config/prod.env -d DIZ_NET --project database/DIZ_NET --if-exists recreate`
  → refused.
- **Portable scripts:** `db-diff.sh … --portable` creates a script without a fixed database name.

## 9.12 Step 8 – renames without data loss

Example in DIZ_NET: column `etl.Ladelauf.AnzahlZeilen` → `Zeilenanzahl` and table `ref.Fachabteilung` →
`ref.Abteilung`.

**a) Create rename scripts and update the project**

```bash
db-new-rename.sh column -d DIZ_NET --schema etl --table Ladelauf --old AnzahlZeilen --new Zeilenanzahl --feature DIZ-42
db-new-rename.sh table  -d DIZ_NET --schema ref --old Fachabteilung --new Abteilung --feature DIZ-43
ls renames/

# Update project files (table, procedure, foreign key, view)
grep -rl 'AnzahlZeilen' database/DIZ_NET | xargs sed -i 's/\bAnzahlZeilen\b/Zeilenanzahl/g'
grep -rl '\[ref\]\.\[Fachabteilung\]' database/DIZ_NET | xargs sed -i 's/\[ref\]\.\[Fachabteilung\]/[ref].[Abteilung]/g'
mv database/DIZ_NET/ref/Tables/Fachabteilung.sql database/DIZ_NET/ref/Tables/Abteilung.sql
grep -rn 'Zeilenanzahl\|\[ref\]\.\[Abteilung\]' database/DIZ_NET     # check

git add . && git commit -m "DIZ-42/DIZ-43 renames"
```

**b) What would happen without renames (look only, do not execute)**

```bash
db-diff.sh --env-file config/prod.env -d DIZ_NET --project database/DIZ_NET --name preview_without_renames
grep -nE 'DROP TABLE|DROP COLUMN|Rows were detected|CREATE TABLE' artifacts/diff/preview_without_renames.sql
```

The diff wants to drop `ref.Fachabteilung` and create an empty `ref.Abteilung`, and the same for the
column. The report warns about data loss, and the script would abort because data exist.

**c) Correct order on TEST: renames, then diff, then apply**

```bash
db-apply-renames.sh --env-file config/test.env --dir renames --dry-run
db-apply-renames.sh --env-file config/test.env --dir renames

db-diff.sh --env-file config/test.env -d DIZ_NET --project database/DIZ_NET --name DIZ_NET_renames
less artifacts/diff/DIZ_NET_renames.sql      # only ALTER VIEW / ALTER PROCEDURE, no DROP
db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script artifacts/diff/DIZ_NET_renames.sql

# Second run: everything already executed
db-apply-renames.sh --env-file config/test.env --dir renames
```

**d) PROD: data are preserved**

```bash
db-apply-renames.sh --env-file config/prod.env --dir renames          # prompt: protected database
db-diff.sh --env-file config/prod.env -d DIZ_NET --project database/DIZ_NET --name DIZ_NET_prod_renames
db-apply-diff.sh --env-file config/prod.env -d DIZ_NET --script artifacts/diff/DIZ_NET_prod_renames.sql

sqlcmd -S dizprod -U sa -P "$DIZPROD_SA_PASSWORD" -C -d DIZ_NET \
  -Q "SELECT * FROM ref.Abteilung; SELECT LadelaufId, Quelle, Zeilenanzahl FROM etl.Ladelauf; SELECT TOP 5 * FROM core.vFallUebersicht"
```

**e) Update DEV**

```bash
db-provision-dev.sh --env-file config/dev.env -d DIZ_NET --project database/DIZ_NET --if-exists update --renames renames
```

> Without `--renames`, the DEV profile (`BlockOnPossibleDataLoss=False`) would silently drop the table
> and recreate it empty. Harmless on DEV, but it shows why rename scripts are needed.

## 9.13 Step 9 – backup and rollback (optional)

A deliberately broken script first deletes data and then fails:

```bash
cat > artifacts/diff/broken.sql <<'SQL'
:on error exit
USE [DIZ_NET];
GO
DELETE FROM etl.Ladelauf;
GO
SELECT 1/0;   -- error
GO
SQL
```

**With backup** (snapshot) on PROD:

```bash
db-apply-diff.sh --env-file config/prod.env -d DIZ_NET --script artifacts/diff/broken.sql \
    --backup snapshot --history-table dbo.__SchemaDeployHistory
# -> snapshot created, script fails, snapshot is restored and dropped

sqlcmd -S dizprod -U sa -P "$DIZPROD_SA_PASSWORD" -C -d DIZ_NET -Q "SELECT COUNT(*) AS Ladelaeufe FROM etl.Ladelauf"   # still 3
sqlcmd -S dizprod -U sa -P "$DIZPROD_SA_PASSWORD" -C -Q "SELECT name FROM sys.databases"                            # no snapshot left
```

`--backup backup` does the same with a `.bak` file (under `/var/opt/mssql/data` in the DIZPROD container).

**Several steps as one unit:**

```bash
db-backup.sh run --env-file config/test.env -d DIZ_NET -d DIZ_NET_stage --mode snapshot -- \
  bash -c 'db-apply-renames.sh --env-file config/test.env --yes &&
           db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script artifacts/diff/broken.sql --yes --ignore-target-mismatch'
```

**Without backup** (for comparison, e.g. on TEST after inserting a few rows) the deleted data stay gone.

## 9.14 Step 10 – configuration-data versioning (schemas `pc` and `conf`)

**a) Create the test tables on PROD.** On a fresh installation (`docker compose down -v`) this happens
automatically. On an existing instance:

```bash
sqlcmd -S dizprod -U sa -P "$DIZPROD_SA_PASSWORD" -C -x -f 65001 -i testdata/03_DIZ_NET_pc_conf.sql
```

The test data deliberately contain single quotes, multi-line JSON and `$(…)`.

**b) Take the structure into the project and to TEST**

```bash
db-extract.sh --env-file config/prod.env -d DIZ_NET -o database/DIZ_NET --dacpac artifacts/DIZ_NET.dacpac --force
git status database/            # new files under conf/ and pc/
db-diff.sh --env-file config/test.env -d DIZ_NET --project database/DIZ_NET --name DIZ_NET_pc_conf
db-apply-diff.sh --env-file config/test.env -d DIZ_NET --script artifacts/diff/DIZ_NET_pc_conf.sql
```

> If you already performed the renames in step 8, re-extracting with `--force` reproduces the renamed
> PROD state – no conflict.

**c) Export the data from PROD for the first time**

```bash
db-data-init.sh --env-file config/prod.env -d DIZ_NET --include pc --include conf --exclude-column '*.GeaendertAm'
cat data/DIZ_NET/data.conf
less data/DIZ_NET/pc.JobSchritt.sql
git add data/ && git commit -m "Version configuration data pc/conf"
```

**d) Apply to TEST** (TEST only has the empty tables so far)

```bash
db-data-apply.sh --env-file config/test.env -d DIZ_NET --dry-run   # preview: everything "inserted"
db-data-apply.sh --env-file config/test.env -d DIZ_NET
db-data-apply.sh --env-file config/test.env -d DIZ_NET --dry-run   # now 0 / 0 / 0 everywhere
```

**e) Change data in the repository and apply**

```bash
nano data/DIZ_NET/pc.Job.sql
#  - job 30: change "0" -> "1" (active)
#  - add a new line, e.g.:  (40, N'Export', N'0 6 * * 1', 1, 1800),
#    (mind the commas: the last line before ") AS v" has no comma)
git diff data/

db-data-apply.sh --env-file config/test.env -d DIZ_NET --changed-since HEAD --dry-run
db-data-apply.sh --env-file config/test.env -d DIZ_NET --changed-since HEAD
git commit -am "Job 30 activated, job 40 added"
```

**f) Change made directly in the database → into the repository**

```bash
sqlcmd -S dizprod -U sa -P "$DIZPROD_SA_PASSWORD" -C -d DIZ_NET \
  -Q "UPDATE conf.Parameter SET Wert = N'10000' WHERE Schluessel = 'etl.batchgroesse'; DELETE FROM conf.QuellsystemTabelle WHERE Tabellenname = N'Fall_raw';"

db-data-refresh.sh --env-file config/prod.env -d DIZ_NET
git diff data/                  # exactly the two changed records
```

**g) Foreign-key validation:** add a line with an unknown source system to
`conf.QuellsystemTabelle.sql`, e.g. `(N'XYZ', N'Test', 5)`, and run `db-data-apply.sh … --dry-run`. It
aborts with a foreign-key violation; nothing is changed.

**h) Build DEV including data**

```bash
db-provision-dev.sh --env-file config/dev.env -d DIZ_NET --project database/DIZ_NET --if-exists update --data data/DIZ_NET
```

---

## 9.15 Connect with GUI tools

VS Code (extension *SQL Server (mssql)*), Azure Data Studio, DBeaver, DataGrip, SSMS (Windows):
server `localhost`, port `14331` / `14332` / `14333`, authentication *SQL login*, user `sa`, password see
above, enable *Trust Server Certificate*.

## 9.16 Management

```bash
docker compose stop                  # stop (data are kept)
docker compose start                 # start again
docker compose down                  # remove containers, keep volumes
docker compose down -v               # delete everything incl. data -> next start re-seeds PROD
docker compose up -d --build tools   # rebuild only the tools container
```

To reset the workspace, delete `lab/workspace/database`, `lab/workspace/artifacts`,
`lab/workspace/data`, `lab/workspace/renames` (and `lab/workspace/.git` if you initialised one).
`lab/workspace/config` and `lab/workspace/testdata` are kept.

> Work in `/workspace`, not in `/toolkit/scripts`: the scripts create `artifacts/`, `database/`, `data/`
> and `renames/` relative to the current directory.

## 9.17 Lab troubleshooting

| Symptom | Solution |
|---|---|
| SQL container does not start / exits immediately | `docker logs DIZPROD`. Often too little Docker memory (at least 8 GB); on Apple Silicon the Rosetta option may be missing. |
| `Password validation failed` in the log | Password in `lab/.env` does not meet the complexity rules → change it, `docker compose down -v`, start again |
| DIZPROD-INIT fails | `docker compose logs dizprod-init`; after fixing, `docker compose up -d dizprod-init` |
| `dotnet build` fails with `Unable to find package Microsoft.Build.Sql` | No internet access from the container (proxy?) → see [installation §3.4](01-installation.md#34-offline--internal-nuget-feed) |
| Build error `SQL71561` in DIZ_NET_stage | Extracted without `--reference` → repeat step 1 for DIZ_NET_stage with `--reference … --force` |
| Files appear under `lab/../toolkit/scripts/artifacts` | You ran the scripts inside `/toolkit/scripts` – switch to `/workspace` |

Next: [10 – Troubleshooting](10-troubleshooting.md)
