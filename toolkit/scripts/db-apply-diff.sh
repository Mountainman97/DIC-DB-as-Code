#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-apply-diff.sh – Fuehrt ein (mit db-diff.sh erzeugtes) Diff-Skript auf
#                    einer Ziel-Datenbank aus
#
# Sicherheitspruefungen vor der Ausfuehrung:
#   * Ziel-DB im Skript (:setvar DatabaseName) muss zu --database passen
#   * Ziel aus der .meta-Datei (falls vorhanden) muss passen
#   * Pruefsumme laut .meta vs. aktuelle Datei (Warnung bei Abweichung)
#   * Rueckfrage bei geschuetzten Datenbanken (PROTECTED_DATABASES)
#   * Optional: Historientabelle verhindert doppelte Ausfuehrung
#
# Ausfuehrung via sqlcmd (SQLCMD-Modus, Abbruch beim ersten Fehler),
# vollstaendiges Protokoll in einer .log-Datei.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") --database NAME --script DATEI.sql [Optionen]

Optionen:
  -i, --script DATEI        Auszufuehrendes Diff-Skript                     (Pflicht)
  --var NAME=WERT           Zusaetzliche SqlCmd-Variable (mehrfach)
  --history-table S.T       Ausfuehrungen in Tabelle S.T der Ziel-DB protokollieren
                            und bereits erfolgreich ausgefuehrte Skripte (gleicher
                            SHA256) ueberspringen. Default: \$DEPLOY_HISTORY_TABLE
  --force-rerun             Trotz Eintrag in der Historie erneut ausfuehren
  --query-timeout SEK       Timeout je Batch (Default: 0 = unbegrenzt)
  --log-file DATEI          Protokolldatei (Default: <skript>.<zeitstempel>.log)
  --ignore-target-mismatch  Abweichende Ziel-DB/Server in Skript/.meta ignorieren
  --backup MODE             Vorher sichern, bei Fehler wiederherstellen, bei Erfolg
                            Sicherung loeschen: none|backup|snapshot [BACKUP_MODE]
  --dry-run                 Nur pruefen, nichts ausfuehren
  --yes                     Keine Rueckfragen
  -h, --help                Diese Hilfe

$(connection_help)

Beispiel:
  $(basename "$0") --env-file config/test.env -d DIZ_NET \\
      --script artifacts/diff/DIZ_NET_20261016T101500Z.sql \\
      --history-table dbo.__SchemaDeployHistory
EOF
}

ORIG_ARGS=("$@")
preload_env_file "$@"

SCRIPT=""
VARS=()
HISTORY_TABLE="${DEPLOY_HISTORY_TABLE:-}"
FORCE_RERUN=false
QUERY_TIMEOUT=0
LOG_FILE=""
IGNORE_MISMATCH=false
DRY_RUN=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    -i|--script)              SCRIPT=${2:?}; shift 2 ;;
    --var)                    VARS+=("${2:?}"); shift 2 ;;
    --history-table)          HISTORY_TABLE=${2:?}; shift 2 ;;
    --force-rerun)            FORCE_RERUN=true; shift ;;
    --query-timeout)          QUERY_TIMEOUT=${2:?}; shift 2 ;;
    --log-file)               LOG_FILE=${2:?}; shift 2 ;;
    --ignore-target-mismatch) IGNORE_MISMATCH=true; shift ;;
    --dry-run)                DRY_RUN=true; shift ;;
    --backup)                 BACKUP_MODE=${2:?}; shift 2 ;;
    --yes|-y)                 ASSUME_YES=true; shift ;;
    -h|--help)                usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

# ------------------------------------------------------------------ Validierung
[[ -n "${SCRIPT}" ]]    || { usage >&2; die "--script fehlt."; }
[[ -f "${SCRIPT}" ]]    || die "Skript nicht gefunden: ${SCRIPT}"
[[ -n "${DB_NAME:-}" ]] || { usage >&2; die "Keine Ziel-Datenbank angegeben (--database oder DB_NAME)."; }
validate_connection
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (sqlcmd)."
[[ "${QUERY_TIMEOUT}" =~ ^[0-9]+$ ]] || die "--query-timeout muss eine Zahl sein."
validate_backup_mode

SCRIPT="$(abs_path "${SCRIPT}")"
SCRIPT_SHA="$(sha256_of "${SCRIPT}")"
SCRIPT_NAME="$(basename "${SCRIPT}")"
META_FILE="${SCRIPT%.sql}.meta"
: "${LOG_FILE:=${SCRIPT%.sql}.$(utc_stamp).log}"

mismatch() {
  if [[ "${IGNORE_MISMATCH}" == "true" ]]; then log_warn "$* (ignoriert)"; else die "$* – Abbruch (--ignore-target-mismatch zum Uebergehen)."; fi
}

log_step "1/4 Pruefe Skript ${SCRIPT_NAME}"
log_info "Ziel   : ${DB_SERVER} / ${DB_NAME}"
log_info "SHA256 : ${SCRIPT_SHA}"

# a) :setvar DatabaseName im Skript (nicht auskommentiert)
#    sqlpackage kommentiert bei CommentOutSetVarDeclarations=True den
#    :setvar-Block mit /* ... */ aus – Zeilen in Blockkommentaren zaehlen nicht.
SCRIPT_DB="$(tr -d '\r' < "${SCRIPT}" | awk '
  incomment { if (index($0, "*/")) incomment = 0; next }
  /^[[:space:]]*\/\*/ { if (!index(substr($0, index($0, "/*") + 2), "*/")) incomment = 1; next }
  /^:setvar[[:space:]]+DatabaseName[[:space:]]/ {
    v = $0; sub(/^:setvar[[:space:]]+DatabaseName[[:space:]]+/, "", v); gsub(/"/, "", v); sub(/[[:space:]]+$/, "", v)
    print v; exit
  }')"
PORTABLE=false
if [[ -n "${SCRIPT_DB}" ]]; then
  if [[ "${SCRIPT_DB}" != "${DB_NAME}" ]]; then
    mismatch "Skript ist fuer Datenbank '${SCRIPT_DB}' erzeugt, Ziel ist '${DB_NAME}'. Hinweis: sqlcmd verwendet den Wert aus dem Skript"
  fi
else
  PORTABLE=true
  log_info "Skript ohne aktive :setvar-Deklarationen (portabel) – Variablen werden uebergeben."
fi

# b) .meta-Datei
if [[ -f "${META_FILE}" ]]; then
  meta() { grep -E "^$1=" "${META_FILE}" | head -n1 | cut -d= -f2- || true; }
  m_db="$(meta target_database)"; m_srv="$(meta target_server)"; m_sha="$(meta script_sha256)"; m_ops="$(meta operations)"
  if [[ -n "${m_db}" && "${m_db,,}" != "${DB_NAME,,}" ]]; then
    mismatch "Diff wurde gegen Datenbank '${m_db}' erzeugt (Ziel: '${DB_NAME}')"
  fi
  if [[ -n "${m_srv}" && "${m_srv}" != "<connection-string>" && "${m_srv,,}" != "${DB_SERVER,,}" ]]; then
    mismatch "Diff wurde gegen Server '${m_srv}' erzeugt (Ziel: '${DB_SERVER}')"
  fi
  if [[ -n "${m_sha}" && "${m_sha}" != "${SCRIPT_SHA}" ]]; then
    log_warn "Skript wurde seit der Erzeugung veraendert (SHA256 weicht von .meta ab)."
  fi
  if [[ "${m_ops}" == "0" ]]; then
    log_info "Laut .meta enthaelt das Skript keine Objekt-Aenderungen."
  fi
else
  log_info "Keine .meta-Datei gefunden – Ziel-Abgleich nur ueber :setvar."
fi

# c) Historientabelle
if [[ -n "${HISTORY_TABLE}" ]]; then
  [[ "${HISTORY_TABLE}" =~ ^([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$ ]] \
    || die "--history-table muss die Form Schema.Tabelle haben (nur Buchstaben, Ziffern, _)."
  H_SCHEMA="${BASH_REMATCH[1]}"; H_TABLE="${BASH_REMATCH[2]}"
  H_FQN="[${H_SCHEMA}].[${H_TABLE}]"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  log_step "Dry-Run: Pruefungen bestanden, es wurde nichts ausgefuehrt."
  exit 0
fi

# ------------------------------------------------------- 2) Verbindung/Historie
log_step "2/4 Pruefe Verbindung und Historie"
database_exists "${DB_NAME}" || mismatch "Datenbank '${DB_NAME}' existiert auf '${DB_SERVER}' nicht"

if [[ -n "${HISTORY_TABLE}" ]]; then
  run_sqlcmd "${DB_NAME}" -Q "SET NOCOUNT ON;
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
  done_count="$(sqlcmd_scalar "${DB_NAME}" "SELECT COUNT(*) FROM ${H_FQN} WHERE ScriptSha256 = '${SCRIPT_SHA}' AND Status = 'SUCCESS';")"
  if [[ "${done_count}" != "0" ]]; then
    if [[ "${FORCE_RERUN}" == "true" ]]; then
      log_warn "Skript wurde bereits ${done_count}x erfolgreich ausgefuehrt – erneute Ausfuehrung (--force-rerun)."
    else
      log_info "Skript wurde bereits erfolgreich ausgefuehrt (laut ${HISTORY_TABLE}) – nichts zu tun."
      exit 0
    fi
  fi
fi

if is_protected_db "${DB_NAME}" && [[ "${ASSUME_YES}" != "true" ]]; then
  confirm "'${DB_NAME}' ist eine geschuetzte Datenbank. Skript '${SCRIPT_NAME}' jetzt ausfuehren?" || die "Abgebrochen."
fi

# Optional: abgesichert ueber db-backup.sh neu starten (kehrt nur ohne Sicherung zurueck)
backup_reexec "${DB_NAME}"

# ------------------------------------------------------------- 3) Ausfuehren
log_step "3/4 Fuehre ${SCRIPT_NAME} aus (Protokoll: ${LOG_FILE})"
SQLCMD_VARS=(-v "DatabaseName=${DB_NAME}")
if [[ "${PORTABLE}" == "true" ]]; then
  data_path="$(sqlcmd_scalar master "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400));")"
  log_path="$(sqlcmd_scalar master "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(400));")"
  SQLCMD_VARS+=(-v "DefaultFilePrefix=${DB_NAME}" -v "DefaultDataPath=${data_path}" -v "DefaultLogPath=${log_path}")
fi
for kv in "${VARS[@]}"; do
  [[ "${kv}" == *=* ]] || die "Ungueltige Variable '${kv}' (erwartet NAME=WERT)."
  SQLCMD_VARS+=(-v "${kv}")
done

mkdir -p "$(dirname "${LOG_FILE}")"
start_ts=$(date +%s)
set +e
trap - ERR
# Verbindung auf master: das Skript wechselt selbst per USE [$(DatabaseName)]
run_sqlcmd master -I -t "${QUERY_TIMEOUT}" "${SQLCMD_VARS[@]}" -i "${SCRIPT}" 2>&1 | tee "${LOG_FILE}" >&2
rc=${PIPESTATUS[0]}
set -e
trap '_on_error $LINENO' ERR
duration=$(( $(date +%s) - start_ts ))

# ------------------------------------------------------------- 4) Historie
STATUS=$([[ ${rc} -eq 0 ]] && echo SUCCESS || echo FAILED)
if [[ -n "${HISTORY_TABLE}" ]]; then
  log_step "4/4 Protokolliere Ergebnis in ${HISTORY_TABLE}"
  run_sqlcmd "${DB_NAME}" -Q "SET NOCOUNT ON; INSERT INTO ${H_FQN} (ScriptName, ScriptSha256, Status, ClientHost, DurationSec)
VALUES (N'$(sql_lit "${SCRIPT_NAME}")', '${SCRIPT_SHA}', '${STATUS}', N'$(sql_lit "$(hostname 2>/dev/null || echo unknown)")', ${duration});" >/dev/null \
    || log_warn "Eintrag in die Historientabelle fehlgeschlagen."
else
  log_step "4/4 Keine Historientabelle konfiguriert"
fi

if [[ ${rc} -ne 0 ]]; then
  die "Ausfuehrung FEHLGESCHLAGEN (sqlcmd Exit-Code ${rc}) nach ${duration}s. Details: ${LOG_FILE}"
fi
log_step "Fertig: ${SCRIPT_NAME} erfolgreich auf ${DB_SERVER} / ${DB_NAME} ausgefuehrt (${duration}s)."
