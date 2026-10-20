#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-diff.sh – Vergleicht den Stand einer Ziel-Datenbank mit dem
#              Dateiverzeichnis (SQL-Projekt) und erzeugt ein Diff-Skript
#
# Ablauf:
#   1. SQL-Projekt -> DACPAC bauen (oder fertiges DACPAC verwenden)
#   2. sqlpackage /Action:DeployReport  -> XML-Bericht der Aenderungen
#   3. sqlpackage /Action:Script        -> ausfuehrbares SQLCMD-Diff-Skript
#   4. Metadaten-Datei (.meta) mit Ziel, Quelle, Git-Commit, SHA256
#
# Das Diff-Skript ist ein SQLCMD-Skript und wird mit db-apply-diff.sh
# (oder sqlcmd) ausgefuehrt. Es ist spezifisch fuer den Zustand der
# Ziel-Datenbank zum Zeitpunkt der Erzeugung!
#
# Ausgabe auf STDOUT: Pfad des Diff-Skripts (leer, falls keine Aenderungen
# und --skip-empty gesetzt ist).
#
# Exit-Codes: 0 = OK, 1 = Fehler, 3 = Aenderungen gefunden (nur mit --fail-on-changes)
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") --database NAME (--project PFAD | --dacpac DATEI) [Optionen]

Erzeugt ein Diff-Skript, das die Ziel-Datenbank auf den Stand des
Dateiverzeichnisses bringt.

Quelle (eines von beiden):
  --project PFAD            SQL-Projekt (Ordner/.sqlproj), wird gebaut
  --dacpac DATEI            Fertiges DACPAC

Optionen:
  --output-dir ORDNER       Ablageort fuer Skript/Report (Default: ./artifacts/diff)
                            ACHTUNG: nicht innerhalb des SQL-Projektordners ablegen,
                            sonst werden die Skripte beim Build mitkompiliert.
  --name NAME               Dateiname ohne Endung
                            (Default: <DB>_<UTC-Zeitstempel>)
  --profile DATEI           Publish-Profil (.publish.xml)
  --var NAME=WERT           SqlCmd-Variable (mehrfach)
  --property NAME=WERT      Zusaetzliche Eigenschaft (/p:NAME=WERT), mehrfach
  --drop-objects-not-in-source
                            Objekte loeschen, die nur in der DB existieren
  --portable                :setvar-Deklarationen auskommentieren
                            (DatabaseName etc. werden beim Ausfuehren gesetzt)
  --no-report               Keinen DeployReport erzeugen
  --skip-empty              Bei 0 Aenderungen keine Dateien behalten
  --fail-on-changes         Exit-Code 3, falls Aenderungen gefunden (Drift-Check)
  -h, --help                Diese Hilfe

$(connection_help)

Beispiel:
  $(basename "$0") --env-file config/test.env -d DIZ_NET --project database/DIZ_NET \\
      --profile config/default.publish.xml --output-dir artifacts/diff
EOF
}

preload_env_file "$@"

DACPAC=""
PROJECT=""
OUTPUT_DIR="artifacts/diff"
NAME=""
PROFILE="${PUBLISH_PROFILE:-}"
VARS=()
EXTRA_PROPS=()
DROP_NOT_IN_SOURCE=false
PORTABLE=false
WITH_REPORT=true
SKIP_EMPTY=false
FAIL_ON_CHANGES=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    --dacpac)          DACPAC=${2:?}; shift 2 ;;
    --project)         PROJECT=${2:?}; shift 2 ;;
    --output-dir)      OUTPUT_DIR=${2:?}; shift 2 ;;
    --name)            NAME=${2:?}; shift 2 ;;
    --profile)         PROFILE=${2:?}; shift 2 ;;
    --var)             VARS+=("${2:?}"); shift 2 ;;
    --property)        EXTRA_PROPS+=("${2:?}"); shift 2 ;;
    --drop-objects-not-in-source) DROP_NOT_IN_SOURCE=true; shift ;;
    --portable)        PORTABLE=true; shift ;;
    --no-report)       WITH_REPORT=false; shift ;;
    --skip-empty)      SKIP_EMPTY=true; shift ;;
    --fail-on-changes) FAIL_ON_CHANGES=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

# ------------------------------------------------------------------ Validierung
[[ -n "${DB_NAME:-}" ]] || { usage >&2; die "Keine Ziel-Datenbank angegeben (--database oder DB_NAME)."; }
if [[ -n "${DACPAC}" && -n "${PROJECT}" ]] || [[ -z "${DACPAC}" && -z "${PROJECT}" ]]; then
  usage >&2; die "Genau eine Quelle angeben: --project ODER --dacpac."
fi
[[ -z "${PROFILE}" || -f "${PROFILE}" ]] || die "Publish-Profil nicht gefunden: ${PROFILE}"
validate_connection

OUTPUT_DIR="$(abs_path "${OUTPUT_DIR}")"
if [[ -n "${PROJECT}" ]]; then
  proj_dir="$(abs_path "${PROJECT}")"; [[ -f "${proj_dir}" ]] && proj_dir="$(dirname "${proj_dir}")"
  case "${OUTPUT_DIR}/" in
    "${proj_dir%/}/"*) die "--output-dir liegt im Projektordner (${proj_dir}). Bitte einen Ordner ausserhalb waehlen." ;;
  esac
fi
mkdir -p "${OUTPUT_DIR}"
: "${NAME:=$(sanitize "${DB_NAME}")_$(utc_stamp)}"
SCRIPT_FILE="${OUTPUT_DIR}/${NAME}.sql"
REPORT_FILE="${OUTPUT_DIR}/${NAME}.deployreport.xml"
META_FILE="${OUTPUT_DIR}/${NAME}.meta"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# ------------------------------------------------------------ 1) Quelle bereit
if [[ -n "${PROJECT}" ]]; then
  log_step "1/4 Baue DACPAC aus Projekt ${PROJECT}"
  DACPAC="${WORK_DIR}/source.dacpac"
  build_dacpac_from_project "${PROJECT}" "${DACPAC}"
else
  log_step "1/4 Verwende DACPAC ${DACPAC}"
  [[ -f "${DACPAC}" ]] || die "DACPAC nicht gefunden: ${DACPAC}"
fi

CS="$(build_connection_string "${DB_NAME}")"
# Hinweis: Die Ziel-DB steht im Connection-String (Initial Catalog); /TargetDatabaseName
# darf zusammen mit /TargetConnectionString nicht verwendet werden.
BASE_ARGS=(/SourceFile:"${DACPAC}" /TargetConnectionString:"${CS}")
[[ -n "${PROFILE}" ]] && BASE_ARGS+=(/Profile:"${PROFILE}")
vars_to_sqlpackage VARS BASE_ARGS
PROPS=()
[[ "${DROP_NOT_IN_SOURCE}" == "true" ]] && PROPS+=("/p:DropObjectsNotInSource=True")
for p in "${EXTRA_PROPS[@]}"; do PROPS+=("/p:${p}"); done

# ------------------------------------------------------------ 2) DeployReport
CHANGES="unbekannt"
if [[ "${WITH_REPORT}" == "true" ]]; then
  log_step "2/4 Erzeuge DeployReport"
  run_sqlpackage /Action:DeployReport "${BASE_ARGS[@]}" /OutputPath:"${REPORT_FILE}" "${PROPS[@]}"
  # Jede betroffene Objekt-Aenderung erscheint als <Item .../> unter <Operation>
  CHANGES="$(grep -o '<Item ' "${REPORT_FILE}" | wc -l | tr -d ' ')" || CHANGES=0
  log_info "Geplante Objekt-Aenderungen: ${CHANGES}"
  grep -o '<Operation Name="[^"]*"' "${REPORT_FILE}" | sed 's/<Operation Name=/  Operation: /' >&2 || true
  if grep -q '<Alert Name="DataIssue"' "${REPORT_FILE}"; then
    log_warn "Report enthaelt Warnungen zu moeglichem DATENVERLUST – bitte pruefen: ${REPORT_FILE}"
  fi
else
  log_step "2/4 DeployReport uebersprungen"
fi

# ------------------------------------------------------------ 3) Diff-Skript
log_step "3/4 Erzeuge Diff-Skript"
SCRIPT_PROPS=("${PROPS[@]}")
[[ "${PORTABLE}" == "true" ]] && SCRIPT_PROPS+=("/p:CommentOutSetVarDeclarations=True")
run_sqlpackage /Action:Script "${BASE_ARGS[@]}" /OutputPath:"${SCRIPT_FILE}" "${SCRIPT_PROPS[@]}"
[[ -f "${SCRIPT_FILE}" ]] || die "sqlpackage hat kein Skript erzeugt."

if [[ "${CHANGES}" == "0" && "${SKIP_EMPTY}" == "true" ]]; then
  log_info "Keine Aenderungen – Dateien werden verworfen (--skip-empty)."
  rm -f "${SCRIPT_FILE}" "${REPORT_FILE}"
  exit 0
fi

# ------------------------------------------------------------ 4) Metadaten
log_step "4/4 Schreibe Metadaten"
GIT_COMMIT="$(git -C "$(dirname "${PROJECT:-${DACPAC}}")" rev-parse HEAD 2>/dev/null || echo "-")"
{
  echo "created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "target_server=${DB_SERVER:-<connection-string>}"
  echo "target_database=${DB_NAME}"
  echo "source=${PROJECT:-${DACPAC}}"
  echo "source_dacpac_sha256=$(sha256_of "${DACPAC}")"
  echo "git_commit=${GIT_COMMIT}"
  echo "publish_profile=${PROFILE:--}"
  echo "portable=${PORTABLE}"
  echo "operations=${CHANGES}"
  echo "script_sha256=$(sha256_of "${SCRIPT_FILE}")"
  echo "sqlpackage_version=$(sqlpackage_version)"
  echo "created_by=${USER:-$(id -un 2>/dev/null || echo unknown)}@$(hostname 2>/dev/null || echo unknown)"
} > "${META_FILE}"

log_step "Fertig"
log_info "Diff-Skript : ${SCRIPT_FILE}"
[[ "${WITH_REPORT}" == "true" ]] && log_info "Report      : ${REPORT_FILE}"
log_info "Metadaten   : ${META_FILE}"
echo "${SCRIPT_FILE}"

if [[ "${FAIL_ON_CHANGES}" == "true" && "${CHANGES}" != "0" ]]; then
  log_warn "Aenderungen gefunden (--fail-on-changes) -> Exit-Code 3"
  exit 3
fi
