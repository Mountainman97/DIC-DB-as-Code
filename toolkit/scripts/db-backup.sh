#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# db-backup.sh – Sicherung vor Deployments: anlegen, wiederherstellen, loeschen
#                oder einen beliebigen Befehl abgesichert ausfuehren
#
#   run      Sicherung anlegen -> Befehl ausfuehren -> bei Fehler wieder-
#            herstellen, bei Erfolg Sicherung loeschen (wie das alte Backupsystem)
#   create   Nur Sicherung anlegen (Referenzen in --state-file)
#   restore  Sicherung(en) aus --state-file wiederherstellen
#   drop     Sicherung(en) aus --state-file loeschen
#
# Die Sicherung ist optional. Die Deployment-Skripte nutzen sie nur, wenn
# BACKUP_MODE (oder --backup) auf "backup" oder "snapshot" gesetzt ist.
# -----------------------------------------------------------------------------
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=lib/backup.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/backup.sh"

usage() {
  cat <<EOF
Verwendung:
  $(basename "$0") run     -d DB [-d DB2 ...] [--mode M] [--keep] -- BEFEHL [ARGS...]
  $(basename "$0") create  -d DB [-d DB2 ...] [--mode M] --state-file DATEI
  $(basename "$0") restore --state-file DATEI
  $(basename "$0") drop    --state-file DATEI

Optionen:
  -d, --database NAME   Zu sichernde Datenbank (mehrfach moeglich)
  --mode M              backup | snapshot (Default: \$BACKUP_MODE, sonst backup)
  --backup-dir PFAD     Verzeichnis auf dem SQL-SERVER-Host [BACKUP_DIR]
  --no-compression      Backup ohne Kompression (z.B. SQL Express)
  --keep                Sicherung nach Erfolg nicht loeschen [BACKUP_KEEP=true]
  --state-file DATEI    Datei mit den angelegten Sicherungen (create/restore/drop)
  -h, --help            Diese Hilfe

$(connection_help)

Beispiele:
  # Mehrere Schritte als Einheit absichern (eine Sicherung je Datenbank)
  $(basename "$0") run --env-file config/prod.env -d DIZ_NET -d DIZ_NET_stage --mode snapshot -- \\
      bash -c 'db-apply-renames.sh --env-file config/prod.env --yes &&
               db-apply-diff.sh --env-file config/prod.env -d DIZ_NET --script artifacts/diff/x.sql --yes'

  # Getrennte Pipeline-Schritte
  $(basename "$0") create  --env-file config/prod.env -d DIZ_NET --state-file artifacts/backup.state
  $(basename "$0") restore --env-file config/prod.env --state-file artifacts/backup.state   # bei Fehler
  $(basename "$0") drop    --env-file config/prod.env --state-file artifacts/backup.state   # bei Erfolg
EOF
}

ACTION="${1:-}"
case "${ACTION}" in
  run|create|restore|drop) shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; die "Erstes Argument muss run, create, restore oder drop sein." ;;
esac

# --env-file nur aus den eigenen Argumenten (vor "--") laden
_pre=(); for _a in "$@"; do [[ "${_a}" == "--" ]] && break; _pre+=("${_a}"); done
preload_env_file "${_pre[@]}"

DBS=()
MODE=""
STATE_FILE=""
CMD=()
[[ "${BACKUP_MODE,,}" != "none" ]] && MODE="${BACKUP_MODE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--database)    DBS+=("${2:?}"); shift 2; continue ;;
    --mode)           MODE=${2:?}; shift 2; continue ;;
    --backup-dir)     BACKUP_DIR=${2:?}; shift 2; continue ;;
    --no-compression) BACKUP_COMPRESSION=false; shift; continue ;;
    --keep)           BACKUP_KEEP=true; shift; continue ;;
    --state-file)     STATE_FILE=${2:?}; shift 2; continue ;;
    -h|--help)        usage; exit 0 ;;
    --)               shift; CMD=("$@"); break ;;
  esac
  parse_connection_opt "$1" "${2-}"
  if [[ ${_CONSUMED} -gt 0 ]]; then shift "${_CONSUMED}"; continue; fi
  usage >&2; die "Unbekannte Option: $1"
done

BACKUP_MODE="${MODE:-backup}"
validate_backup_mode
[[ "${BACKUP_MODE}" != "none" ]] || die "--mode none ist hier nicht sinnvoll."
validate_connection
[[ -n "${DB_SERVER:-}" ]] || die "Fuer dieses Skript wird DB_SERVER benoetigt (sqlcmd)."

# ------------------------------------------------------------- Hilfsfunktionen
REFS_DB=(); REFS_REF=(); REFS_MODE=()

create_all() {
  local db ref
  for db in "${DBS[@]}"; do
    if ! database_exists "${db}"; then
      log_info "Datenbank [${db}] existiert nicht – keine Sicherung noetig."
      continue
    fi
    if ! ref="$(backup_create "${db}")"; then
      log_error "Sicherung von [${db}] fehlgeschlagen."
      drop_all
      return 1
    fi
    REFS_DB+=("${db}"); REFS_REF+=("${ref}"); REFS_MODE+=("${BACKUP_MODE}")
  done
}

restore_all() {   # in umgekehrter Reihenfolge
  local i failed=0
  for (( i=${#REFS_DB[@]}-1; i>=0; i-- )); do
    BACKUP_MODE="${REFS_MODE[$i]}"
    if backup_restore "${REFS_DB[$i]}" "${REFS_REF[$i]}"; then
      [[ "$(to_bool "${BACKUP_KEEP}")" == "true" ]] || backup_drop "${REFS_DB[$i]}" "${REFS_REF[$i]}"
    else
      failed=1
    fi
  done
  return "${failed}"
}

drop_all() {
  local i
  for i in "${!REFS_DB[@]}"; do
    BACKUP_MODE="${REFS_MODE[$i]}"
    backup_drop "${REFS_DB[$i]}" "${REFS_REF[$i]}"
  done
}

write_state() {
  local i
  mkdir -p "$(dirname "${STATE_FILE}")"
  : > "${STATE_FILE}"
  for i in "${!REFS_DB[@]}"; do
    printf '%s\t%s\t%s\n' "${REFS_MODE[$i]}" "${REFS_DB[$i]}" "${REFS_REF[$i]}" >> "${STATE_FILE}"
  done
}

read_state() {
  [[ -f "${STATE_FILE}" ]] || die "State-Datei nicht gefunden: ${STATE_FILE}"
  local m d r
  while IFS=$'\t' read -r m d r; do
    [[ -z "${m}" ]] && continue
    REFS_MODE+=("${m}"); REFS_DB+=("${d}"); REFS_REF+=("${r}")
  done < "${STATE_FILE}"
}

# ------------------------------------------------------------- Aktionen
case "${ACTION}" in
  create)
    [[ ${#DBS[@]} -gt 0 ]] || die "Mindestens eine Datenbank (-d) angeben."
    [[ -n "${STATE_FILE}" ]] || die "--state-file angeben."
    log_step "Lege Sicherung(en) an (${BACKUP_MODE})"
    create_all || die "Abbruch."
    write_state
    log_info "Sicherungen notiert in ${STATE_FILE}"
    ;;

  restore)
    [[ -n "${STATE_FILE}" ]] || die "--state-file angeben."
    read_state
    log_step "Stelle ${#REFS_DB[@]} Datenbank(en) wieder her"
    restore_all || die "Mindestens eine Wiederherstellung ist fehlgeschlagen."
    ;;

  drop)
    [[ -n "${STATE_FILE}" ]] || die "--state-file angeben."
    read_state
    log_step "Entferne ${#REFS_DB[@]} Sicherung(en)"
    drop_all
    ;;

  run)
    [[ ${#DBS[@]} -gt 0 ]] || die "Mindestens eine Datenbank (-d) angeben."
    [[ ${#CMD[@]} -gt 0 ]] || die "Kein Befehl nach '--' angegeben."

    log_step "Lege Sicherung(en) an (${BACKUP_MODE})"
    create_all || die "Abbruch – Befehl wurde NICHT ausgefuehrt."

    # Kindprozesse sollen nicht selbst noch einmal sichern
    export TOOLKIT_BACKUP_ACTIVE=1 BACKUP_MODE=none
    export DB_SERVER DB_AUTH DB_USER DB_PASSWORD DB_PASSWORD_FILE DB_ENCRYPT DB_TRUST_SERVER_CERT DB_CONNECT_TIMEOUT
    [[ -n "${DB_CONNECTION_STRING:-}" ]] && export DB_CONNECTION_STRING

    log_step "Fuehre aus: ${CMD[*]}"
    # Strg+C nicht sofort abbrechen lassen, damit noch wiederhergestellt wird
    trap 'log_warn "Abbruchsignal empfangen – warte auf Befehlsende und stelle ggf. wieder her."' INT TERM
    set +e; trap - ERR
    "${CMD[@]}"
    rc=$?
    set -e; trap '_on_error $LINENO' ERR
    trap - INT TERM

    if [[ ${rc} -ne 0 ]]; then
      log_error "Befehl fehlgeschlagen (Exit-Code ${rc})."
      if [[ ${#REFS_DB[@]} -gt 0 ]]; then
        log_step "Stelle Sicherung(en) wieder her"
        restore_all || log_error "Wiederherstellung unvollstaendig – Sicherungen wurden NICHT geloescht, bitte manuell pruefen!"
      fi
      exit "${rc}"
    fi

    if [[ "$(to_bool "${BACKUP_KEEP}")" == "true" ]]; then
      log_info "Erfolg – Sicherungen bleiben erhalten (--keep):"
      for i in "${!REFS_DB[@]}"; do log_info "  [${REFS_DB[$i]}] ${REFS_REF[$i]}"; done
    else
      log_step "Erfolg – entferne Sicherung(en)"
      drop_all
    fi
    ;;
esac
