#!/usr/bin/env bash
# shellcheck shell=bash
# -----------------------------------------------------------------------------
# data.sh – gemeinsame Funktionen der Datenversionierung
#           (db-data-init.sh, db-data-refresh.sh, db-data-apply.sh)
#
# Ablage im Repository:
#   data/<Datenbank>/data.conf              welche Tabellen versioniert werden
#   data/<Datenbank>/<Schema>.<Tabelle>.sql MERGE-Skript mit allen Datensaetzen
#
# data.conf (eine Angabe pro Zeile, # = Kommentar, Platzhalter * und ? erlaubt):
#   include conf                 -> alle Tabellen im Schema conf
#   include pc.*                 -> dto. fuer pc
#   include dbo.Mapping          -> einzelne Tabelle
#   exclude conf.Log*            -> Tabellen ausnehmen
#   exclude-column *.GeaendertAm -> Spalte(n) nicht versionieren (Tabellenmuster.Spalte)
#   max-rows 50000               -> Sicherheitslimit je Tabelle
# -----------------------------------------------------------------------------

DATA_EXPORT_SQL="${TOOLKIT_LIB_DIR}/data-export.sql"
: "${DATA_MAX_ROWS:=50000}"

DC_INCLUDE=(); DC_EXCLUDE=(); DC_EXCL_COLS=(); DC_MAX_ROWS="${DATA_MAX_ROWS}"

# Muster normalisieren: "conf" -> "conf.*"
_dc_norm() { if [[ "$1" == *.* ]]; then printf '%s' "$1"; else printf '%s.*' "$1"; fi; }

# Glob-Vergleich ohne Beachtung der Gross-/Kleinschreibung
_dc_match() {
  local name=$1 pattern=$2
  # shellcheck disable=SC2053
  [[ "${name,,}" == ${pattern,,} ]]
}

# data_conf_read <datei>
data_conf_read() {
  local conf=$1 key val line
  [[ -f "${conf}" ]] || die "Konfiguration nicht gefunden: ${conf}"
  DC_INCLUDE=(); DC_EXCLUDE=(); DC_EXCL_COLS=(); DC_MAX_ROWS="${DATA_MAX_ROWS}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"; line="$(printf '%s' "${line}" | tr -d '\r' | xargs)"
    [[ -z "${line}" ]] && continue
    key="${line%% *}"; val="${line#* }"
    [[ "${key}" == "${line}" ]] && die "Ungueltige Zeile in ${conf}: '${line}'"
    case "${key,,}" in
      include)        DC_INCLUDE+=("$(_dc_norm "${val}")") ;;
      exclude)        DC_EXCLUDE+=("$(_dc_norm "${val}")") ;;
      exclude-column) [[ "${val}" == *.* ]] || die "exclude-column erwartet Tabellenmuster.Spalte: '${val}'"
                      DC_EXCL_COLS+=("${val}") ;;
      max-rows)       [[ "${val}" =~ ^[0-9]+$ ]] || die "max-rows muss eine Zahl sein: '${val}'"
                      DC_MAX_ROWS="${val}" ;;
      *) die "Unbekannter Eintrag '${key}' in ${conf}" ;;
    esac
  done < "${conf}"
  [[ ${#DC_INCLUDE[@]} -gt 0 ]] || die "Keine include-Angabe in ${conf}."
}

# data_select_tables <db>  -> gibt "schema.tabelle" je Zeile aus (sortiert)
data_select_tables() {
  local db=$1 tbl p inc
  local -a all
  mapfile -t all < <(run_sqlcmd "${db}" -h -1 -W -Q "SET NOCOUNT ON;
SELECT s.name + N'.' + t.name FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0 ORDER BY s.name, t.name;" | tr -d '\r' | sed '/^[[:space:]]*$/d')
  for tbl in "${all[@]}"; do
    inc=false
    for p in "${DC_INCLUDE[@]}"; do _dc_match "${tbl}" "${p}" && { inc=true; break; }; done
    [[ "${inc}" == "true" ]] || continue
    for p in "${DC_EXCLUDE[@]}"; do _dc_match "${tbl}" "${p}" && { inc=false; break; }; done
    [[ "${inc}" == "true" ]] && printf '%s\n' "${tbl}"
  done
  return 0
}

# data_excluded_cols <schema.tabelle> -> kommagetrennte Spaltenliste
data_excluded_cols() {
  local tbl=$1 e tp col out=""
  for e in "${DC_EXCL_COLS[@]}"; do
    tp="$(_dc_norm "${e%.*}")"; col="${e##*.}"
    if _dc_match "${tbl}" "${tp}"; then out+="${out:+,}${col}"; fi
  done
  printf '%s' "${out}"
}

# Dateiname fuer eine Tabelle
data_file_name() { printf '%s.%s.sql' "$(sanitize "$1")" "$(sanitize "$2")"; }

# data_export_table <db> <schema> <tabelle> <zieldatei> <ausgeschl.spalten> <max-rows>
data_export_table() {
  local db=$1 schema=$2 table=$3 out=$4 excl=$5 maxrows=$6 tmp err
  # shellcheck disable=SC2016  # '$(' ist hier woertlich gemeint (sqlcmd-Variablensyntax)
  for v in "${schema}" "${table}" "${excl}"; do
    if [[ "${v}" == *"'"* || "${v}" == *"]"* || "${v}" == *'$('* ]]; then
      log_error "Name mit nicht unterstuetzten Zeichen: ${v}"; return 1
    fi
  done
  tmp="$(mktemp)"; err="$(mktemp)"
  # -y 0: lange Zeilen nicht abschneiden (schliesst -h -1 aus -> Kopfzeile wird unten entfernt)
  if ! run_sqlcmd "${db}" -y 0 -r1 -f 65001 \
        -v "DataSchema=${schema}" -v "DataTable=${table}" -v "ExcludeCols=${excl}" \
        -v "MaxRows=${maxrows}" -v "DbLabel=${db}" \
        -i "${DATA_EXPORT_SQL}" > "${tmp}" 2> "${err}"; then
    log_error "Export von [${schema}].[${table}] fehlgeschlagen: $(tr -d '\r' < "${err}" | grep -v '^[[:space:]]*$' | tail -n 3 | xargs)"
    rm -f "${tmp}" "${err}"
    return 1
  fi
  # CR, Spaltenkopf (dv_line + ----), Leerzeichen am Zeilenende und Leerzeilen entfernen
  tr -d '\r' < "${tmp}" | sed -e 's/[[:space:]]*$//' \
    | awk 'hdr < 2 && /^dv_line$/ { hdr = 1; next }
           hdr == 1 && /^-+$/     { hdr = 2; next }
           { hdr = 2 } /^$/ { next } { print }' > "${out}"
  rm -f "${tmp}" "${err}"
  grep -q '^-- Tabelle: ' "${out}" || { log_error "Unerwartete Ausgabe beim Export von [${schema}].[${table}]."; return 1; }
}

# data_refresh_db <db> <ordner> <prune:true|false>
# Exportiert alle laut data.conf versionierten Tabellen neu. Setzt DR_* Zaehler.
data_refresh_db() {
  local db=$1 dir=$2 prune=$3 tbl schema table file tmpfile before after excl
  local -a tables expected=()
  DR_NEW=0; DR_CHANGED=0; DR_SAME=0; DR_FAILED=0; DR_STALE=0
  data_conf_read "${dir}/data.conf"
  mapfile -t tables < <(data_select_tables "${db}")
  log_info "[${db}] ${#tables[@]} Tabelle(n) laut ${dir}/data.conf"
  [[ ${#tables[@]} -gt 0 ]] || log_warn "[${db}] Keine passende Tabelle gefunden."

  for tbl in "${tables[@]}"; do
    schema="${tbl%%.*}"; table="${tbl#*.}"
    file="${dir}/$(data_file_name "${schema}" "${table}")"
    expected+=("$(basename "${file}")")
    excl="$(data_excluded_cols "${tbl}")"
    tmpfile="$(mktemp)"
    if ! data_export_table "${db}" "${schema}" "${table}" "${tmpfile}" "${excl}" "${DC_MAX_ROWS}"; then
      DR_FAILED=$((DR_FAILED + 1)); rm -f "${tmpfile}"; continue
    fi
    if [[ ! -f "${file}" ]]; then
      mv -f "${tmpfile}" "${file}"; DR_NEW=$((DR_NEW + 1))
      log_info "  neu        ${file}"
    else
      before="$(sha256_of "${file}")"; after="$(sha256_of "${tmpfile}")"
      if [[ "${before}" == "${after}" ]]; then
        rm -f "${tmpfile}"; DR_SAME=$((DR_SAME + 1))
        log_debug "  unveraendert ${file}"
      else
        cat "${tmpfile}" > "${file}"; rm -f "${tmpfile}"; DR_CHANGED=$((DR_CHANGED + 1))
        log_info "  geaendert  ${file}"
      fi
    fi
  done

  # Dateien zu Tabellen, die nicht (mehr) versioniert werden
  local f base keep
  for f in "${dir}"/*.sql; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"; keep=false
    for e in "${expected[@]}"; do [[ "${e}" == "${base}" ]] && { keep=true; break; }; done
    [[ "${keep}" == "true" ]] && continue
    DR_STALE=$((DR_STALE + 1))
    if [[ "${prune}" == "true" ]]; then
      rm -f "${f}" && log_info "  entfernt   ${f}"
    else
      log_warn "  verwaist   ${f} (Tabelle nicht mehr versioniert/vorhanden – mit --prune entfernen)"
    fi
  done
  log_info "[${db}] neu: ${DR_NEW}, geaendert: ${DR_CHANGED}, unveraendert: ${DR_SAME}, Fehler: ${DR_FAILED}, verwaist: ${DR_STALE}"
  [[ ${DR_FAILED} -eq 0 ]]
}
