#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-data-apply.sh – Versionierte Daten auf eine Datenbank ausspielen
#
# Fuehrt die MERGE-Skripte aus data/<Datenbank>/ in EINER Transaktion aus:
#   1. Fremdschluessel ZWISCHEN den beteiligten Tabellen voruebergehend
#      deaktivieren (Reihenfolge der Tabellen spielt dadurch keine Rolle)
#   2. je Tabelle MERGE -> INSERT / UPDATE / DELETE auf den Stand der Datei
#   3. Fremdschluessel wieder aktivieren UND pruefen (WITH CHECK)
#   4. COMMIT – bei einem Fehler wird alles zurueckgerollt
#
# --dry-run fuehrt alles aus und rollt am Ende zurueck: so sieht man die
# Anzahl eingefuegter/geaenderter/geloeschter Zeilen je Tabelle ohne Wirkung.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

usage() {
  cat <<USAGE
Verwendung: $(basename "$0") -d DB [--dir ORDNER | --file DATEI ...] [Optionen]

Optionen:
  -d, --database NAME     Ziel-Datenbank                                       (Pflicht)
  --dir ORDNER            Ordner mit den Datendateien (Default: data/<DB>)
  --file DATEI            Nur diese Datei(en) ausspielen (mehrfach)
  --changed-since REF     Nur Dateien, die sich seit Git-Referenz REF geaendert haben
                          (z.B. origin/main, HEAD~1, v1.4.0)
  --no-delete             Zeilen, die nur in der DB existieren, NICHT loeschen
  --dry-run               Ausfuehren und zurueckrollen (zeigt die Aenderungen je Tabelle)
  --backup MODE           Vorher sichern, bei Fehler wiederherstellen: none|backup|snapshot
  --log-file DATEI        Protokoll (Default: keins, Ausgabe nur auf der Konsole)
  --yes                   Keine Rueckfrage bei geschuetzten Datenbanken
  -h, --help              Diese Hilfe

$(connection_help)

Beispiele:
  $(basename "$0") --env-file config/test.env -d DIZ_NET --dry-run
  $(basename "$0") --env-file config/test.env -d DIZ_NET
  $(basename "$0") --env-file config/prod.env -d DIZ_NET --changed-since origin/main
  # Daten einer anderen Quelle in eine DEV-DB mit anderem Namen:
  $(basename "$0") --env-file config/dev.env -d DIZ_NET_DEV_1234 --dir data/DIZ_NET
USAGE
}

ORIG_ARGS=("$@")
preload_env_file "$@"

DATA_DIR=""
FILES=()
CHANGED_SINCE=""
NO_DELETE=false
DRY_RUN=false
LOG_FILE=""
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    --dir)           DATA_DIR=${2:?}; shift 2 ;;
    --file)          FILES+=("${2:?}"); shift 2 ;;
    --changed-since) CHANGED_SINCE=${2:?}; shift 2 ;;
    --no-delete)     NO_DELETE=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --backup)        BACKUP_MODE=${2:?}; shift 2 ;;
    --log-file)      LOG_FILE=${2:?}; shift 2 ;;
    --yes|-y)        ASSUME_YES=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

[[ -n "${DB_NAME:-}" ]] || { usage >&2; die "Keine Ziel-Datenbank angegeben (--database oder DB_NAME)."; }
validate_connection
validate_backup_mode
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (sqlcmd)."
: "${DATA_DIR:=data/$(sanitize "${DB_NAME}")}"

# ------------------------------------------------------------ Dateien bestimmen
if [[ ${#FILES[@]} -eq 0 ]]; then
  [[ -d "${DATA_DIR}" ]] || die "Datenordner nicht gefunden: ${DATA_DIR}"
  if [[ -n "${CHANGED_SINCE}" ]]; then
    git -C "${DATA_DIR}" rev-parse --git-dir >/dev/null 2>&1 || die "--changed-since erfordert ein Git-Repository."
    mapfile -t rel < <(git -C "${DATA_DIR}" diff --name-only --relative --diff-filter=ACMR "${CHANGED_SINCE}" -- . 2>/dev/null \
                       | grep -E '\.sql$' || true)
    # zusaetzlich neue, noch nicht eingecheckte Dateien
    mapfile -t -O "${#rel[@]}" rel < <(git -C "${DATA_DIR}" ls-files --others --exclude-standard -- '*.sql' 2>/dev/null || true)
    for r in "${rel[@]}"; do [[ "${r}" == */* ]] && continue; FILES+=("${DATA_DIR}/${r}"); done
    log_info "Seit ${CHANGED_SINCE} geaendert: ${#FILES[@]} Datei(en)"
  else
    mapfile -t FILES < <(find "${DATA_DIR}" -maxdepth 1 -type f -name '*.sql' | sort)
  fi
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
  log_info "Keine Datendateien auszuspielen."
  exit 0
fi
mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | sort -u)

TABLES=()
for f in "${FILES[@]}"; do
  [[ -f "${f}" ]] || die "Datei nicht gefunden: ${f}"
  t="$(grep -m1 '^-- Tabelle: ' "${f}" | sed 's/^-- Tabelle: //' | tr -d '\r' || true)"
  [[ -n "${t}" ]] || die "Keine Datendatei (Kopfzeile '-- Tabelle:' fehlt): ${f}"
  grep -q -- '-- @@DELETE@@' "${f}" || die "Datei ist beschaedigt (Marker @@DELETE@@ fehlt): ${f}"
  TABLES+=("${t}")
done

log_step "Ziel ${DB_SERVER} / ${DB_NAME}: ${#FILES[@]} Tabelle(n)$([[ "${DRY_RUN}" == "true" ]] && echo ' – DRY-RUN')"
for i in "${!FILES[@]}"; do log_info "  ${TABLES[$i]}  <- ${FILES[$i]}"; done
[[ "${NO_DELETE}" == "true" ]] && log_info "Loeschen deaktiviert (--no-delete)."

database_exists "${DB_NAME}" || die "Datenbank '${DB_NAME}' existiert nicht auf ${DB_SERVER}."

if [[ "${DRY_RUN}" != "true" ]]; then
  if is_protected_db "${DB_NAME}" && [[ "${ASSUME_YES}" != "true" ]]; then
    confirm "'${DB_NAME}' ist eine geschuetzte Datenbank. Daten von ${#FILES[@]} Tabelle(n) jetzt ausspielen?" || die "Abgebrochen."
  fi
  # Optional: abgesichert ueber db-backup.sh neu starten (kehrt nur ohne Sicherung zurueck)
  backup_reexec "${DB_NAME}"
fi

# ------------------------------------------------------------ Gesamtskript bauen
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
MASTER="${WORK_DIR}/apply.sql"
tbl_values="$(printf "(N'%s')," "${TABLES[@]//\'/\'\'}")"; tbl_values="${tbl_values%,}"

{
  echo ":on error exit"
  echo "SET NOCOUNT ON;"
  echo "SET XACT_ABORT ON;"
  echo "BEGIN TRANSACTION;"
  echo "IF OBJECT_ID(N'tempdb..#dv_fk') IS NOT NULL DROP TABLE #dv_fk;"
  echo "CREATE TABLE #dv_fk (tbl NVARCHAR(400) NOT NULL, fk SYSNAME NOT NULL);"
  echo "INSERT INTO #dv_fk (tbl, fk)"
  echo "SELECT QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(fk.parent_object_id)), fk.name"
  echo "FROM sys.foreign_keys fk"
  echo "WHERE fk.is_disabled = 0"
  echo "  AND fk.parent_object_id     IN (SELECT OBJECT_ID(n) FROM (VALUES ${tbl_values}) x(n))"
  echo "  AND fk.referenced_object_id IN (SELECT OBJECT_ID(n) FROM (VALUES ${tbl_values}) x(n));"
  echo "DECLARE @sql NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(N'ALTER TABLE ' + tbl + N' NOCHECK CONSTRAINT ' + QUOTENAME(fk) + N';' AS NVARCHAR(MAX)), N' ') FROM #dv_fk);"
  echo "IF @sql IS NOT NULL EXEC (@sql);"
  echo "GO"
  i=0
  for f in "${FILES[@]}"; do
    src="$(abs_path "${f}")"
    if [[ "${NO_DELETE}" == "true" ]]; then
      i=$((i + 1)); src="${WORK_DIR}/${i}_$(basename "${f}")"
      grep -v -- '-- @@DELETE@@' "${f}" > "${src}"
    fi
    echo ":r \"${src}\""
  done
  echo "DECLARE @sql NVARCHAR(MAX) = (SELECT STRING_AGG(CAST(N'ALTER TABLE ' + tbl + N' WITH CHECK CHECK CONSTRAINT ' + QUOTENAME(fk) + N';' AS NVARCHAR(MAX)), N' ') FROM #dv_fk);"
  echo "IF @sql IS NOT NULL EXEC (@sql);"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;"
    echo "PRINT N'DRY-RUN: alle Aenderungen wurden zurueckgerollt.';"
  else
    echo "IF @@TRANCOUNT > 0 COMMIT TRANSACTION;"
  fi
  echo "GO"
} > "${MASTER}"

# ------------------------------------------------------------ Ausfuehren
log_step "Spiele Daten aus"
set +e; trap - ERR
if [[ -n "${LOG_FILE}" ]]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  run_sqlcmd "${DB_NAME}" -x -I -f 65001 -i "${MASTER}" 2>&1 | tee "${LOG_FILE}" >&2
  rc=${PIPESTATUS[0]}
else
  run_sqlcmd "${DB_NAME}" -x -I -f 65001 -i "${MASTER}" >&2
  rc=$?
fi
set -e; trap '_on_error $LINENO' ERR

if [[ ${rc} -ne 0 ]]; then
  die "Ausspielen FEHLGESCHLAGEN (sqlcmd Exit-Code ${rc}) – alle Datenaenderungen wurden zurueckgerollt."
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  log_step "Dry-Run beendet – nichts wurde geaendert."
else
  log_step "Fertig: Daten von ${#FILES[@]} Tabelle(n) auf ${DB_SERVER} / ${DB_NAME} ausgespielt."
fi
