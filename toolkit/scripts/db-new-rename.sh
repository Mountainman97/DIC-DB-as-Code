#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-new-rename.sh – Legt ein Renaming-Skript aus der Vorlage an
#
# Dateinamen (Konvention):
#   renameColumn_<Datenbank>_<Spaltenname>_<Tabellenname>_<Feature>.sql
#   renameTable_<Datenbank>_<Tabellenname>_<Feature>.sql
# (Spalten-/Tabellenname = bisheriger, also ALTER Name)
#
# Ausgabe auf STDOUT: Pfad der angelegten Datei.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<EOF
Verwendung:
  $(basename "$0") column --database DB --schema S --table T --old ALT --new NEU --feature F [--dir ORDNER]
  $(basename "$0") table  --database DB --schema S --old ALT --new NEU --feature F [--dir ORDNER]

Legt ein Renaming-Skript (sp_rename ohne Datenverlust) nach der Namenskonvention an.

Optionen:
  -d, --database DB     Datenbank, in der umbenannt wird                     (Pflicht)
  --schema S            Schema (Default: dbo)
  --table T             Tabelle (nur bei 'column')
  --old ALT             Bisheriger Name der Spalte/Tabelle                   (Pflicht)
  --new NEU             Neuer Name                                           (Pflicht)
  --feature F           Feature/Ticket, z.B. DIZ-1234                        (Pflicht)
  --dir ORDNER          Zielordner (Default: renames)
  --force               Vorhandene Datei ueberschreiben
  -h, --help            Diese Hilfe

Beispiele:
  $(basename "$0") column -d DIZ_NET --schema etl --table Ladelauf --old AnzahlZeilen --new Zeilenanzahl --feature DIZ-42
  $(basename "$0") table  -d DIZ_NET --schema ref --old Fachabteilung --new Abteilung --feature DIZ-43
EOF
}

KIND="${1:-}"
[[ "${KIND}" == "-h" || "${KIND}" == "--help" ]] && { usage; exit 0; }
case "${KIND}" in
  column|table) shift ;;
  *) usage >&2; die "Erstes Argument muss 'column' oder 'table' sein." ;;
esac

DB="" SCHEMA="dbo" TABLE="" OLD="" NEW="" FEATURE="" DIR="renames" FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--database) DB=${2:?}; shift 2 ;;
    --schema)      SCHEMA=${2:?}; shift 2 ;;
    --table)       TABLE=${2:?}; shift 2 ;;
    --old)         OLD=${2:?}; shift 2 ;;
    --new)         NEW=${2:?}; shift 2 ;;
    --feature)     FEATURE=${2:?}; shift 2 ;;
    --dir)         DIR=${2:?}; shift 2 ;;
    --force)       FORCE=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

[[ -n "${DB}" && -n "${OLD}" && -n "${NEW}" && -n "${FEATURE}" ]] || { usage >&2; die "--database, --old, --new und --feature sind Pflicht."; }
[[ "${KIND}" == "table" || -n "${TABLE}" ]] || die "Fuer 'column' wird --table benoetigt."
for v in "${DB}" "${SCHEMA}" "${TABLE}" "${OLD}" "${NEW}" "${FEATURE}"; do
  [[ "${v}" != *"'"* && "${v}" != */* ]] || die "Namen duerfen weder ' noch / enthalten: ${v}"
done

if [[ "${KIND}" == "column" ]]; then
  FILE="${DIR}/renameColumn_${DB}_${OLD}_${TABLE}_${FEATURE}.sql"
  TEMPLATE="${TOOLKIT_ROOT}/templates/rename/renameColumn.sql.template"
else
  FILE="${DIR}/renameTable_${DB}_${OLD}_${FEATURE}.sql"
  TEMPLATE="${TOOLKIT_ROOT}/templates/rename/renameTable.sql.template"
fi
[[ -f "${TEMPLATE}" ]] || die "Vorlage nicht gefunden: ${TEMPLATE}"
if [[ -e "${FILE}" && "${FORCE}" != "true" ]]; then die "Datei existiert bereits: ${FILE} (--force zum Ueberschreiben)"; fi
mkdir -p "${DIR}"

DATABASE="${DB}" SCHEMA="${SCHEMA}" TABLE="${TABLE}" OLD="${OLD}" NEW="${NEW}" FEATURE="${FEATURE}" \
CREATED="$(date '+%Y-%m-%d')" \
awk '{
  gsub(/@@DATABASE@@/, ENVIRON["DATABASE"]); gsub(/@@SCHEMA@@/, ENVIRON["SCHEMA"]);
  gsub(/@@TABLE@@/, ENVIRON["TABLE"]);       gsub(/@@OLD@@/, ENVIRON["OLD"]);
  gsub(/@@NEW@@/, ENVIRON["NEW"]);           gsub(/@@FEATURE@@/, ENVIRON["FEATURE"]);
  gsub(/@@CREATED@@/, ENVIRON["CREATED"]);   print
}' "${TEMPLATE}" > "${FILE}"

log_info "Renaming-Skript angelegt: ${FILE}"
log_info "Nicht vergessen: Die Umbenennung auch in den .sql-Dateien des Projekts nachziehen"
log_info "(Tabellen-/Spaltendefinition und alle Views/Prozeduren, die das Objekt verwenden)."
echo "${FILE}"
