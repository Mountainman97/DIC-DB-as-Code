# Linux tools container for DIC-DB-as-Code
# Contains: .NET SDK 8, SqlPackage (dotnet tool), sqlcmd (mssql-tools18), git, unzip
FROM mcr.microsoft.com/dotnet/sdk:8.0

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    ACCEPT_EULA=Y \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl gnupg ca-certificates unzip libunwind8 git less nano \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
      > /etc/apt/sources.list.d/mssql-release.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends mssql-tools18 unixodbc \
 && rm -rf /var/lib/apt/lists/*

RUN dotnet tool install --tool-path /opt/sqlpackage microsoft.sqlpackage \
 && ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage \
 && ln -s /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd \
 && git config --global --add safe.directory '*' \
 && git config --global user.name  "DACPAC Lab" \
 && git config --global user.email "lab@example.local"

# Make the toolkit scripts callable directly (toolkit is mounted at /toolkit)
ENV PATH="/toolkit/scripts:${PATH}"
WORKDIR /workspace
CMD ["sleep", "infinity"]
