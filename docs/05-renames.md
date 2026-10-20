# 5 – Renames without data loss

## 5.1 Why rename scripts are needed

SqlPackage compares *states*. It cannot know that a column or table was **renamed** – it only sees
"old column missing, new column present" and generates *drop old column + add empty new column*. With
data in the table this either aborts (`BlockOnPossibleDataLoss=True`) or loses the data.

DIC-DB-as-Code therefore stores every rename additionally as a small **rename script** that performs the
rename with `sp_rename` on the target instance **before** the change script is generated or the DACPAC is
deployed. Afterwards the target and the project match, and SqlPackage no longer sees a difference for
the renamed object.

> SQL Server projects in Visual Studio solve this with a *refactor log*, which is tied to the IDE. The
> rename scripts here are plain SQL files that can be reviewed and run from any pipeline.

## 5.2 Naming convention

Rename scripts live in the folder `renames/` in the repository root – **not** inside an SQL project
folder, otherwise they would be compiled.

```
renameColumn_<Database>_<ColumnName>_<TableName>_<Feature>.sql
renameTable_<Database>_<TableName>_<Feature>.sql
```

- Column and table name in the file name are the **old** names.
- Schema, old and new name are defined inside the script.
- `<Feature>` is the ticket or feature identifier (e.g. `DIZ-42`) and can be used as a filter.

Examples:

```
renames/renameColumn_DIZ_NET_AnzahlZeilen_Ladelauf_DIZ-42.sql
renames/renameTable_DIZ_NET_Fachabteilung_DIZ-43.sql
renames/renameColumn_DIZ_NET_stage_Geburtsdatum_Patient_raw_DIZ-50.sql
```

## 5.3 Creating a rename script – `db-new-rename.sh`

```bash
T=tools/dic-db-as-code/toolkit/scripts

$T/db-new-rename.sh column -d DIZ_NET --schema etl --table Ladelauf \
    --old AnzahlZeilen --new Zeilenanzahl --feature DIZ-42
# -> renames/renameColumn_DIZ_NET_AnzahlZeilen_Ladelauf_DIZ-42.sql

$T/db-new-rename.sh table -d DIZ_NET --schema ref \
    --old Fachabteilung --new Abteilung --feature DIZ-43
# -> renames/renameTable_DIZ_NET_Fachabteilung_DIZ-43.sql
```

| Option | Meaning |
|---|---|
| `column` \| `table` | Kind of rename (first argument) |
| `-d, --database DB` | Database in which the rename happens (**required**) |
| `--schema S` | Schema (default `dbo`) |
| `--table T` | Table (only for `column`) |
| `--old NAME` / `--new NAME` | Old and new name (**required**) |
| `--feature F` | Feature/ticket, e.g. `DIZ-1234` (**required**) |
| `--dir DIR` | Target folder (default `renames`) |
| `--force` | Overwrite an existing file |

The templates are in [`toolkit/templates/rename/`](../toolkit/templates/rename). A generated script
looks like this (abridged):

```sql
-- Datenbank: DIZ_NET
-- Feature:   DIZ-42
DECLARE @Tabellenname NVARCHAR(128) = 'Ladelauf';
DECLARE @AlterName    NVARCHAR(128) = 'AnzahlZeilen';
DECLARE @NeuerName    NVARCHAR(128) = 'Zeilenanzahl';
DECLARE @Schema       NVARCHAR(128) = 'etl';

IF EXISTS (… old column exists …)
    EXEC sp_rename 'etl.Ladelauf.AnzahlZeilen', 'Zeilenanzahl', 'COLUMN';
ELSE IF EXISTS (… new column exists …)
    PRINT 'already renamed – nothing to do';
ELSE
    THROW 50001, 'Column not found', 1;
```

Behaviour:

- **Old name exists** → rename.
- **Old name missing, new name exists** → informational message, no error. This happens on instances
  that were already built with the new state, e.g. a freshly provisioned DEV database.
- **Neither exists** → `THROW 50001`, the run stops.

The header line `-- Datenbank: <Name>` (or `-- Database: <Name>`) makes the target database explicit
(see below). Hand-written scripts without this line also work, as long as the file name follows the
convention.

## 5.4 Update the project as well

The rename must also be made in the `.sql` files of the project: in the table definition and in all
views, procedures, functions, indexes and constraints that use the object.

```bash
grep -rn 'AnzahlZeilen' database/
grep -rl 'AnzahlZeilen' database/DIZ_NET | xargs sed -i 's/\bAnzahlZeilen\b/Zeilenanzahl/g'

# Table rename: also rename the file
git mv database/DIZ_NET/ref/Tables/Fachabteilung.sql database/DIZ_NET/ref/Tables/Abteilung.sql
```

Commit the rename script and the project changes **together** in the same pull request.

> After `sp_rename`, views and procedures in the database still contain the old names – SQL Server does
> not rewrite their source code. The subsequent change script brings them to the project state with
> `ALTER VIEW` / `ALTER PROCEDURE`.

## 5.5 Executing rename scripts – `db-apply-renames.sh`

```bash
$T/db-apply-renames.sh --env-file config/test.env --dir renames --dry-run   # show the plan
$T/db-apply-renames.sh --env-file config/test.env --dir renames             # execute
```

How the script works:

1. **Determine the database.** If the file has a header `-- Datenbank: <Name>` / `-- Database: <Name>`,
   it wins. Otherwise the file name is matched against the databases on the target instance, and the
   **longest** matching name wins (`renameColumn_DIZ_NET_stage_…` → `DIZ_NET_stage`, not `DIZ_NET`).
   If this is ambiguous (e.g. a column `stage_xyz` in `DIZ_NET`), a warning is shown; the header line
   makes it unambiguous.
2. **Order.** By the time the file was added to Git (oldest first), then by file name. Files not yet
   committed come last. This way, e.g., a table rename and a later column rename in that table run in
   the correct order.
3. **History.** Every execution is recorded in the history table of the respective database (default
   `dbo.__SchemaDeployHistory`, the same as for `db-apply-diff.sh`). Scripts that already ran
   successfully are skipped, so the whole folder can be passed on every deployment.
4. **Missing database.** If the database does not exist on the instance (e.g. an empty TEST instance),
   the script is skipped (`--strict` aborts instead).
5. **Errors.** The run stops at the first error (e.g. `THROW 50001`); subsequent scripts do not run.
6. **Protected databases** (`PROTECTED_DATABASES`) require confirmation or `--yes`.

| Option | Meaning |
|---|---|
| `--dir DIR` | Folder with rename scripts (default `renames`) |
| `--file FILE` | Individual file(s) instead of a folder (repeatable) |
| `-d, --database NAME` | Only scripts for this database (acts as a **filter**, not as connection target) |
| `--feature NAME` | Only scripts of this feature |
| `--history-table S.T` | History table per database (default `$DEPLOY_HISTORY_TABLE` or `dbo.__SchemaDeployHistory`) |
| `--no-history` | No history (scripts run every time – they are idempotent anyway) |
| `--force-rerun` | Run scripts again that already ran |
| `--strict` | Abort if the database of a script does not exist |
| `--dry-run` | Only show the plan |
| `--backup MODE` | Back up all affected databases first, restore on failure, drop on success (`none`/`backup`/`snapshot`, [6 – Backup](06-backup.md)) |
| `--yes` | No confirmation for protected databases |

## 5.6 Order in the deployment

The order is essential: **first renames, then diff, then apply.**

```bash
$T/db-apply-renames.sh --env-file config/test.env --dir renames --yes
SCRIPT=$($T/db-diff.sh --env-file config/test.env -d DIZ_NET --project database/DIZ_NET)
$T/db-apply-diff.sh   --env-file config/test.env -d DIZ_NET --script "$SCRIPT" --yes
```

- If the diff is generated **before** the renames, it contains drop + create for the renamed objects.
  Run renames, diff and apply in **one** pipeline stage after approval. A diff generated earlier can
  serve as preview – renames appear there as drop/create, and the rename scripts are shown next to it
  for review.
- To roll back the renames as well if the change script fails, wrap both steps in
  `db-backup.sh run` ([6 – Backup](06-backup.md)).
- For DEV databases, `db-provision-dev.sh --if-exists update --renames renames` runs the renames
  automatically before the deployment.
- A **newly created** database (provisioning from the project) needs no renames – it is created with the
  new names directly.

## 5.7 What happens if a rename script is forgotten?

On TEST/PROD the conservative profile protects you: the deployment report contains a `DataIssue` alert,
and the change script aborts as soon as the affected table contains rows. Add the rename script,
re-run renames and diff. On DEV (`dev.publish.xml`, `BlockOnPossibleDataLoss=False`) the column/table
would silently be dropped and recreated empty – harmless for disposable DEV data, but a good reason to
also use `--renames` there.

## 5.8 Housekeeping

Rename scripts can stay in the repository indefinitely – executed scripts are skipped via the history
table, and scripts whose old object no longer exists are no-ops. Once all environments (including
long-lived DEV databases) have run a rename, the script may be moved to an archive folder outside
`renames/`.

Next: [6 – Backup and rollback](06-backup.md)
