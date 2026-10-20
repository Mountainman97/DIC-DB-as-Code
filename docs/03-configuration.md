# 3 – Configuration

All scripts share one configuration model: a few `DB_*` variables describe the connection, a handful of
further variables control behaviour, and **publish profiles** control SqlPackage.

## 3.1 Where settings come from

Every setting can be provided in three ways. The first one found wins:

1. **Command-line option** (e.g. `--server`, `--database`),
2. **Env file** loaded with `--env-file FILE`,
3. **Environment variable** that is already set (e.g. a pipeline secret).

An env file is a plain shell file that is *sourced* by the scripts (`set -a; source FILE`). It can
therefore reference other environment variables:

```bash
# config/test.env
DB_SERVER="sql-test.example.local,1433"
DB_USER="svc_dacpac"
DB_TRUST_SERVER_CERT="true"
PUBLISH_PROFILE="tools/dic-db-as-code/toolkit/config/default.publish.xml"
DEPLOY_HISTORY_TABLE="dbo.__SchemaDeployHistory"
```

Typically there is one env file per environment (`config/dev.env`, `config/test.env`,
`config/prod.env`) in the database repository. A commented template is
[`toolkit/config/example.env`](../toolkit/config/example.env).

> Because env files are sourced, a line `DB_PASSWORD="…"` in an env file overrides an exported
> `DB_PASSWORD`. Leave the line out, or write `DB_PASSWORD="${DB_PASSWORD:-}"` /
> `DB_PASSWORD="${SOME_SECRET:-}"` (as the lab does).

## 3.2 Connection variables

| Variable | CLI option | Default | Meaning |
|---|---|---|---|
| `DB_SERVER` | `-S, --server` | – | `host`, `host,port` or `host\instance` (required) |
| `DB_NAME` | `-d, --database` | – | Database name (most scripts require `-d`) |
| `DB_AUTH` | `--auth` | `sql` | `sql` (login/password) or `integrated` (Kerberos, run `kinit` first, see [installation §4](01-installation.md#4-kerberos-optional-db_authintegrated)) |
| `DB_USER` | `-U, --user` | – | SQL login |
| `DB_PASSWORD` | – | – | Password – **only** as environment variable/secret |
| `DB_PASSWORD_FILE` | `--password-file` | – | Alternative: file containing the password (Docker/Kubernetes secret) |
| `DB_ENCRYPT` | `--no-encrypt` | `true` | TLS encryption of the connection |
| `DB_TRUST_SERVER_CERT` | `--trust-server-cert` | `false` | Do not validate the server certificate (self-signed certificates) |
| `DB_CONNECT_TIMEOUT` | `--connect-timeout` | `30` | Connection timeout in seconds |
| `DB_CONNECTION_STRING` | `--connection-string` | – | Complete connection string for SqlPackage (e.g. Microsoft Entra ID authentication); the database is replaced automatically |

## 3.3 Behaviour variables

| Variable | Used by | Meaning |
|---|---|---|
| `PUBLISH_PROFILE` | provision, diff | Default publish profile (overridden by `--profile`) |
| `PROTECTED_DATABASES` | all scripts that change a database | Comma-separated list, glob patterns allowed (e.g. `DIZ_NET,DIZ_NET_stage,*_PROD`). `db-provision-dev.sh` never overwrites these (except with `--allow-protected`); apply scripts ask for confirmation (or require `--yes`). |
| `DEPLOY_HISTORY_TABLE` | apply-diff, apply-renames | Default for `--history-table` (e.g. `dbo.__SchemaDeployHistory`) |
| `BACKUP_MODE` | apply-diff, apply-renames, data-apply, provision (update) | `none` (default), `backup` or `snapshot`, see [6 – Backup](06-backup.md) |
| `BACKUP_DIR` | backup | Backup location **on the SQL Server host** |
| `BACKUP_COMPRESSION` | backup | `true` (default); `false` for SQL Server Express |
| `BACKUP_KEEP` | backup | `true` keeps the backup after success (default `false`) |
| `DATA_MAX_ROWS` | data scripts | Safety limit per table (default `50000`; `max-rows` in `data.conf` takes precedence) |
| `SQLPACKAGE_BIN`, `SQLCMD_BIN` | all | Paths to the tools if not on the `PATH` |
| `SQLPACKAGE_EXTRA_ARGS`, `SQLCMD_EXTRA_ARGS` | all | Extra arguments for every call, e.g. `/p:CommandTimeout=600` |
| `DEBUG=1` | all | Additional debug output |
| `NO_COLOR=1` | all | Disable coloured output |

## 3.4 Secrets

Passwords never belong in env files in the repository. Recommended:

- **Pipelines:** store `DB_PASSWORD` as a secret variable and map it into the environment of the step
  (examples in [8 – Pipelines](08-pipelines.md)). Use different secrets per environment.
- **Locally:** `export DB_PASSWORD=…`, `--password-file ~/.secrets/dev_pw`, or a non-committed
  `config/*.local.env` (ignored by the shipped `.gitignore` pattern `*.local.env`).
- **Secret stores** (OpenBao/Vault, Azure Key Vault, …): fetch the password before the call and export it
  as `DB_PASSWORD`.

How the password is passed on:

- `sqlcmd` receives it via the environment variable `SQLCMDPASSWORD`, not on the command line.
- `sqlpackage` expects it inside the connection string. It is masked in the logs, but it is visible to
  other users of the same host in the process list. On shared build agents consider
  `DB_AUTH=integrated` (Kerberos).

## 3.5 Publish profiles

Publish profiles control the behaviour of SqlPackage's `Publish`, `Script` and `DeployReport` actions.
Two profiles are shipped in [`toolkit/config/`](../toolkit/config):

| Setting | `default.publish.xml` (TEST/PROD) | `dev.publish.xml` (DEV) |
|---|---|---|
| `BlockOnPossibleDataLoss` | **True** – abort if data could be lost | False |
| `DropObjectsNotInSource` | **False** – keep objects that only exist in the target | True – align exactly with the project |
| `IncludeTransactionalScripts` | True – change script runs in a transaction | True |
| `GenerateSmartDefaults` | True – defaults for new NOT NULL columns | True |
| Security objects (users, logins, permissions, role memberships) | excluded | excluded / never dropped |
| `ScriptDatabaseOptions` | False – leave recovery model etc. untouched | True – take options from the DACPAC for new databases |
| `IgnoreColumnOrder` | True – avoid table rebuilds | default |
| `VerifyDeployment` | True | default |

Properties given on the command line (`--property Name=Value`, `--drop-objects-not-in-source`,
`--allow-data-loss`) take precedence over the profile. All properties are listed in the
[SqlPackage Publish documentation](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-publish).

You can copy a profile into your database repository (e.g. `config/prod.publish.xml`) and adapt it.
Keep `DropObjectsNotInSource=False` on TEST/PROD unless the history table and all other non-project
objects are part of the project.

### SqlCmd variables for cross-database references

If a project references another database (see [4 – Schema deployment, references](04-schema-deployment.md#cross-database-references)),
its name can be made variable with an SqlCmd variable – either in the profile:

```xml
<ItemGroup>
  <SqlCmdVariable Include="DIZ_NET">
    <Value>DIZ_NET_DEV_1234</Value>
  </SqlCmdVariable>
</ItemGroup>
```

or per call with `--var DIZ_NET=DIZ_NET_DEV_1234`. References created by `db-extract.sh` use a fixed
database name (`DatabaseVariableLiteralValue`), which is the simplest choice when every environment uses
the same database names.

## 3.6 Example: three environments

```bash
# config/dev.env – disposable DEV databases
DB_SERVER="sql-dev.example.local"
DB_USER="svc_dacpac_dev"
DB_TRUST_SERVER_CERT="true"
PUBLISH_PROFILE="tools/dic-db-as-code/toolkit/config/dev.publish.xml"

# config/test.env
DB_SERVER="sql-test.example.local"
DB_USER="svc_dacpac_test"
PUBLISH_PROFILE="tools/dic-db-as-code/toolkit/config/default.publish.xml"
DEPLOY_HISTORY_TABLE="dbo.__SchemaDeployHistory"

# config/prod.env
DB_SERVER="sql-prod.example.local"
DB_USER="svc_dacpac_prod"
PUBLISH_PROFILE="tools/dic-db-as-code/toolkit/config/default.publish.xml"
DEPLOY_HISTORY_TABLE="dbo.__SchemaDeployHistory"
PROTECTED_DATABASES="DIZ_NET,DIZ_NET_stage"
BACKUP_MODE="snapshot"            # optional safety net for production only
```

Next: [4 – Schema deployment](04-schema-deployment.md)
