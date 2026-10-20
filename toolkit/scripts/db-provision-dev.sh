#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-provision-dev.sh – Legt auf einer Zielinstanz eine (DEV-)Datenbank an und
#                       spielt ein DACPAC darauf aus
#
# Quelle ist entweder ein fertiges DACPAC (--dacpac) oder das SQL-Projekt im
# Dateiverzeichnis (--project), das vorher mit db-build.sh gebaut wird.
#
# Verhalten, falls die Ziel-Datenbank bereits existiert (--if-exists):
#   fail     (Default) Abbruch – schuetzt vor versehentlichem Ueberschreiben
#   update   Schema der bestehenden DB auf den DACPAC-Stand bringen
#   recreate DB loeschen und neu anlegen (/p:CreateNewDatabase=True)
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

usage() {
  cat <<EOF
Verwendung: $(basename "$0") --database NAME (--dacpac DATEI | --project PFAD) [Optionen]

Erzeugt eine Datenbank auf der Zielinstanz und deployt das DACPAC, z.B. um
eine DEV-Instanz pro Feature-Branch bereitzustellen.

Quelle (eines von beiden):
  --dacpac DATEI            Fertiges DACPAC
  --project PFAD            SQL-Projekt (Ordner/.sqlproj), wird vorher gebaut

Optionen:
  --if-exists MODUS         fail (Default) | update | recreate
  --profile DATEI           Publish-Profil (.publish.xml), z.B. config/dev.publish.xml
  --var NAME=WERT           SqlCmd-Variable fuer das Deployment (mehrfach)
  --property NAME=WERT      Zusaetzliche Publish-Eigenschaft (/p:NAME=WERT), mehrfach
  --allow-data-loss         BlockOnPossibleDataLoss=False (nur sinnvoll bei update)
  --renames ORDNER          Bei --if-exists update: Renaming-Skripte fuer diese DB
                            vor dem Deployment ausfuehren (db-apply-renames.sh)
  --data ORDNER             Nach dem Deployment versionierte Daten ausspielen
                            (db-data-apply.sh), z.B. data/DIZ_NET
  --post-script DATEI       Nach dem Deployment per sqlcmd ausfuehren (z.B.
                            Testdaten). Mehrfach moeglich, Reihenfolge bleibt.
  --backup MODE             Bei --if-exists update: vorher sichern, bei Fehler wiederherstellen, bei Erfolg
                            Sicherung loeschen: none|backup|snapshot [BACKUP_MODE]
  --allow-protected         Auch Datenbanken aus PROTECTED_DATABASES zulassen
  --yes                     Keine Rueckfrage bei recreate
  -h, --help                Diese Hilfe

$(connection_help)

Beispiele:
  $(basename "$0") --env-file config/dev.env -d DIZ_NET_DEV_1234 --project database/DIZ_NET
  $(basename "$0") --env-file config/dev.env -d DIZ_NET_DEV --dacpac artifacts/DIZ_NET.dacpac \\
      --if-exists recreate --yes --post-script testdata/seed.sql
EOF
}

ORIG_ARGS=("$@")
preload_env_file "$@"

DACPAC=""
PROJECT=""
IF_EXISTS="fail"
PROFILE="${PUBLISH_PROFILE:-}"
VARS=()
EXTRA_PROPS=()
ALLOW_DATA_LOSS=false
POST_SCRIPTS=()
ALLOW_PROTECTED=false
ASSUME_YES=false
RENAMES_DIR=""
DATA_DIR=""

while [[ $# -gt 0 ]]; do
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  case "$1" in
    --dacpac)          DACPAC=${2:?}; shift 2 ;;
    --project)         PROJECT=${2:?}; shift 2 ;;
    --if-exists)       IF_EXISTS=${2:?}; shift 2 ;;
    --profile)         PROFILE=${2:?}; shift 2 ;;
    --var)             VARS+=("${2:?}"); shift 2 ;;
    --property)        EXTRA_PROPS+=("${2:?}"); shift 2 ;;
    --allow-data-loss) ALLOW_DATA_LOSS=true; shift ;;
    --post-script)     POST_SCRIPTS+=("${2:?}"); shift 2 ;;
    --renames)         RENAMES_DIR=${2:?}; shift 2 ;;
    --data)            DATA_DIR=${2:?}; shift 2 ;;
    --backup)          BACKUP_MODE=${2:?}; shift 2 ;;
    --allow-protected) ALLOW_PROTECTED=true; shift ;;
    --yes|-y)          ASSUME_YES=true; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) usage >&2; die "Unbekannte Option: $1" ;;
  esac
done

# ------------------------------------------------------------------ Validierung
[[ -n "${DB_NAME:-}" ]] || { usage >&2; die "Keine Ziel-Datenbank angegeben (--database oder DB_NAME)."; }
if [[ -n "${DACPAC}" && -n "${PROJECT}" ]] || [[ -z "${DACPAC}" && -z "${PROJECT}" ]]; then
  usage >&2; die "Genau eine Quelle angeben: --dacpac ODER --project."
fi
case "${IF_EXISTS}" in fail|update|recreate) ;; *) die "Ungueltiger --if-exists '${IF_EXISTS}'." ;; esac
[[ -z "${PROFILE}" || -f "${PROFILE}" ]] || die "Publish-Profil nicht gefunden: ${PROFILE}"
for s in "${POST_SCRIPTS[@]}"; do [[ -f "${s}" ]] || die "Post-Skript nicht gefunden: ${s}"; done
[[ -z "${DATA_DIR}" || -d "${DATA_DIR}" ]] || die "Datenordner nicht gefunden: ${DATA_DIR}"
validate_connection
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (Existenzpruefung per sqlcmd)."

if is_protected_db "${DB_NAME}" && [[ "${ALLOW_PROTECTED}" != "true" ]]; then
  die "Datenbank '${DB_NAME}' ist geschuetzt (PROTECTED_DATABASES). Abbruch. Ggf. --allow-protected."
fi

validate_backup_mode
if [[ "${BACKUP_MODE}" != "none" && "${IF_EXISTS}" != "update" ]]; then
  log_warn "Sicherung wird nur bei --if-exists update verwendet – ignoriert."
  BACKUP_MODE=none
fi
# Optional: abgesichert ueber db-backup.sh neu starten (existiert die DB nicht,
# legt db-backup.sh keine Sicherung an)
backup_reexec "${DB_NAME}"

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

# ---------------------------------------------------------- 2) Ziel pruefen
log_step "2/4 Pruefe Ziel ${DB_SERVER} / ${DB_NAME}"
PUBLISH_PROPS=()
if database_exists "${DB_NAME}"; then
  case "${IF_EXISTS}" in
    fail)
      die "Datenbank '${DB_NAME}' existiert bereits. --if-exists update|recreate verwenden." ;;
    update)
      log_info "Datenbank existiert – Schema wird aktualisiert."
      if [[ -n "${RENAMES_DIR}" ]]; then
        log_info "Fuehre zuerst Renaming-Skripte aus ${RENAMES_DIR} aus"
        export DB_SERVER DB_AUTH DB_USER DB_PASSWORD DB_ENCRYPT DB_TRUST_SERVER_CERT DB_CONNECT_TIMEOUT
        rename_args=(--dir "${RENAMES_DIR}" --database "${DB_NAME}")
        [[ "${ASSUME_YES}" == "true" ]] && rename_args+=(--yes)
        "${TOOLKIT_ROOT}/scripts/db-apply-renames.sh" "${rename_args[@]}"
      fi ;;
    recreate)
      log_warn "Datenbank '${DB_NAME}' existiert und wird GELOESCHT und neu angelegt."
      if [[ "${ASSUME_YES}" != "true" ]]; then
        confirm "Datenbank '${DB_NAME}' auf '${DB_SERVER}' wirklich neu anlegen?" || die "Abgebrochen."
      fi
      PUBLISH_PROPS+=("/p:CreateNewDatabase=True") ;;
  esac
else
  log_info "Datenbank existiert nicht – wird durch das Deployment angelegt."
fi

# ---------------------------------------------------------- 3) Deployment
log_step "3/4 Deploye DACPAC nach ${DB_NAME}"
[[ "${ALLOW_DATA_LOSS}" == "true" ]] && PUBLISH_PROPS+=("/p:BlockOnPossibleDataLoss=False")
for p in "${EXTRA_PROPS[@]}"; do PUBLISH_PROPS+=("/p:${p}"); done
SP_ARGS=(/Action:Publish /SourceFile:"${DACPAC}"
         /TargetConnectionString:"$(build_connection_string "${DB_NAME}")")
[[ -n "${PROFILE}" ]] && SP_ARGS+=(/Profile:"${PROFILE}")
vars_to_sqlpackage VARS SP_ARGS
run_sqlpackage "${SP_ARGS[@]}" "${PUBLISH_PROPS[@]}"

# ---------------------------------------------------------- Daten (optional)
if [[ -n "${DATA_DIR}" ]]; then
  log_step "Spiele versionierte Daten aus ${DATA_DIR} aus"
  export DB_SERVER DB_AUTH DB_USER DB_PASSWORD DB_PASSWORD_FILE DB_ENCRYPT DB_TRUST_SERVER_CERT DB_CONNECT_TIMEOUT
  "${TOOLKIT_ROOT}/scripts/db-data-apply.sh" -d "${DB_NAME}" --dir "${DATA_DIR}" --backup none --yes
fi

# ---------------------------------------------------------- 4) Post-Skripte
if [[ ${#POST_SCRIPTS[@]} -gt 0 ]]; then
  log_step "4/4 Fuehre ${#POST_SCRIPTS[@]} Post-Skript(e) aus"
  SQLCMD_VARS=(-v "DatabaseName=${DB_NAME}")
  for kv in "${VARS[@]}"; do SQLCMD_VARS+=(-v "${kv}"); done
  for s in "${POST_SCRIPTS[@]}"; do
    log_info "-> ${s}"
    run_sqlcmd "${DB_NAME}" -I "${SQLCMD_VARS[@]}" -i "${s}"
  done
else
  log_step "4/4 Keine Post-Skripte"
fi

log_step "Fertig: ${DB_SERVER} / ${DB_NAME} ist bereit."
echo "${DB_NAME}"
