# 1 – Installation

This guide installs everything the toolkit needs on a Linux workstation or build agent:
**SqlPackage**, **sqlcmd** and the **.NET SDK** (to build SQL projects) – with internet access and
for **networks without internet access** (offline installation), which is common in hospital networks.

Versions as of October 2026 (SqlPackage 170.5.x, Microsoft.Build.Sql 2.3.0). Please check the linked
sources for current versions when installing.

| Tool | Used for | Required? |
|---|---|---|
| Bash ≥ 4.4 | all scripts | yes (tested with Bash 5.x) |
| SqlPackage | Extract, Publish, Script, DeployReport | yes |
| sqlcmd | existence checks, executing change/rename/data scripts, post-scripts | yes |
| .NET SDK ≥ 8 | building SQL projects into DACPACs; SqlPackage as dotnet tool | yes, as soon as you work with `--project` |
| `unzip` *or* `python3` | reading metadata (target platform, collation) from a DACPAC | yes (`db-extract.sh`) |
| `git` | ordering of rename scripts, `--changed-since`, commit hash in metadata | recommended |

Supported distributions for SqlPackage (x64): Debian 12+, RHEL 8+, SLES 15 SP6+, Ubuntu 22.04+.

> **Shortcut:** If you can use containers, the tools image in [`lab/tools/Dockerfile`](../lab/tools/Dockerfile)
> already contains everything. See also [section 6](#6-container-image-for-pipelines-optional).

---

## 1. SqlPackage

Official source: <https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-download>

There are two variants. **Variant A** is the simplest on build agents that have the .NET SDK installed
anyway. **Variant B** (self-contained ZIP) is meant for machines without .NET.

### 1.1 Variant A – as a dotnet tool (recommended if the .NET SDK is present)

Prerequisite: .NET SDK 8 or later (see [section 3](#3-net-sdk-and-sql-project-sdk)).

```bash
# Install for the current user
dotnet tool install -g microsoft.sqlpackage

# Add to PATH (once, e.g. in ~/.bashrc)
echo 'export PATH="$PATH:$HOME/.dotnet/tools"' >> ~/.bashrc
source ~/.bashrc

# Check
sqlpackage /Version
```

Update / remove:

```bash
dotnet tool update -g microsoft.sqlpackage
dotnet tool uninstall -g microsoft.sqlpackage
```

If only a newer .NET runtime is installed, use `--allow-roll-forward`:

```bash
dotnet tool install -g microsoft.sqlpackage --allow-roll-forward
```

**System-wide for build agents** (all users, e.g. the agent service account):

```bash
sudo dotnet tool install --tool-path /opt/sqlpackage microsoft.sqlpackage
sudo ln -sf /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage
```

### 1.2 Variant B – self-contained ZIP (no .NET installation)

```bash
# 1. Dependencies
sudo apt-get install -y libunwind8 unzip          # Debian / Ubuntu
# sudo dnf install -y libunwind libicu unzip      # RHEL / Rocky / Alma

# 2. Download (evergreen link to the current version)
curl -L -o /tmp/sqlpackage-linux.zip https://aka.ms/sqlpackage-linux

# 3. Extract to /opt/sqlpackage and make executable
sudo mkdir -p /opt/sqlpackage
sudo unzip -o /tmp/sqlpackage-linux.zip -d /opt/sqlpackage
sudo chmod a+x /opt/sqlpackage/sqlpackage

# 4. Add to PATH
sudo ln -sf /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage

# 5. Check
sqlpackage /Version
```

The toolkit finds SqlPackage automatically on the `PATH`, in `~/.dotnet/tools/`, `/opt/sqlpackage/`
and `~/sqlpackage/`. Alternatively, set `SQLPACKAGE_BIN=/path/to/sqlpackage`.

### 1.3 Offline installation

**ZIP variant:** Download `https://aka.ms/sqlpackage-linux` on a machine with internet access,
transfer the file (shared drive, internal artifact repository, …) and continue with step 3 of
[1.2](#12-variant-b--self-contained-zip-no-net-installation).

**dotnet tool variant:** Download the NuGet package `Microsoft.SqlPackage`
(<https://www.nuget.org/packages/Microsoft.SqlPackage>, "Download package"), put it into a folder and
install from there:

```bash
mkdir -p /opt/nuget-offline
cp microsoft.sqlpackage.*.nupkg /opt/nuget-offline/
dotnet tool install -g microsoft.sqlpackage --add-source /opt/nuget-offline
```

With an internal NuGet feed (Azure DevOps Artifacts, Nexus, ProGet, …) use `--add-source <feed-url>`.

---

## 2. sqlcmd

The toolkit works with both variants:

- **mssql-tools18** – the classic ODBC-based `sqlcmd` (installed to `/opt/mssql-tools18/bin`)
- **go-sqlcmd** – the new self-contained implementation (single binary, no ODBC dependency)

Official sources:

- <https://learn.microsoft.com/sql/linux/sql-server-linux-setup-tools>
- <https://learn.microsoft.com/sql/tools/sqlcmd/go-sqlcmd-utility>

### 2.1 mssql-tools18 – Debian / Ubuntu

```bash
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
# Ubuntu (version detected automatically); for Debian: .../config/debian/12/prod.list
curl -fsSL https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/mssql-release.list
sudo apt-get update
sudo ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc

echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
source ~/.bashrc
sqlcmd -?
```

> If `apt-get update` reports a missing key: add `[signed-by=/usr/share/keyrings/microsoft-prod.gpg]`
> after `deb` in `/etc/apt/sources.list.d/mssql-release.list`.

### 2.2 mssql-tools18 – RHEL / Rocky / Alma

```bash
# RHEL 9 (for RHEL 8: .../config/rhel/8/prod.repo)
curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo | sudo tee /etc/yum.repos.d/mssql-release.repo
sudo ACCEPT_EULA=Y dnf install -y mssql-tools18 unixODBC
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
```

### 2.3 go-sqlcmd

```bash
# From the Microsoft package repository (after setting it up as in 2.1/2.2)
sudo apt-get install -y sqlcmd          # or: sudo dnf install -y sqlcmd

# or as a single binary from GitHub
curl -L -o /tmp/sqlcmd.tar.bz2 https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-amd64.tar.bz2
sudo tar -xjf /tmp/sqlcmd.tar.bz2 -C /usr/local/bin sqlcmd
sqlcmd --version
```

### 2.4 Offline installation

- **go-sqlcmd** is the easiest: download the `tar.bz2` archive from GitHub on a machine with internet, copy, extract – done.
- **mssql-tools18**: download the packages and their dependencies on an online machine with the same distribution and install them on the target:

  ```bash
  # Debian/Ubuntu – on the online machine
  apt-get download mssql-tools18 msodbcsql18 unixodbc odbcinst libodbc2
  # on the target machine
  sudo ACCEPT_EULA=Y dpkg -i ./*.deb

  # RHEL – on the online machine
  dnf download --resolve mssql-tools18 msodbcsql18 unixODBC
  # on the target machine
  sudo ACCEPT_EULA=Y dnf install -y ./*.rpm
  ```

  Alternatively, mirror the Microsoft repository internally (Nexus, Artifactory, Satellite, aptly).

---

## 3. .NET SDK and SQL project SDK

Needed by `db-build.sh` – and therefore by `--project` in `db-provision-dev.sh` and `db-diff.sh` and by
`db-extract.sh --build` – and for SqlPackage as a dotnet tool.

### 3.1 Install the .NET SDK

```bash
# Ubuntu 22.04 / 24.04 (packages in the Ubuntu archive)
sudo apt-get update && sudo apt-get install -y dotnet-sdk-8.0

# Debian 12 (via the Microsoft repository, see 2.1)
sudo apt-get install -y dotnet-sdk-8.0

# RHEL 8 / 9
sudo dnf install -y dotnet-sdk-8.0

dotnet --list-sdks
```

Without a package manager (or without root), use the install script or the binary archive:

```bash
curl -L -o dotnet-install.sh https://dot.net/v1/dotnet-install.sh
bash dotnet-install.sh --channel 8.0 --install-dir "$HOME/.dotnet"
echo 'export DOTNET_ROOT="$HOME/.dotnet"; export PATH="$PATH:$HOME/.dotnet:$HOME/.dotnet/tools"' >> ~/.bashrc
```

Offline: download `dotnet-sdk-8.0.xxx-linux-x64.tar.gz` from <https://dotnet.microsoft.com/download/dotnet/8.0>
and extract it to `/opt/dotnet` (`DOTNET_ROOT=/opt/dotnet`, extend `PATH`).

Recommended on build agents:

```bash
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
```

### 3.2 SQL project SDK

The `.sqlproj` files created by `db-extract.sh` are **SDK-style** projects. The SDK is downloaded
automatically as a NuGet package on the first `dotnet build` – nothing has to be installed separately,
but NuGet must be able to reach the package.

| Template (`--project-sdk`) | NuGet package | Default version |
|---|---|---|
| `microsoft-build-sql` (default) | [Microsoft.Build.Sql](https://www.nuget.org/packages/Microsoft.Build.Sql) – official SDK by Microsoft | 2.3.0 |
| `msbuild-sdk-sqlproj` | [MSBuild.Sdk.SqlProj](https://www.nuget.org/packages/MSBuild.Sdk.SqlProj) – community SDK | 4.4.0 |

The version is stored in the `.sqlproj` (`<Sdk Name="…" Version="…" />` or `Sdk="…/Version"`) and can be
raised there at any time.

### 3.3 Test a build

```bash
cd database/DIZ_NET
dotnet build -c Release
ls bin/Release/*.dacpac
```

### 3.4 Offline / internal NuGet feed

Without access to nuget.org the build fails with *"Unable to find package Microsoft.Build.Sql"*. Options:

**a) Internal feed** (recommended; e.g. Azure DevOps Artifacts with nuget.org as upstream, Nexus,
ProGet). Create a `nuget.config` in the root of your database repository:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="internal" value="https://devops.example.local/tfs/Collection/_packaging/nuget-internal/nuget/v3/index.json" />
  </packageSources>
</configuration>
```

**b) Offline folder.** Build once on a machine with internet access (this puts all required packages
into the NuGet cache) and transfer the packages:

```bash
# online machine
cd database/DIZ_NET && dotnet build -c Release
# the packages are now under ~/.nuget/packages/
#   microsoft.build.sql/<version>/ (+ dependencies, if any)
```

Copy the `.nupkg` files from `~/.nuget/packages/<package>/<version>/` into a folder on the target system
(e.g. `/opt/nuget-offline`) and register it as source:

```xml
<configuration>
  <packageSources>
    <clear />
    <add key="offline" value="/opt/nuget-offline" />
  </packageSources>
</configuration>
```

Or per call: `db-build.sh --project … --dotnet-arg --source --dotnet-arg /opt/nuget-offline`.

---

## 4. Kerberos (optional, `DB_AUTH=integrated`)

To use Windows/AD authentication instead of an SQL login:

```bash
sudo apt-get install -y krb5-user        # RHEL: sudo dnf install -y krb5-workstation
# configure /etc/krb5.conf with your AD realm, then:
kinit svc_dacpac@EXAMPLE.LOCAL                                # interactive
kinit -kt /etc/svc_dacpac.keytab svc_dacpac@EXAMPLE.LOCAL    # with keytab (pipelines)
klist
```

Then set `DB_AUTH=integrated`; `DB_USER`/`DB_PASSWORD` are not needed. The SQL Server must have a valid
SPN (`MSSQLSvc/host.example.local:1433`), and `DB_SERVER` must be the fully qualified host name.

---

## 5. Verify the installation

```bash
sqlpackage /Version
sqlcmd -? | head -n 3
dotnet --list-sdks

# Test the connection (mssql-tools18 / go-sqlcmd)
SQLCMDPASSWORD="$DB_PASSWORD" sqlcmd -S "$DB_SERVER" -U "$DB_USER" -C -Q "SELECT @@VERSION"

# Make the scripts executable (if permissions were lost while copying)
chmod +x tools/dic-db-as-code/toolkit/scripts/*.sh
tools/dic-db-as-code/toolkit/scripts/db-extract.sh --help
```

## 6. Container image for pipelines (optional)

An image with all tools makes agents and runners interchangeable. Example `Dockerfile`:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:8.0
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 ACCEPT_EULA=Y
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg unzip libunwind8 ca-certificates lsb-release git \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" > /etc/apt/sources.list.d/mssql-release.list \
 && apt-get update && apt-get install -y --no-install-recommends mssql-tools18 unixodbc \
 && dotnet tool install --tool-path /opt/sqlpackage microsoft.sqlpackage \
 && ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage \
 && ln -s /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd \
 && rm -rf /var/lib/apt/lists/*
```

> The base image `mcr.microsoft.com/dotnet/sdk:8.0` is based on Debian 12 (bookworm). In networks
> without internet access, build the image outside and push it to your internal registry.

## 7. Database permissions

The login used by the toolkit needs, depending on the task:

| Task | Permission |
|---|---|
| Extraction | `VIEW DEFINITION` on the source database (or `db_owner`) |
| Provisioning a new database | `CREATE ANY DATABASE` (or `dbcreator`) on the target instance |
| Diff | `VIEW DEFINITION` on the target database |
| Apply diff / renames | DDL rights (`db_ddladmin` or `db_owner`); `CREATE TABLE` for the history table |
| Data apply | `INSERT`/`UPDATE`/`DELETE` and `ALTER` on the versioned tables (foreign keys, `IDENTITY_INSERT`) |
| Backup / snapshot | `db_backupoperator` for backups, `dbcreator`/`sysadmin` for restore and snapshots |

Next: [2 – Concepts and workflow](02-concepts.md)
