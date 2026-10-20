#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-data-refresh.sh – Versionierte Daten erneut aus der Datenbank lesen
#
# Liest alle Tabellen laut data/<Datenbank>/data.conf neu aus und
# aktualisiert die Dateien. Neue Tabellen in den konfigurierten Schemata
# werden automatisch aufgenommen. Aenderungen sind danach per "git diff"
# zeilengenau sichtbar.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/data.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/data.sh"

usage() {
  cat <<USAGE
Verwendung: $(basename "$0") [-d DB] [Optionen]

Optionen:
  -d, --database NAME   Nur diese Datenbank (Default: alle Ordner unter --dir mit data.conf)
  --dir ORDNER          Basisordner (Default: data)
  --prune               Dateien von Tabellen loeschen, die nicht mehr versioniert werden
  --fail-on-changes     Exit-Code 3, wenn sich Daten geaendert haben (Drift-Check)
  -h, --help            Diese Hilfe

$(connection_help)

Beispiele:
  $(basename "$0") --env-file config/prod.env                # alle versionierten DBs
  $(basename "$0") --env-file config/prod.env -d DIZ_NET && git diff data/
USAGE
}

preload_env_file "$@"
unset DB_NAME
BASE_DIR="data"; PRUNE=false; FAIL_ON_CHANGES=false

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    --dir)             BASE_DIR=${2:?}; shift 2 ;;
    --prune)           PRUNE=true; shift ;;
    --fail-on-changes) FAIL_ON_CHANGES=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done
validate_connection
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (sqlcmd)."

DBS=()
if [[ -n "${DB_NAME:-}" ]]; then
  [[ -f "${BASE_DIR}/$(sanitize "${DB_NAME}")/data.conf" ]] \
    || die "Keine Datenversionierung fuer ${DB_NAME} eingerichtet (${BASE_DIR}/$(sanitize "${DB_NAME}")/data.conf fehlt) – db-data-init.sh verwenden."
  DBS=("${DB_NAME}")
else
  for c in "${BASE_DIR}"/*/data.conf; do
    [[ -f "${c}" ]] && DBS+=("$(basename "$(dirname "${c}")")")
  done
  [[ ${#DBS[@]} -gt 0 ]] || die "Keine data.conf unter ${BASE_DIR}/*/ gefunden."
fi

TOTAL_CHANGES=0; FAILED=0
for db in "${DBS[@]}"; do
  log_step "Aktualisiere Daten von ${DB_SERVER} / ${db}"
  if ! database_exists "${db}"; then
    log_warn "Datenbank '${db}' existiert nicht auf ${DB_SERVER} – uebersprungen."; FAILED=1; continue
  fi
  data_refresh_db "${db}" "${BASE_DIR}/$(sanitize "${db}")" "${PRUNE}" || FAILED=1
  TOTAL_CHANGES=$((TOTAL_CHANGES + DR_NEW + DR_CHANGED))
done

log_step "Fertig – ${TOTAL_CHANGES} Datei(en) neu oder geaendert"
[[ ${FAILED} -eq 0 ]] || die "Es sind Fehler aufgetreten (siehe oben)."
if [[ "${FAIL_ON_CHANGES}" == "true" && ${TOTAL_CHANGES} -gt 0 ]]; then
  log_warn "Daten weichen vom Repository ab (--fail-on-changes) -> Exit-Code 3"
  exit 3
fi
