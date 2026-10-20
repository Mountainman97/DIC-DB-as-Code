#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# common.sh – gemeinsame Funktionen fuer das SQL-DACPAC-Toolkit
#
# Wird von allen Skripten unter scripts/ per "source" eingebunden.
# Stellt bereit:
#   * Logging (log_info, log_warn, log_error, die, log_step)
#   * Laden von Env-Dateien (--env-file)
#   * Verbindungsparameter (DB_*) + Aufbau von Connection-Strings
#   * Aufruf von sqlpackage und sqlcmd mit einheitlichen Parametern
# -----------------------------------------------------------------------------

set -Eeuo pipefail

TOOLKIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_ROOT="$(cd "${TOOLKIT_LIB_DIR}/../.." && pwd)"
TOOLKIT_SCRIPT_NAME="$(basename "${BASH_SOURCE[-1]}")"

# --------------------------------------------------------------------------- #
# Logging                                                                     #
# --------------------------------------------------------------------------- #
# Alle Log-Ausgaben gehen nach STDERR, damit STDOUT fuer Rueckgabewerte
# (z.B. Pfad eines erzeugten DACPACs / Diff-Skripts) frei bleibt.

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_BLU=$'\033[34m'; _C_BOLD=$'\033[1m'
else
  _C_RESET=""; _C_RED=""; _C_YEL=""; _C_BLU=""; _C_BOLD=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%s [INFO ] %s\n' "$(_ts)" "$*" >&2; }
log_warn()  { printf '%s %s[WARN ]%s %s\n' "$(_ts)" "${_C_YEL}" "${_C_RESET}" "$*" >&2; }
log_error() { printf '%s %s[ERROR]%s %s\n' "$(_ts)" "${_C_RED}" "${_C_RESET}" "$*" >&2; }
log_step()  { printf '\n%s %s==> %s%s\n' "$(_ts)" "${_C_BOLD}${_C_BLU}" "$*" "${_C_RESET}" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf '%s [DEBUG] %s\n' "$(_ts)" "$*" >&2; return 0; }

die() {
  log_error "$*"
  exit 1
}

_on_error() {
  local exit_code=$? line=$1
  log_error "${TOOLKIT_SCRIPT_NAME}: Abbruch in Zeile ${line} (Exit-Code ${exit_code})."
  exit "${exit_code}"
}
trap '_on_error $LINENO' ERR

# --------------------------------------------------------------------------- #
# Hilfsfunktionen                                                             #
# --------------------------------------------------------------------------- #

require_cmd() {
  local cmd=$1 hint=${2:-}
  command -v "${cmd}" >/dev/null 2>&1 || die "Benoetigtes Programm '${cmd}' nicht gefunden. ${hint}"
}

# Wert eines Boolean-artigen Strings normalisieren -> "true" / "false"
to_bool() {
  case "${1,,}" in
    1|true|yes|y|ja|j|on) echo "true" ;;
    0|false|no|n|nein|off|"") echo "false" ;;
    *) die "Ungueltiger Boolean-Wert: '$1'" ;;
  esac
}

# Absoluten Pfad bilden (Datei/Ordner muss nicht existieren)
abs_path() {
  local p=$1
  if [[ "${p}" = /* ]]; then echo "${p}"; else echo "${PWD}/${p#./}"; fi
}

# Dateinamen-tauglichen String erzeugen
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

utc_stamp() { date -u '+%Y%m%dT%H%M%SZ'; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# Nachfrage (nur interaktiv). Gibt 0 bei "ja" zurueck.
confirm() {
  local prompt=$1 answer
  if [[ ! -t 0 ]]; then
    die "Bestaetigung erforderlich ('${prompt}'), aber keine interaktive Konsole. Mit --yes ausfuehren."
  fi
  read -r -p "${prompt} [j/N] " answer
  [[ "${answer,,}" == "j" || "${answer,,}" == "ja" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# --------------------------------------------------------------------------- #
# Env-Datei laden                                                             #
# --------------------------------------------------------------------------- #
# Sucht in den Argumenten nach "--env-file <datei>" bzw. "--env-file=<datei>"
# und laedt die Datei VOR dem eigentlichen Argument-Parsing. Dadurch gilt:
#   Kommandozeile  >  Env-Datei  >  bereits gesetzte Umgebungsvariablen
preload_env_file() {
  local prev="" arg file=""
  for arg in "$@"; do
    if [[ "${prev}" == "--env-file" ]]; then file="${arg}"; fi
    if [[ "${arg}" == --env-file=* ]]; then file="${arg#--env-file=}"; fi
    prev="${arg}"
  done
  if [[ -n "${file}" ]]; then
    [[ -f "${file}" ]] || die "Env-Datei nicht gefunden: ${file}"
    log_info "Lade Konfiguration aus ${file}"
    set -a
    # shellcheck disable=SC1090
    source "${file}"
    set +a
  fi
}

# --------------------------------------------------------------------------- #
# Verbindungsparameter                                                        #
# --------------------------------------------------------------------------- #
# Folgende Variablen werden ausgewertet (Env-Datei, Umgebung oder CLI):
#   DB_SERVER            Hostname[,Port] bzw. Host\Instanz          (Pflicht)
#   DB_NAME              Datenbankname                              (je Skript)
#   DB_AUTH              sql | integrated                           (Default: sql)
#   DB_USER              SQL-Login (bei DB_AUTH=sql)
#   DB_PASSWORD          Passwort  (bei DB_AUTH=sql) – NIE ins Repo einchecken
#   DB_PASSWORD_FILE     Alternativ: Datei, die das Passwort enthaelt
#   DB_ENCRYPT           true | false                               (Default: true)
#   DB_TRUST_SERVER_CERT true | false                               (Default: false)
#   DB_CONNECT_TIMEOUT   Sekunden                                   (Default: 30)
#   DB_CONNECTION_STRING Optional: kompletter Connection-String fuer sqlpackage
#                        (ueberschreibt alle obigen Einzelwerte fuer sqlpackage)
#   SQLPACKAGE_BIN       Pfad zu sqlpackage (Default: Suche im PATH)
#   SQLCMD_BIN           Pfad zu sqlcmd     (Default: Suche im PATH)
#   SQLPACKAGE_EXTRA_ARGS  zusaetzliche Argumente fuer jeden sqlpackage-Aufruf
#   SQLCMD_EXTRA_ARGS      zusaetzliche Argumente fuer jeden sqlcmd-Aufruf

: "${DB_AUTH:=sql}"
: "${DB_ENCRYPT:=true}"
: "${DB_TRUST_SERVER_CERT:=false}"
: "${DB_CONNECT_TIMEOUT:=30}"

# Gemeinsame Verbindungs-Optionen parsen. Gibt die Anzahl verbrauchter
# Argumente ueber die globale Variable _CONSUMED zurueck (0 = nicht erkannt).
_CONSUMED=0
# shellcheck disable=SC2034  # Variablen werden von den aufrufenden Skripten genutzt
parse_connection_opt() {
  _CONSUMED=0
  local opt=$1 val=${2-}
  _need_val() { [[ -n "${val}" && "${val}" != --* ]] || die "Option ${opt} erwartet einen Wert."; }
  case "${opt}" in
    --env-file)          _need_val; _CONSUMED=2 ;;   # bereits durch preload_env_file geladen
    --env-file=*)        _CONSUMED=1 ;;
    -S|--server)         _need_val; DB_SERVER=${val};  _CONSUMED=2 ;;
    -d|--database)       _need_val; DB_NAME=${val};    _CONSUMED=2 ;;
    -U|--user)           _need_val; DB_USER=${val};    _CONSUMED=2 ;;
    --password-file)     _need_val; DB_PASSWORD_FILE=${val}; _CONSUMED=2 ;;
    --auth)              _need_val; DB_AUTH=${val};    _CONSUMED=2 ;;
    --trust-server-cert) DB_TRUST_SERVER_CERT=true;    _CONSUMED=1 ;;
    --no-encrypt)        DB_ENCRYPT=false;             _CONSUMED=1 ;;
    --connect-timeout)   _need_val; DB_CONNECT_TIMEOUT=${val}; _CONSUMED=2 ;;
    --connection-string) _need_val; DB_CONNECTION_STRING=${val}; _CONSUMED=2 ;;
  esac
  return 0
}

connection_help() {
  cat <<'EOF'
Verbindungsoptionen (alternativ per Env-Datei / Umgebungsvariablen DB_*):
  --env-file DATEI         Env-Datei mit DB_*-Variablen laden
  -S, --server HOST        SQL Server (Host[,Port] oder Host\Instanz)   [DB_SERVER]
  -d, --database NAME      Datenbankname                                [DB_NAME]
  --auth sql|integrated    Authentifizierung (integrated = Kerberos)    [DB_AUTH]
  -U, --user LOGIN         SQL-Login                                    [DB_USER]
  --password-file DATEI    Datei mit Passwort (sonst: DB_PASSWORD)      [DB_PASSWORD_FILE]
  --trust-server-cert      Serverzertifikat nicht validieren            [DB_TRUST_SERVER_CERT]
  --no-encrypt             Verbindung nicht verschluesseln              [DB_ENCRYPT=false]
  --connect-timeout SEK    Verbindungs-Timeout (Default 30)             [DB_CONNECT_TIMEOUT]
  --connection-string CS   Vollstaendiger Connection-String (nur sqlpackage)
EOF
}

validate_connection() {
  DB_AUTH="${DB_AUTH,,}"
  DB_ENCRYPT="$(to_bool "${DB_ENCRYPT}")"
  DB_TRUST_SERVER_CERT="$(to_bool "${DB_TRUST_SERVER_CERT}")"
  if [[ -n "${DB_CONNECTION_STRING:-}" && -z "${DB_SERVER:-}" ]]; then
    return 0   # nur sqlpackage-Nutzung mit fertigem Connection-String
  fi
  [[ -n "${DB_SERVER:-}" ]] || die "Kein Server angegeben (--server oder DB_SERVER)."
  case "${DB_AUTH}" in
    sql)
      [[ -n "${DB_USER:-}" ]] || die "DB_AUTH=sql benoetigt einen Benutzer (--user oder DB_USER)."
      if [[ -z "${DB_PASSWORD:-}" && -n "${DB_PASSWORD_FILE:-}" ]]; then
        [[ -r "${DB_PASSWORD_FILE}" ]] || die "Passwort-Datei nicht lesbar: ${DB_PASSWORD_FILE}"
        DB_PASSWORD="$(head -n1 "${DB_PASSWORD_FILE}" | tr -d '\r\n')"
      fi
      [[ -n "${DB_PASSWORD:-}" ]] || die "Kein Passwort gesetzt (DB_PASSWORD oder --password-file)."
      ;;
    integrated) : ;;
    *) die "Unbekannte Authentifizierung '${DB_AUTH}' (erlaubt: sql, integrated)." ;;
  esac
}

# Wert fuer einen ADO.NET-Connection-String quoten, falls noetig
_cs_quote() {
  local v=$1
  if [[ "${v}" =~ [\;\'\"] || "${v}" =~ ^[[:space:]] || "${v}" =~ [[:space:]]$ ]]; then
    v="${v//\"/\"\"}"
    printf '"%s"' "${v}"
  else
    printf '%s' "${v}"
  fi
}

# build_connection_string <datenbank>
build_connection_string() {
  local db=$1
  if [[ -n "${DB_CONNECTION_STRING:-}" ]]; then
    # Datenbank im vorgegebenen Connection-String ersetzen/ergaenzen
    local cs="${DB_CONNECTION_STRING%;}"
    cs="$(printf '%s' "${cs}" | sed -E 's/(^|;)[[:space:]]*(Initial Catalog|Database)[[:space:]]*=[^;]*//Ig; s/^;//')"
    printf '%s;Initial Catalog=%s' "${cs}" "$(_cs_quote "${db}")"
    return 0
  fi
  local cs
  cs="Data Source=$(_cs_quote "${DB_SERVER}");Initial Catalog=$(_cs_quote "${db}")"
  if [[ "${DB_AUTH}" == "integrated" ]]; then
    cs+=";Integrated Security=True"
  else
    cs+=";User ID=$(_cs_quote "${DB_USER}");Password=$(_cs_quote "${DB_PASSWORD}")"
  fi
  if [[ "${DB_ENCRYPT}" == "true" ]]; then cs+=";Encrypt=True"; else cs+=";Encrypt=False"; fi
  if [[ "${DB_TRUST_SERVER_CERT}" == "true" ]]; then cs+=";Trust Server Certificate=True"; fi
  cs+=";Connect Timeout=${DB_CONNECT_TIMEOUT}"
  printf '%s' "${cs}"
}

# Connection-String fuer Logausgaben ohne Passwort
mask_cs() { printf '%s' "$1" | sed -E 's/(Password|Pwd)=("([^"]|"")*"|[^;]*)/\1=*****/Ig'; }

# --------------------------------------------------------------------------- #
# Werkzeuge finden                                                            #
# --------------------------------------------------------------------------- #

resolve_sqlpackage() {
  if [[ -n "${SQLPACKAGE_BIN:-}" ]]; then
    [[ -x "${SQLPACKAGE_BIN}" ]] || die "SQLPACKAGE_BIN ist nicht ausfuehrbar: ${SQLPACKAGE_BIN}"
    return 0
  fi
  local c
  for c in "$(command -v sqlpackage 2>/dev/null || true)" \
           "${HOME}/.dotnet/tools/sqlpackage" \
           "/opt/sqlpackage/sqlpackage" \
           "${HOME}/sqlpackage/sqlpackage"; do
    if [[ -n "${c}" && -x "${c}" ]]; then SQLPACKAGE_BIN="${c}"; return 0; fi
  done
  die "sqlpackage nicht gefunden. Siehe docs/01-installation.md oder SQLPACKAGE_BIN setzen."
}

resolve_sqlcmd() {
  if [[ -n "${SQLCMD_BIN:-}" ]]; then
    [[ -x "${SQLCMD_BIN}" ]] || die "SQLCMD_BIN ist nicht ausfuehrbar: ${SQLCMD_BIN}"
    return 0
  fi
  local c
  for c in "$(command -v sqlcmd 2>/dev/null || true)" \
           "/opt/mssql-tools18/bin/sqlcmd" \
           "/opt/mssql-tools/bin/sqlcmd"; do
    if [[ -n "${c}" && -x "${c}" ]]; then SQLCMD_BIN="${c}"; return 0; fi
  done
  die "sqlcmd nicht gefunden. Siehe docs/01-installation.md oder SQLCMD_BIN setzen."
}

# --------------------------------------------------------------------------- #
# sqlpackage-Aufruf                                                           #
# --------------------------------------------------------------------------- #
# run_sqlpackage <args...>
# Passwoerter werden in der Log-Ausgabe maskiert.
run_sqlpackage() {
  resolve_sqlpackage
  local -a args=("$@")
  if [[ -n "${SQLPACKAGE_EXTRA_ARGS:-}" ]]; then
    local -a extra
    read -r -a extra <<<"${SQLPACKAGE_EXTRA_ARGS}"
    args+=("${extra[@]}")
  fi
  local shown=""
  local a
  for a in "${args[@]}"; do shown+=" $(mask_cs "${a}")"; done
  log_info "sqlpackage${shown}"
  "${SQLPACKAGE_BIN}" "${args[@]}" >&2
}

sqlpackage_version() {
  resolve_sqlpackage
  "${SQLPACKAGE_BIN}" /Version 2>/dev/null | tr -d '\r' | tail -n1 || echo "unbekannt"
}

# --------------------------------------------------------------------------- #
# sqlcmd-Aufruf                                                               #
# --------------------------------------------------------------------------- #
# run_sqlcmd <datenbank> <weitere sqlcmd-Argumente...>
# Kompatibel mit mssql-tools18 (ODBC) und go-sqlcmd.
run_sqlcmd() {
  resolve_sqlcmd
  local db=$1; shift
  [[ -n "${DB_SERVER:-}" ]] || die "sqlcmd benoetigt DB_SERVER (ein reiner Connection-String reicht hier nicht)."
  local -a args=(-S "${DB_SERVER}" -d "${db}" -b -l "${DB_CONNECT_TIMEOUT}")
  if [[ "${DB_AUTH}" == "integrated" ]]; then
    args+=(-E)
  else
    args+=(-U "${DB_USER}")
  fi
  if [[ "${DB_ENCRYPT}" == "true" ]]; then args+=(-Nm); else args+=(-No); fi
  if [[ "${DB_TRUST_SERVER_CERT}" == "true" ]]; then args+=(-C); fi
  if [[ -n "${SQLCMD_EXTRA_ARGS:-}" ]]; then
    local -a extra
    read -r -a extra <<<"${SQLCMD_EXTRA_ARGS}"
    args+=("${extra[@]}")
  fi
  log_debug "sqlcmd ${args[*]} $*"
  # Passwort ueber Umgebungsvariable statt Kommandozeile uebergeben
  SQLCMDPASSWORD="${DB_PASSWORD:-}" "${SQLCMD_BIN}" "${args[@]}" "$@"
}

# Einzelnen skalaren Wert abfragen (ohne Header, getrimmt)
sqlcmd_scalar() {
  local db=$1 query=$2
  run_sqlcmd "${db}" -h -1 -W -Q "SET NOCOUNT ON; ${query}" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -n1
}

# SQL-String-Literal escapen (einfache Hochkommas verdoppeln)
sql_lit() { printf '%s' "${1//\'/\'\'}"; }

database_exists() {
  local db=$1 cnt
  cnt="$(sqlcmd_scalar master "SELECT COUNT(*) FROM sys.databases WHERE name = N'$(sql_lit "${db}")';")"
  [[ "${cnt}" == "1" ]]
}

# --------------------------------------------------------------------------- #
# Schutz produktiver Datenbanken                                              #
# --------------------------------------------------------------------------- #
# PROTECTED_DATABASES: kommagetrennte Liste von Datenbanknamen (Glob-Muster
# erlaubt, z.B. "DIZ_NET,DIZ_NET_stage,*_PROD"), auf die destruktive
# Aktionen nur mit --allow-protected ausgefuehrt werden duerfen.
is_protected_db() {
  local db=$1 pattern
  local -a list
  IFS=',' read -r -a list <<<"${PROTECTED_DATABASES:-}"
  for pattern in "${list[@]}"; do
    pattern="$(printf '%s' "${pattern}" | xargs)"
    [[ -z "${pattern}" ]] && continue
    # shellcheck disable=SC2053
    if [[ "${db,,}" == ${pattern,,} ]]; then return 0; fi
  done
  return 1
}

# --------------------------------------------------------------------------- #
# DACPAC aus Projekt bauen (gemeinsam genutzt von provision/diff)             #
# --------------------------------------------------------------------------- #
# build_dacpac_from_project <projekt (Ordner oder .sqlproj)> <ziel.dacpac>
build_dacpac_from_project() {
  "${TOOLKIT_ROOT}/scripts/db-build.sh" --project "$1" --output "$2" >/dev/null
}

# SqlCmd-Variablen (--var NAME=WERT) in sqlpackage-Argumente uebersetzen
# Nutzung: sqlcmd_vars_to_sqlpackage_args <array-name-der-vars> <array-name-ziel>
vars_to_sqlpackage() {
  local -n _src=$1 _dst=$2
  local kv
  for kv in "${_src[@]}"; do
    [[ "${kv}" == *=* ]] || die "Ungueltige Variable '${kv}' (erwartet NAME=WERT)."
    _dst+=("/v:${kv}")
  done
}
