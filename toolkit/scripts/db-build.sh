#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-build.sh – Baut aus einem SQL-Projekt (Dateiverzeichnis) ein DACPAC
#
# Hilfsskript, wird von db-provision-dev.sh und db-diff.sh genutzt, kann aber
# auch eigenstaendig (z.B. als Build-Schritt einer Pipeline) laufen.
#
# Voraussetzung: .NET SDK (>= 8) und Zugriff auf das NuGet-Paket des
# Projekt-SDKs (Microsoft.Build.Sql oder MSBuild.Sdk.SqlProj), ggf. ueber
# einen internen NuGet-Feed / Offline-Ordner (siehe docs/01-installation.md).
#
# Ausgabe auf STDOUT: absoluter Pfad des erzeugten DACPACs.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") --project PFAD [--output DATEI.dacpac] [Optionen]

Baut das SQL-Projekt (Ordner mit genau einer .sqlproj-Datei oder direkt die
.sqlproj-Datei) mit 'dotnet build' und kopiert das Ergebnis-DACPAC.

Optionen:
  -p, --project PFAD        Projektordner oder .sqlproj-Datei             (Pflicht)
  -o, --output DATEI        Zielpfad fuer das DACPAC
                            (Default: ./artifacts/build/<Projektname>.dacpac)
  -c, --configuration KONF  Build-Konfiguration (Default: Release)
  --dotnet-arg ARG          Zusaetzliches Argument fuer 'dotnet build' (mehrfach)
  -h, --help                Diese Hilfe

Beispiel:
  $(basename "$0") --project database/DIZ_NET --output artifacts/DIZ_NET.dacpac
EOF
}

PROJECT=""
OUTPUT=""
CONFIGURATION="Release"
DOTNET_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)       PROJECT=${2:?}; shift 2 ;;
    -o|--output)        OUTPUT=${2:?}; shift 2 ;;
    -c|--configuration) CONFIGURATION=${2:?}; shift 2 ;;
    --dotnet-arg)       DOTNET_ARGS+=("${2:?}"); shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

[[ -n "${PROJECT}" ]] || { usage >&2; die "--project fehlt."; }
require_cmd dotnet "Bitte .NET SDK >= 8 installieren (siehe docs/01-installation.md)."

# Projektdatei ermitteln
if [[ -d "${PROJECT}" ]]; then
  mapfile -t projs < <(find "${PROJECT}" -maxdepth 1 -type f -name '*.sqlproj' | sort)
  [[ ${#projs[@]} -eq 1 ]] || die "Im Ordner '${PROJECT}' muss genau eine .sqlproj liegen (gefunden: ${#projs[@]})."
  PROJ_FILE="${projs[0]}"
elif [[ -f "${PROJECT}" && "${PROJECT}" == *.sqlproj ]]; then
  PROJ_FILE="${PROJECT}"
else
  die "Projekt nicht gefunden oder keine .sqlproj: ${PROJECT}"
fi
PROJ_FILE="$(abs_path "${PROJ_FILE}")"
PROJ_DIR="$(dirname "${PROJ_FILE}")"
PROJ_NAME="$(basename "${PROJ_FILE}" .sqlproj)"

: "${OUTPUT:=artifacts/build/${PROJ_NAME}.dacpac}"
OUTPUT="$(abs_path "${OUTPUT}")"
mkdir -p "$(dirname "${OUTPUT}")"

log_step "Baue ${PROJ_FILE} (${CONFIGURATION})"
dotnet build "${PROJ_FILE}" -c "${CONFIGURATION}" -nologo "${DOTNET_ARGS[@]}" >&2

# Neuestes <Projektname>.dacpac aus dem Build-Output (bin/<Konfiguration>/...)
DACPAC_SRC="$(find "${PROJ_DIR}/bin/${CONFIGURATION}" -type f -name "${PROJ_NAME}.dacpac" -print0 2>/dev/null \
  | xargs -0 -r ls -t 2>/dev/null | head -n1 || true)"
[[ -n "${DACPAC_SRC}" ]] || die "Build erfolgreich, aber kein ${PROJ_NAME}.dacpac unter ${PROJ_DIR}/bin/${CONFIGURATION} gefunden."

cp -f "${DACPAC_SRC}" "${OUTPUT}"
log_info "DACPAC erstellt: ${OUTPUT}"

# Referenzierte DACPACs (ArtifactReference) liegen im selben Build-Ordner.
# sqlpackage sucht sie beim Publish/Script neben dem Quell-DACPAC -> mitkopieren.
OUT_DIR="$(dirname "${OUTPUT}")"
for ref in "$(dirname "${DACPAC_SRC}")"/*.dacpac; do
  [[ "${ref}" == "${DACPAC_SRC}" ]] && continue
  [[ -f "${ref}" ]] || continue
  if [[ "${OUT_DIR}/$(basename "${ref}")" != "${OUTPUT}" ]]; then
    cp -f "${ref}" "${OUT_DIR}/"
    log_info "Referenziertes DACPAC mitkopiert: $(basename "${ref}")"
  fi
done
echo "${OUTPUT}"
