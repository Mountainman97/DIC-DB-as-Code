#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-data-init.sh – Datenversionierung fuer eine Datenbank einrichten
#
# Legt data/<Datenbank>/data.conf an (welche Tabellen versioniert werden) und
# liest die Daten dieser Tabellen erstmalig aus. Je Tabelle entsteht eine Datei
# data/<Datenbank>/<Schema>.<Tabelle>.sql mit einem MERGE-Skript, das eine Zeile
# pro Datensatz enthaelt (sortiert nach Primaerschluessel -> gut lesbare Git-Diffs).
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/data.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/data.sh"

usage() {
  cat <<USAGE
Verwendung: $(basename "$0") -d DB --include MUSTER [--include ...] [Optionen]

Optionen:
  -d, --database NAME        Quelldatenbank                                  (Pflicht)
  --include MUSTER           Schema (z.B. conf) oder Schema.Tabelle, * erlaubt (mehrfach)
  --exclude MUSTER           Tabellen ausnehmen, z.B. conf.Log* (mehrfach)
  --exclude-column T.SPALTE  Spalte nicht versionieren, z.B. *.GeaendertAm (mehrfach)
  --max-rows N               Abbruch bei Tabellen mit mehr Zeilen (Default: ${DATA_MAX_ROWS})
  --dir ORDNER               Basisordner (Default: data) -> ORDNER/<DB>/
  --force                    Vorhandene data.conf ueberschreiben
  -h, --help                 Diese Hilfe

$(connection_help)

Beispiel:
  $(basename "$0") --env-file config/prod.env -d DIZ_NET --include pc --include conf \\
      --exclude-column '*.GeaendertAm'
USAGE
}

preload_env_file "$@"
unset DB_NAME
INCLUDES=(); EXCLUDES=(); EXCL_COLS=(); MAX_ROWS="${DATA_MAX_ROWS}"; BASE_DIR="data"; FORCE=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    --include)        INCLUDES+=("${2:?}"); shift 2 ;;
    --exclude)        EXCLUDES+=("${2:?}"); shift 2 ;;
    --exclude-column) EXCL_COLS+=("${2:?}"); shift 2 ;;
    --max-rows)       MAX_ROWS=${2:?}; shift 2 ;;
    --dir)            BASE_DIR=${2:?}; shift 2 ;;
    --force)          FORCE=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

[[ -n "${DB_NAME:-}" ]] || { usage >&2; die "Keine Datenbank angegeben (--database)."; }
[[ ${#INCLUDES[@]} -gt 0 ]] || { usage >&2; die "Mindestens ein --include angeben."; }
[[ "${MAX_ROWS}" =~ ^[0-9]+$ ]] || die "--max-rows muss eine Zahl sein."
validate_connection
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (sqlcmd)."

DB_DIR="${BASE_DIR}/$(sanitize "${DB_NAME}")"
CONF="${DB_DIR}/data.conf"
if [[ -f "${CONF}" && "${FORCE}" != "true" ]]; then
  die "${CONF} existiert bereits. Zum Aktualisieren der Daten db-data-refresh.sh verwenden (oder --force)."
fi
database_exists "${DB_NAME}" || die "Datenbank '${DB_NAME}' existiert nicht auf ${DB_SERVER}."
mkdir -p "${DB_DIR}"

log_step "Schreibe ${CONF}"
{
  echo "# Datenversionierung fuer ${DB_NAME}"
  echo "# Erstellt: $(date '+%Y-%m-%d') mit db-data-init.sh"
  echo "# Syntax: include|exclude <Schema[.Tabelle]>, exclude-column <Tabellenmuster>.<Spalte>, max-rows <N>"
  for p in "${INCLUDES[@]}";  do echo "include ${p}"; done
  for p in "${EXCLUDES[@]}";  do echo "exclude ${p}"; done
  for p in "${EXCL_COLS[@]}"; do echo "exclude-column ${p}"; done
  echo "max-rows ${MAX_ROWS}"
} > "${CONF}"

log_step "Lese Daten aus ${DB_SERVER} / ${DB_NAME}"
if data_refresh_db "${DB_NAME}" "${DB_DIR}" false; then
  log_step "Fertig – Dateien in ${DB_DIR} pruefen und einchecken"
else
  die "Mindestens eine Tabelle konnte nicht exportiert werden (siehe oben)."
fi
