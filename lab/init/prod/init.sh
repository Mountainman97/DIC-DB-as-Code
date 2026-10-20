#!/bin/bash
# Initialisiert DIZPROD einmalig mit DIZ_NET und DIZ_NET_stage inkl. Testdaten.
# Laeuft im Container DIZPROD-INIT (docker compose), idempotent.
set -euo pipefail
SQLCMD=/opt/mssql-tools18/bin/sqlcmd
[[ -x "$SQLCMD" ]] || { echo "sqlcmd (mssql-tools18) nicht im Image gefunden" >&2; exit 1; }
run() { "$SQLCMD" -S dizprod -U sa -P "$MSSQL_SA_PASSWORD" -C -b -x -f 65001 "$@"; }

exists="$(run -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name IN (N'DIZ_NET', N'DIZ_NET_stage');" | tr -d '[:space:]')"
if [[ "$exists" == "2" ]]; then
  echo "DIZ_NET und DIZ_NET_stage existieren bereits – Initialisierung uebersprungen."
  exit 0
fi

for f in /init/*.sql; do
  echo ">>> $(basename "$f")"
  run -i "$f"
done
echo "DIZPROD erfolgreich initialisiert."
