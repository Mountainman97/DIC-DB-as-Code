#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# backup.sh – Sicherung vor Deployments (optional, Default: aus)
#
# Wird von common.sh-Nutzern zusaetzlich per "source" eingebunden.
#
# Verfahren (BACKUP_MODE):
#   none      keine Sicherung (Default)
#   backup    BACKUP DATABASE ... WITH COPY_ONLY in eine .bak-Datei auf dem
#             SQL-Server-Host; Wiederherstellung per RESTORE ... WITH REPLACE
#   snapshot  Datenbank-Snapshot (CREATE DATABASE ... AS SNAPSHOT OF);
#             sekundenschnell auch bei grossen DBs, Wiederherstellung per
#             RESTORE ... FROM DATABASE_SNAPSHOT. Erfordert Enterprise/Developer
#             oder Standard ab SQL Server 2016 SP1.
#
# Weitere Variablen:
#   BACKUP_DIR          Verzeichnis AUF DEM SQL-SERVER-HOST (nicht dem Client!)
#                       backup:   Default = Standard-Backupverzeichnis der Instanz
#                       snapshot: Default = Verzeichnis der jeweiligen Datendatei
#   BACKUP_COMPRESSION  true|false (Default: true; SQL Express: false setzen)
#   BACKUP_KEEP         true = Sicherung nach Erfolg NICHT loeschen (Default: false)
# -----------------------------------------------------------------------------

: "${BACKUP_MODE:=none}"
: "${BACKUP_COMPRESSION:=true}"
: "${BACKUP_KEEP:=false}"

validate_backup_mode() {
  BACKUP_MODE="${BACKUP_MODE,,}"
  case "${BACKUP_MODE}" in
    none|backup|snapshot) ;;
    *) die "Ungueltiger BACKUP_MODE '${BACKUP_MODE}' (erlaubt: none, backup, snapshot)." ;;
  esac
}

# Pfad-Trenner passend zum Server-Pfad (Windows: \, Linux: /)
_bk_join() {
  local dir=$1 file=$2 sep="/"
  [[ "${dir}" == *\\* ]] && sep="\\"
  dir="${dir%[\\/]}"
  printf '%s%s%s' "${dir}" "${sep}" "${file}"
}

_bk_default_dir() {
  local d
  d="$(sqlcmd_scalar master "SELECT CAST(COALESCE(SERVERPROPERTY('InstanceDefaultBackupPath'), SERVERPROPERTY('InstanceDefaultDataPath')) AS NVARCHAR(400));")"
  if [[ -z "${d}" || "${d}" == "NULL" ]]; then
    log_error "Backup-Verzeichnis der Instanz nicht ermittelbar – BACKUP_DIR setzen."
    return 1
  fi
  printf '%s' "${d}"
}

# backup_create <db>  -> gibt die Referenz (Datei bzw. Snapshot-Name) auf STDOUT aus
# Hinweis: Wird typischerweise in "if ! ref=\$(backup_create ...)" aufgerufen, wo
# set -e nicht greift – deshalb explizite "|| return 1".
backup_create() {
  local db=$1 stamp ref
  stamp="$(utc_stamp)"
  case "${BACKUP_MODE}" in
    backup)
      local dir comp=""
      dir="${BACKUP_DIR:-}"
      if [[ -z "${dir}" ]]; then dir="$(_bk_default_dir)" || return 1; fi
      ref="$(_bk_join "${dir}" "$(sanitize "${db}")_predeploy_${stamp}.bak")"
      [[ "$(to_bool "${BACKUP_COMPRESSION}")" == "true" ]] && comp=", COMPRESSION"
      log_info "Backup [${db}] -> ${ref}"
      run_sqlcmd master -Q "BACKUP DATABASE [${db//]/]]}] TO DISK = N'$(sql_lit "${ref}")' WITH COPY_ONLY, INIT, CHECKSUM${comp}, STATS = 25;" >&2 || return 1
      ;;
    snapshot)
      ref="$(sanitize "${db}")_predeploy_${stamp}"
      log_info "Snapshot [${db}] -> [${ref}]"
      local dir_expr="LEFT(f.physical_name, LEN(f.physical_name) - CHARINDEX(s.sep, REVERSE(f.physical_name)) + 1)"
      if [[ -n "${BACKUP_DIR:-}" ]]; then
        local d="${BACKUP_DIR%[\\/]}"
        if [[ "${d}" == *\\* ]]; then d+="\\"; else d+="/"; fi
        dir_expr="N'$(sql_lit "${d}")'"
      fi
      run_sqlcmd master -Q "SET NOCOUNT ON;
DECLARE @files NVARCHAR(MAX) = STUFF((
  SELECT N', (NAME = ' + QUOTENAME(f.name) + N', FILENAME = N''' + REPLACE(${dir_expr}, N'''', N'''''') + N'${ref}_' + f.name + N'.ss'')'
  FROM [${db//]/]]}].sys.database_files f
  CROSS APPLY (SELECT CASE WHEN f.physical_name LIKE N'%\\%' THEN N'\\' ELSE N'/' END AS sep) s
  WHERE f.type = 0
  FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'');
DECLARE @sql NVARCHAR(MAX) = N'CREATE DATABASE [${ref}] ON ' + @files + N' AS SNAPSHOT OF [${db//]/]]}];';
EXEC (@sql);" >&2 || return 1
      ;;
    *) die "backup_create: BACKUP_MODE=${BACKUP_MODE}" ;;
  esac
  printf '%s\n' "${ref}"
}

# backup_restore <db> <referenz>
backup_restore() {
  local db=$1 ref=$2 qdb="[${1//]/]]}]" rc=0
  log_warn "Stelle [${db}] aus ${BACKUP_MODE} '${ref}' wieder her (bestehende Verbindungen werden getrennt)"
  run_sqlcmd master -Q "ALTER DATABASE ${qdb} SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" >&2 || rc=$?
  if [[ ${rc} -eq 0 ]]; then
    case "${BACKUP_MODE}" in
      backup)   run_sqlcmd master -Q "RESTORE DATABASE ${qdb} FROM DISK = N'$(sql_lit "${ref}")' WITH REPLACE, RECOVERY, STATS = 25;" >&2 || rc=$? ;;
      snapshot) run_sqlcmd master -Q "RESTORE DATABASE ${qdb} FROM DATABASE_SNAPSHOT = N'$(sql_lit "${ref}")';" >&2 || rc=$? ;;
    esac
  fi
  # Mehrbenutzerbetrieb in jedem Fall wiederherstellen
  run_sqlcmd master -Q "IF DB_ID(N'$(sql_lit "${db}")') IS NOT NULL ALTER DATABASE ${qdb} SET MULTI_USER;" >&2 \
    || log_warn "MULTI_USER fuer [${db}] konnte nicht gesetzt werden – bitte manuell pruefen!"
  if [[ ${rc} -ne 0 ]]; then
    log_error "Wiederherstellung von [${db}] FEHLGESCHLAGEN. Sicherung bleibt erhalten: ${ref}"
    return "${rc}"
  fi
  log_info "[${db}] wiederhergestellt."
}

# backup_drop <db> <referenz>  – Sicherung entfernen (Fehler nur als Warnung)
backup_drop() {
  local db=$1 ref=$2
  case "${BACKUP_MODE}" in
    backup)
      log_info "Loesche Backup-Datei ${ref}"
      # sys.xp_delete_files ab SQL Server 2019, sonst xp_delete_file
      run_sqlcmd master -Q "SET NOCOUNT ON;
BEGIN TRY EXEC master.sys.xp_delete_files N'$(sql_lit "${ref}")'; END TRY
BEGIN CATCH EXEC master.dbo.xp_delete_file 0, N'$(sql_lit "${ref}")'; END CATCH" >/dev/null 2>&1 \
        || log_warn "Backup-Datei konnte nicht geloescht werden (Rechte?): ${ref}"
      ;;
    snapshot)
      log_info "Entferne Snapshot [${ref}]"
      run_sqlcmd master -Q "IF DB_ID(N'$(sql_lit "${ref}")') IS NOT NULL DROP DATABASE [${ref//]/]]}];" >&2 \
        || log_warn "Snapshot konnte nicht entfernt werden: ${ref}"
      ;;
  esac
}

# backup_reexec <db...>
# Startet das aufrufende Skript ueber "db-backup.sh run" neu, sodass die
# angegebenen Datenbanken vorher gesichert und bei Fehler wiederhergestellt
# werden. Erwartet das globale Array ORIG_ARGS (urspruengliche Argumente).
# Ohne aktive Sicherung (BACKUP_MODE=none) oder wenn bereits innerhalb von
# db-backup.sh ausgefuehrt, passiert nichts.
backup_reexec() {
  if [[ "${BACKUP_MODE}" == "none" || -n "${TOOLKIT_BACKUP_ACTIVE:-}" ]]; then return 0; fi
  [[ $# -gt 0 ]] || return 0
  local -a args=(run --mode "${BACKUP_MODE}")
  local db
  for db in "$@"; do args+=(-d "${db}"); done
  export DB_SERVER DB_AUTH DB_USER DB_PASSWORD DB_PASSWORD_FILE DB_ENCRYPT DB_TRUST_SERVER_CERT DB_CONNECT_TIMEOUT
  export BACKUP_DIR BACKUP_COMPRESSION BACKUP_KEEP
  log_info "Sicherung aktiv (${BACKUP_MODE}) fuer: $* – Ausfuehrung erfolgt abgesichert"
  exec "${TOOLKIT_ROOT}/scripts/db-backup.sh" "${args[@]}" -- "$0" "${ORIG_ARGS[@]}" --yes
}
