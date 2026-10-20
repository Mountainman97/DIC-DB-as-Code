#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-apply-renames.sh – Fuehrt Renaming-Skripte (sp_rename) auf der im
#                       Dateinamen hinterlegten Datenbank aus
#
# Hintergrund: SqlPackage erkennt Umbenennungen nicht und wuerde eine Spalte/
# Tabelle loeschen und neu anlegen (Datenverlust). Deshalb werden Umbenennungen
# VOR dem Diff/Deployment per sp_rename auf der Zielinstanz ausgefuehrt. Danach
# stimmen Ziel und Projekt ueberein und SqlPackage sieht keine Aenderung mehr.
#
# Dateinamen (Konvention):
#   renameColumn_<Datenbank>_<Spaltenname>_<Tabellenname>_<Feature>.sql
#   renameTable_<Datenbank>_<Tabellenname>_<Feature>.sql
#
# Ermittlung der Datenbank:
#   1. Kopfzeile "-- Datenbank: <Name>" in der Datei (hat Vorrang), sonst
#   2. laengster Datenbankname der Zielinstanz, mit dem der Dateiname nach
#      "renameColumn_" / "renameTable_" beginnt (DIZ_NET_stage vor DIZ_NET).
#
# Reihenfolge: nach dem Zeitpunkt, zu dem die Datei in Git hinzugefuegt wurde
# (aelteste zuerst), danach Dateiname. Nicht eingecheckte Dateien kommen zuletzt.
#
# Bereits erfolgreich ausgefuehrte Skripte werden ueber eine Historientabelle
# in der jeweiligen Datenbank erkannt und uebersprungen.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") [--dir ORDNER | --file DATEI ...] [Optionen]

Fuehrt Renaming-Skripte auf der Zielinstanz aus. Die Datenbank wird aus dem
Dateinamen ermittelt (siehe Kopf dieses Skripts).

Optionen:
  --dir ORDNER              Ordner mit Renaming-Skripten (Default: renames)
  --file DATEI              Einzelne Datei(en) statt Ordner (mehrfach)
  -d, --database NAME       Nur Skripte fuer diese Datenbank ausfuehren
  --feature NAME            Nur Skripte dieses Features ausfuehren
  --history-table S.T       Historientabelle je Datenbank
                            (Default: \$DEPLOY_HISTORY_TABLE oder dbo.__SchemaDeployHistory)
  --no-history              Keine Historie (Skripte laufen jedes Mal)
  --force-rerun             Auch bereits ausgefuehrte Skripte erneut ausfuehren
  --strict                  Abbruch, wenn die Datenbank eines Skripts auf der
                            Instanz nicht existiert (Default: ueberspringen)
  --backup MODE             Vorher sichern, bei Fehler wiederherstellen, bei Erfolg
                            Sicherung loeschen: none|backup|snapshot [BACKUP_MODE]
  --dry-run                 Nur anzeigen, was ausgefuehrt wuerde
  --yes                     Keine Rueckfrage bei geschuetzten Datenbanken
  -h, --help                Diese Hilfe

$(connection_help)
  (--database wirkt hier als Filter, nicht als Verbindungsziel)

Beispiele:
  $(basename "$0") --env-file config/test.env --dir renames --dry-run
  $(basename "$0") --env-file config/test.env --dir renames
  $(basename "$0") --env-file config/prod.env --dir renames --feature DIZ-42
EOF
}

ORIG_ARGS=("$@")
preload_env_file "$@"

# DB_NAME aus einer Env-Datei ist hier kein Filter – nur explizites --database
unset DB_NAME
RENAME_DIR="renames"
FILES=()
FEATURE_FILTER=""
HISTORY_TABLE="${DEPLOY_HISTORY_TABLE:-dbo.__SchemaDeployHistory}"
FORCE_RERUN=false
STRICT=false
DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    --dir)           RENAME_DIR=${2:?}; shift 2 ;;
    --file)          FILES+=("${2:?}"); shift 2 ;;
    --feature)       FEATURE_FILTER=${2:?}; shift 2 ;;
    --history-table) HISTORY_TABLE=${2:?}; shift 2 ;;
    --no-history)    HISTORY_TABLE=""; shift ;;
    --force-rerun)   FORCE_RERUN=true; shift ;;
    --strict)        STRICT=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --backup)        BACKUP_MODE=${2:?}; shift 2 ;;
    --yes|-y)        ASSUME_YES=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done
DB_FILTER="${DB_NAME:-}"
validate_backup_mode

validate_connection
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (sqlcmd)."
if [[ -n "${HISTORY_TABLE}" ]]; then
  [[ "${HISTORY_TABLE}" =~ ^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$ ]] \
    || die "--history-table muss die Form Schema.Tabelle haben."
  H_SCHEMA="${BASH_REMATCH[1]}"; H_TABLE="${BASH_REMATCH[2]}"; H_FQN="[${H_SCHEMA}].[${H_TABLE}]"
fi

# ---------------------------------------------------------------- Dateien sammeln
if [[ ${#FILES[@]} -eq 0 ]]; then
  if [[ ! -d "${RENAME_DIR}" ]]; then
    log_info "Ordner '${RENAME_DIR}' existiert nicht – keine Renaming-Skripte."
    exit 0
  fi
  mapfile -t FILES < <(find "${RENAME_DIR}" -maxdepth 1 -type f \( -iname 'renameColumn_*.sql' -o -iname 'renameTable_*.sql' \) | sort)
fi
for f in "${FILES[@]}"; do [[ -f "${f}" ]] || die "Datei nicht gefunden: ${f}"; done
if [[ ${#FILES[@]} -eq 0 ]]; then
  log_info "Keine Renaming-Skripte gefunden."
  exit 0
fi

# Reihenfolge: Git-Hinzufuegezeitpunkt, dann Name
order_key() {
  local f=$1 ts
  ts="$(git -C "$(dirname "${f}")" log --diff-filter=A --format=%ct -- "$(basename "${f}")" 2>/dev/null | tail -n1 || true)"
  printf '%s\t%s\n' "${ts:-9999999999}" "${f}"
}
mapfile -t FILES < <(for f in "${FILES[@]}"; do order_key "${f}"; done | sort -t$'\t' -k1,1n -k2,2 | cut -f2-)

# ---------------------------------------------------- Datenbanken der Instanz
log_step "Lese Datenbanken von ${DB_SERVER}"
mapfile -t SERVER_DBS < <(run_sqlcmd master -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY LEN(name) DESC, name;" \
                          | tr -d '\r' | sed '/^[[:space:]]*$/d')
log_info "Gefunden: ${SERVER_DBS[*]:-<keine>}"

# resolve_file <datei> -> setzt R_DB, R_KIND, R_OBJ, R_FEATURE, R_NOTE
resolve_file() {
  local f=$1 base rest header db match="" others=()
  base="$(basename "${f}" .sql)"
  R_NOTE=""
  case "${base,,}" in
    renamecolumn_*) R_KIND="Spalte" ;;
    renametable_*)  R_KIND="Tabelle" ;;
    *) R_KIND=""; return 1 ;;
  esac
  rest="${base#*_}"
  header="$(grep -m1 -iE '^--[[:space:]]*(Datenbank|Database)[[:space:]]*:' "${f}" \
            | sed -E 's/^--[[:space:]]*[A-Za-z]+[[:space:]]*:[[:space:]]*//; s/[[:space:]]+$//' | tr -d '\r' || true)"
  if [[ -n "${header}" ]]; then
    match="${header}"
    [[ "${rest,,}" == "${header,,}_"* ]] || R_NOTE="Kopfzeile '${header}' passt nicht zum Dateinamen"
  else
    for db in "${SERVER_DBS[@]}"; do
      if [[ "${rest,,}" == "${db,,}_"* ]]; then
        if [[ -z "${match}" ]]; then match="${db}"; else others+=("${db}"); fi
      fi
    done
    if [[ ${#others[@]} -gt 0 ]]; then
      R_NOTE="mehrdeutig (auch: ${others[*]}) – laengster Treffer gewaehlt; eindeutig per Kopfzeile '-- Datenbank: <Name>'"
    fi
  fi
  R_DB="${match}"
  if [[ -n "${R_DB}" && "${rest,,}" == "${R_DB,,}_"* ]]; then
    local tail="${rest:${#R_DB}+1}"
    R_FEATURE="${tail##*_}"
    R_OBJ="${tail%_*}"
  else
    R_FEATURE="?"; R_OBJ="?"
  fi
  return 0
}

history_done() {   # <db> <skriptname> -> Anzahl erfolgreicher Laeufe
  sqlcmd_scalar "$1" "IF OBJECT_ID(N'${H_FQN}', N'U') IS NULL SELECT 0 ELSE EXEC sp_executesql N'SELECT COUNT(*) FROM ${H_FQN} WHERE ScriptName = @n AND Status = ''SUCCESS''', N'@n NVARCHAR(400)', @n = N'$(sql_lit "$2")';"
}

history_ensure() {
  run_sqlcmd "$1" -Q "SET NOCOUNT ON;
IF SCHEMA_ID(N'${H_SCHEMA}') IS NULL EXEC(N'CREATE SCHEMA [${H_SCHEMA}]');
IF OBJECT_ID(N'${H_FQN}', N'U') IS NULL
CREATE TABLE ${H_FQN} (
  Id           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_${H_TABLE} PRIMARY KEY,
  ScriptName   NVARCHAR(400) NOT NULL,
  ScriptSha256 CHAR(64)      NOT NULL,
  Status       VARCHAR(20)   NOT NULL,
  AppliedAtUtc DATETIME2(0)  NOT NULL CONSTRAINT DF_${H_TABLE}_At DEFAULT SYSUTCDATETIME(),
  AppliedBy    NVARCHAR(256) NOT NULL CONSTRAINT DF_${H_TABLE}_By DEFAULT SUSER_SNAME(),
  ClientHost   NVARCHAR(256) NULL,
  DurationSec  INT           NULL
);" >/dev/null
}

history_insert() { # <db> <name> <sha> <status> <dauer>
  run_sqlcmd "$1" -Q "SET NOCOUNT ON; INSERT INTO ${H_FQN} (ScriptName, ScriptSha256, Status, ClientHost, DurationSec)
VALUES (N'$(sql_lit "$2")', '$3', '$4', N'$(sql_lit "$(hostname 2>/dev/null || echo unknown)")', $5);" >/dev/null \
    || log_warn "Eintrag in ${HISTORY_TABLE} (${1}) fehlgeschlagen."
}

# ---------------------------------------------------------------- Plan erstellen
log_step "Plane ${#FILES[@]} Renaming-Skript(e)"
PLAN_FILES=(); PLAN_DBS=()
CNT_SKIP_DB=0; CNT_SKIP_FILTER=0; CNT_DONE=0
PROTECTED_HIT=()

for f in "${FILES[@]}"; do
  name="$(basename "${f}")"
  if ! resolve_file "${f}"; then
    log_warn "Uebersprungen (Name entspricht nicht der Konvention): ${name}"; continue
  fi
  if [[ -z "${R_DB}" ]]; then
    msg="Keine passende Datenbank auf ${DB_SERVER} fuer: ${name}"
    if [[ "${STRICT}" == "true" ]]; then die "${msg}"; fi
    log_warn "${msg} – uebersprungen"; CNT_SKIP_DB=$((CNT_SKIP_DB + 1)); continue
  fi
  if [[ -n "${R_NOTE}" ]]; then log_warn "${name}: ${R_NOTE}"; fi
  if [[ -n "${DB_FILTER}" && "${R_DB,,}" != "${DB_FILTER,,}" ]]; then CNT_SKIP_FILTER=$((CNT_SKIP_FILTER + 1)); continue; fi
  if [[ -n "${FEATURE_FILTER}" && "${R_FEATURE,,}" != "${FEATURE_FILTER,,}" ]]; then CNT_SKIP_FILTER=$((CNT_SKIP_FILTER + 1)); continue; fi

  # Datenbank (auch per Kopfzeile) muss existieren
  found=false
  for db in "${SERVER_DBS[@]}"; do [[ "${db,,}" == "${R_DB,,}" ]] && { found=true; R_DB="${db}"; break; }; done
  if [[ "${found}" != "true" ]]; then
    msg="Datenbank '${R_DB}' existiert nicht auf ${DB_SERVER}: ${name}"
    if [[ "${STRICT}" == "true" ]]; then die "${msg}"; fi
    log_warn "${msg} – uebersprungen"; CNT_SKIP_DB=$((CNT_SKIP_DB + 1)); continue
  fi

  if [[ -n "${HISTORY_TABLE}" && "${FORCE_RERUN}" != "true" ]]; then
    if [[ "$(history_done "${R_DB}" "${name}")" != "0" ]]; then
      log_info "Bereits ausgefuehrt: [${R_DB}] ${name}"; CNT_DONE=$((CNT_DONE + 1)); continue
    fi
  fi

  log_info "Geplant: [${R_DB}] ${R_KIND} ${R_OBJ} (Feature ${R_FEATURE}) <- ${name}"
  PLAN_FILES+=("${f}"); PLAN_DBS+=("${R_DB}")
  if is_protected_db "${R_DB}"; then PROTECTED_HIT+=("${R_DB}"); fi
done

summary() {
  log_step "Zusammenfassung"
  log_info "Ausgefuehrt:               ${1}"
  log_info "Bereits ausgefuehrt:       ${CNT_DONE}"
  log_info "Datenbank nicht vorhanden: ${CNT_SKIP_DB}"
  log_info "Durch Filter ausgelassen:  ${CNT_SKIP_FILTER}"
}

if [[ ${#PLAN_FILES[@]} -eq 0 ]]; then
  log_info "Nichts auszufuehren."
  summary 0; exit 0
fi
if [[ "${DRY_RUN}" == "true" ]]; then
  log_step "Dry-Run: ${#PLAN_FILES[@]} Skript(e) wuerden ausgefuehrt, es wurde nichts geaendert."
  summary 0; exit 0
fi
if [[ ${#PROTECTED_HIT[@]} -gt 0 && "${ASSUME_YES}" != "true" ]]; then
  confirm "Renaming auf geschuetzten Datenbanken ($(printf '%s\n' "${PROTECTED_HIT[@]}" | sort -u | xargs)) ausfuehren?" || die "Abgebrochen."
fi

# Optional: abgesichert ueber db-backup.sh neu starten (kehrt nur ohne Sicherung zurueck)
mapfile -t _BK_DBS < <(printf '%s\n' "${PLAN_DBS[@]}" | sort -u)
backup_reexec "${_BK_DBS[@]}"

# ---------------------------------------------------------------- Ausfuehren
log_step "Fuehre ${#PLAN_FILES[@]} Renaming-Skript(e) aus"
done_count=0
for i in "${!PLAN_FILES[@]}"; do
  f="${PLAN_FILES[$i]}"; db="${PLAN_DBS[$i]}"; name="$(basename "${f}")"
  log_info "-> [${db}] ${name}"
  [[ -n "${HISTORY_TABLE}" ]] && history_ensure "${db}"
  start_ts=$(date +%s)
  set +e; trap - ERR
  run_sqlcmd "${db}" -I -i "${f}" >&2
  rc=$?
  set -e; trap '_on_error $LINENO' ERR
  dur=$(( $(date +%s) - start_ts ))
  status=$([[ ${rc} -eq 0 ]] && echo SUCCESS || echo FAILED)
  [[ -n "${HISTORY_TABLE}" ]] && history_insert "${db}" "${name}" "$(sha256_of "${f}")" "${status}" "${dur}"
  if [[ ${rc} -ne 0 ]]; then
    summary "${done_count}"
    die "Renaming FEHLGESCHLAGEN: [${db}] ${name} (sqlcmd Exit-Code ${rc}). Nachfolgende Skripte wurden nicht ausgefuehrt."
  fi
  done_count=$((done_count + 1))
done

summary "${done_count}"
