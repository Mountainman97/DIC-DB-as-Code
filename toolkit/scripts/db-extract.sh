#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-extract.sh – Initialer Import einer bestehenden MS-SQL-Datenbank
#
#   1. Extrahiert die Datenbankstruktur als initiales DACPAC
#   2. Extrahiert dieselbe Struktur als .sql-Dateien in ein Verzeichnis
#      (Default-Gliederung: <Schema>/<Objekttyp>/<Objekt>.sql)
#   3. Legt eine SDK-artige .sqlproj-Datei an, damit das Verzeichnis spaeter
#      mit 'dotnet build' wieder zu einem DACPAC gebaut werden kann
#   4. Optional: baut das Projekt testweise (--build)
#
# Ausgabe auf STDOUT: Pfad des initialen DACPACs.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") --database NAME --output-dir ORDNER [Optionen]

Extrahiert Struktur (Schema, Tabellen, Views, Prozeduren, ...) einer Datenbank
in ein versionierbares Dateiverzeichnis und erzeugt ein initiales DACPAC.

Optionen:
  -o, --output-dir ORDNER   Projektordner fuer die .sql-Dateien          (Pflicht)
                            z.B. database/DIZ_NET
  --dacpac DATEI            Zielpfad des initialen DACPACs
                            (Default: ./artifacts/<Projektname>.dacpac)
  --project-name NAME       Name des Projekts/.sqlproj (Default: Datenbankname)
  --structure TYP           Ordnergliederung der .sql-Dateien:
                              SchemaObjectType (Default) | Schema | ObjectType |
                              Flat | SqlProject (*)
                            (*) SqlProject: sqlpackage erzeugt die .sqlproj
                                selbst (erfordert aktuelle sqlpackage-Version)
  --project-sdk SDK         Vorlage fuer die .sqlproj:
                              microsoft-build-sql (Default) | msbuild-sdk-sqlproj | none
  --sdk-version VERSION     Version des Projekt-SDKs
                            (Default: ${DEFAULT_SDK_VERSION_MBS} bzw. ${DEFAULT_SDK_VERSION_MSSP})
  --reference DACPAC[=DB]   Referenz auf eine andere Datenbank (z.B. bei
                            Abfragen auf [DIZ_NET].[dbo].[...] aus DIZ_NET_stage).
                            Das DACPAC wird nach <ORDNER>/references kopiert.
                            DB = Name der referenzierten Datenbank
                            (Default: Dateiname ohne .dacpac). Mehrfach moeglich.
  --include-permissions     Berechtigungen (GRANT/DENY) mit extrahieren
  --verify                  Extraktion durch sqlpackage validieren lassen
  --property NAME=WERT      Zusaetzliche Extract-Eigenschaft (/p:NAME=WERT), mehrfach
  --build                   Projekt nach dem Anlegen testweise bauen (dotnet noetig)
  --force                   In einen nicht-leeren Ordner extrahieren
                            (vorhandene Dateien gleichen Namens werden ueberschrieben)
  -h, --help                Diese Hilfe

$(connection_help)

Beispiel:
  $(basename "$0") --env-file config/prod-source.env -d DIZ_NET \\
      --output-dir database/DIZ_NET --dacpac artifacts/DIZ_NET.dacpac
EOF
}

DEFAULT_SDK_VERSION_MBS="2.3.0"     # Microsoft.Build.Sql
DEFAULT_SDK_VERSION_MSSP="4.4.0"    # MSBuild.Sdk.SqlProj

preload_env_file "$@"

OUTPUT_DIR=""
DACPAC_OUT=""
PROJECT_NAME=""
STRUCTURE="SchemaObjectType"
PROJECT_SDK="microsoft-build-sql"
SDK_VERSION=""
REFERENCES=()
INCLUDE_PERMISSIONS=false
VERIFY=false
EXTRA_PROPS=()
DO_BUILD=false
FORCE=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    -o|--output-dir)       OUTPUT_DIR=${2:?}; shift 2 ;;
    --dacpac)              DACPAC_OUT=${2:?}; shift 2 ;;
    --project-name)        PROJECT_NAME=${2:?}; shift 2 ;;
    --structure)           STRUCTURE=${2:?}; shift 2 ;;
    --project-sdk)         PROJECT_SDK=${2:?}; shift 2 ;;
    --sdk-version)         SDK_VERSION=${2:?}; shift 2 ;;
    --reference)           REFERENCES+=("${2:?}"); shift 2 ;;
    --include-permissions) INCLUDE_PERMISSIONS=true; shift ;;
    --verify)              VERIFY=true; shift ;;
    --property)            EXTRA_PROPS+=("${2:?}"); shift 2 ;;
    --build)               DO_BUILD=true; shift ;;
    --force)               FORCE=true; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

# ------------------------------------------------------------------ Validierung
[[ -n "${DB_NAME:-}" ]]  || { usage >&2; die "Keine Datenbank angegeben (--database oder DB_NAME)."; }
[[ -n "${OUTPUT_DIR}" ]] || { usage >&2; die "--output-dir fehlt."; }
validate_connection

case "${STRUCTURE}" in
  SchemaObjectType|Schema|ObjectType|Flat|SqlProject) ;;
  *) die "Ungueltige --structure '${STRUCTURE}'." ;;
esac
case "${PROJECT_SDK}" in
  microsoft-build-sql) : "${SDK_VERSION:=${DEFAULT_SDK_VERSION_MBS}}" ;;
  msbuild-sdk-sqlproj) : "${SDK_VERSION:=${DEFAULT_SDK_VERSION_MSSP}}" ;;
  none) ;;
  *) die "Ungueltiges --project-sdk '${PROJECT_SDK}'." ;;
esac
for ref in "${REFERENCES[@]}"; do
  [[ -f "${ref%%=*}" ]] || die "Referenz-DACPAC nicht gefunden: ${ref%%=*}"
done
if [[ ${#REFERENCES[@]} -gt 0 && "${PROJECT_SDK}" != "microsoft-build-sql" ]]; then
  log_warn "--reference wird nur fuer die Vorlage microsoft-build-sql automatisch eingetragen."
fi

: "${PROJECT_NAME:=${DB_NAME}}"
: "${DACPAC_OUT:=artifacts/${PROJECT_NAME}.dacpac}"
OUTPUT_DIR="$(abs_path "${OUTPUT_DIR}")"
DACPAC_OUT="$(abs_path "${DACPAC_OUT}")"

if [[ -d "${OUTPUT_DIR}" ]] && [[ -n "$(find "${OUTPUT_DIR}" -name '*.sql' -print -quit)" ]] && [[ "${FORCE}" != "true" ]]; then
  die "Ordner '${OUTPUT_DIR}' enthaelt bereits .sql-Dateien. Mit --force ueberschreiben."
fi
mkdir -p "${OUTPUT_DIR}" "$(dirname "${DACPAC_OUT}")"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

CS="$(build_connection_string "${DB_NAME}")"

COMMON_PROPS=(
  "/p:ExtractAllTableData=False"
  "/p:IgnoreUserLoginMappings=True"
  "/p:VerifyExtraction=$([[ "${VERIFY}" == "true" ]] && echo True || echo False)"
  "/p:IgnorePermissions=$([[ "${INCLUDE_PERMISSIONS}" == "true" ]] && echo False || echo True)"
)
for p in "${EXTRA_PROPS[@]}"; do COMMON_PROPS+=("/p:${p}"); done

log_info "Quelle : ${DB_SERVER:-<Connection-String>} / ${DB_NAME}"
log_info "Ziel   : ${OUTPUT_DIR}"
log_info "DACPAC : ${DACPAC_OUT}"

# --------------------------------------------------------- 1) DACPAC extrahieren
log_step "1/4 Extrahiere initiales DACPAC"
run_sqlpackage /Action:Extract /SourceConnectionString:"${CS}" \
  /TargetFile:"${DACPAC_OUT}" \
  /p:DacApplicationName="${PROJECT_NAME}" \
  "${COMMON_PROPS[@]}"

# ---------------------------------------------------- 2) .sql-Dateien extrahieren
log_step "2/4 Extrahiere Struktur als .sql-Dateien (${STRUCTURE})"
run_sqlpackage /Action:Extract /SourceConnectionString:"${CS}" \
  /TargetFile:"${WORK_DIR}/src" \
  /p:ExtractTarget="${STRUCTURE}" \
  "${COMMON_PROPS[@]}"

[[ -d "${WORK_DIR}/src" ]] || die "sqlpackage hat keinen Ordner erzeugt (${WORK_DIR}/src)."
cp -R "${WORK_DIR}/src/." "${OUTPUT_DIR}/"
SQL_COUNT="$(find "${OUTPUT_DIR}" -type f -name '*.sql' | wc -l | tr -d ' ')"
log_info "${SQL_COUNT} .sql-Dateien in ${OUTPUT_DIR}"

# ------------------------------------------------------- 3) Projektdatei anlegen
log_step "3/4 Projektdatei anlegen"

# Attribut aus model.xml des DACPACs lesen (DspName, CollationLcid, ...)
dacpac_model_attr() {
  local dacpac=$1 attr=$2 head
  if command -v unzip >/dev/null 2>&1; then
    head="$(unzip -p "${dacpac}" model.xml 2>/dev/null | head -c 4000 || true)"
  elif command -v python3 >/dev/null 2>&1; then
    head="$(python3 -c 'import sys,zipfile; print(zipfile.ZipFile(sys.argv[1]).read("model.xml")[:4000].decode("utf-8","ignore"))' "${dacpac}" 2>/dev/null || true)"
  else
    head=""
  fi
  printf '%s' "${head}" | grep -o "${attr}=\"[^\"]*\"" | head -n1 | sed -E 's/^[^"]*"([^"]*)"$/\1/' || true
}

DSP="$(dacpac_model_attr "${DACPAC_OUT}" DspName)"
LCID="$(dacpac_model_attr "${DACPAC_OUT}" CollationLcid)"
CASE_SENSITIVE="$(dacpac_model_attr "${DACPAC_OUT}" CollationCaseSensitive)"
if [[ -z "${DSP}" ]]; then
  DSP="Microsoft.Data.Tools.Schema.Sql.Sql160DatabaseSchemaProvider"
  log_warn "Zielplattform (DSP) nicht ermittelbar (unzip/python3 fehlt?) – verwende ${DSP}."
fi
SQL_VERSION="$(printf '%s' "${DSP}" | sed -E 's/.*\.(Sql[A-Za-z0-9]+)DatabaseSchemaProvider$/\1/')"
COLLATION="${LCID:-1033}, $([[ "${CASE_SENSITIVE,,}" == "true" ]] && echo CS || echo CI)"
log_info "Zielplattform: ${DSP} (${SQL_VERSION}), Collation: ${COLLATION}"

PROJ_FILE="${OUTPUT_DIR}/${PROJECT_NAME}.sqlproj"
EXISTING_PROJ="$(find "${OUTPUT_DIR}" -maxdepth 1 -name '*.sqlproj' -print -quit)"

# Referenzen vorbereiten
REF_XML=""
if [[ ${#REFERENCES[@]} -gt 0 ]]; then
  mkdir -p "${OUTPUT_DIR}/references"
  REF_XML="  <ItemGroup>"$'\n'
  for ref in "${REFERENCES[@]}"; do
    ref_file="${ref%%=*}"
    ref_db="${ref#*=}"
    [[ "${ref}" == *=* ]] || ref_db="$(basename "${ref_file}" .dacpac)"
    [[ -f "${ref_file}" ]] || die "Referenz-DACPAC nicht gefunden: ${ref_file}"
    cp -f "${ref_file}" "${OUTPUT_DIR}/references/"
    REF_XML+="    <ArtifactReference Include=\"references/$(basename "${ref_file}")\">"$'\n'
    REF_XML+="      <SuppressMissingDependenciesErrors>False</SuppressMissingDependenciesErrors>"$'\n'
    REF_XML+="      <DatabaseVariableLiteralValue>${ref_db}</DatabaseVariableLiteralValue>"$'\n'
    REF_XML+="    </ArtifactReference>"$'\n'
    log_info "Referenz: $(basename "${ref_file}") -> [${ref_db}]"
  done
  REF_XML+="  </ItemGroup>"
fi

if [[ "${STRUCTURE}" == "SqlProject" ]]; then
  log_info "Projektdatei wurde von sqlpackage erzeugt: ${EXISTING_PROJ:-<keine gefunden>}"
elif [[ "${PROJECT_SDK}" == "none" ]]; then
  log_info "Keine Projektdatei angelegt (--project-sdk none)."
elif [[ -n "${EXISTING_PROJ}" ]]; then
  log_warn "Projektdatei existiert bereits und wird nicht ueberschrieben: ${EXISTING_PROJ}"
else
  TEMPLATE="${TOOLKIT_ROOT}/templates/${PROJECT_SDK}.sqlproj.template"
  [[ -f "${TEMPLATE}" ]] || die "Vorlage nicht gefunden: ${TEMPLATE}"
  REF_XML="${REF_XML}" PROJECT_NAME="${PROJECT_NAME}" DSP="${DSP}" SQL_VERSION="${SQL_VERSION}" \
  COLLATION="${COLLATION}" SDK_VERSION="${SDK_VERSION}" \
  awk '{
      gsub(/@@PROJECT_NAME@@/, ENVIRON["PROJECT_NAME"]);
      gsub(/@@DSP@@/,          ENVIRON["DSP"]);
      gsub(/@@SQL_VERSION@@/,  ENVIRON["SQL_VERSION"]);
      gsub(/@@COLLATION@@/,    ENVIRON["COLLATION"]);
      gsub(/@@SDK_VERSION@@/,  ENVIRON["SDK_VERSION"]);
      if ($0 ~ /@@REFERENCES@@/) { if (ENVIRON["REF_XML"] != "") print ENVIRON["REF_XML"]; next }
      print
    }' "${TEMPLATE}" > "${PROJ_FILE}"
  log_info "Projektdatei angelegt: ${PROJ_FILE}"
fi

# .gitignore fuer Build-Ausgaben
if [[ ! -f "${OUTPUT_DIR}/.gitignore" ]]; then
  printf 'bin/\nobj/\n' > "${OUTPUT_DIR}/.gitignore"
fi

# ------------------------------------------------------------ 4) Testbuild (opt.)
if [[ "${DO_BUILD}" == "true" ]]; then
  log_step "4/4 Testbuild des Projekts"
  "${TOOLKIT_ROOT}/scripts/db-build.sh" --project "${OUTPUT_DIR}" \
      --output "${WORK_DIR}/build-check.dacpac" >/dev/null
  log_info "Projekt laesst sich erfolgreich bauen."
else
  log_step "4/4 Testbuild uebersprungen (mit --build aktivieren)"
fi

log_step "Fertig"
log_info "Naechste Schritte:"
log_info "  git add ${OUTPUT_DIR} && git commit -m 'Initialer Import ${DB_NAME}'"
log_info "  DACPAC als Build-Artefakt verwenden: ${DACPAC_OUT}"
echo "${DACPAC_OUT}"
