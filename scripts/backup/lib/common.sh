#!/usr/bin/env bash
# Funciones compartidas por los 4 scripts de backup (BLUEPRINT 3.5).
# Se usa con `source`, no se ejecuta directamente.

log() {
  # Formato simple; en el clúster stdout/stderr los captura promtail.
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

require_env() {
  local var missing=0
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log "ERROR: falta la variable de entorno ${var}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1
}

# age_encrypt_stream <recipient-public-key>
# Lee de stdin, escribe cifrado a stdout. Nunca toca disco sin cifrar.
age_encrypt_stream() {
  local recipient="$1"
  age --encrypt --recipient "${recipient}"
}

# age_decrypt_file <identity-file> <input> <output>
# Usado solo por verify-restore.sh (el único consumidor de la llave privada).
age_decrypt_file() {
  local identity="$1" input="$2" output="$3"
  age --decrypt --identity "${identity}" --output "${output}" "${input}"
}

# configure_rclone — genera un config temporal a partir de env vars R2_*.
# El archivo se borra en el EXIT trap del script que lo invoca.
# Devuelve la ruta del config vía stdout (el caller la captura).
configure_rclone() {
  require_env R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
  local config
  config="$(mktemp)"
  chmod 600 "${config}"
  cat > "${config}" <<EOF
[r2]
type = s3
provider = Cloudflare
env_auth = false
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
  echo "${config}"
}

# upload_to_r2 <rclone-config> <remote-path-relative-to-bucket>
# Lee el objeto cifrado de stdin y lo sube en streaming (rcat).
upload_to_r2() {
  local rclone_config="$1" remote_path="$2"
  rclone --config "${rclone_config}" rcat "r2:${R2_BUCKET}/${remote_path}" \
    --retries 3 --low-level-retries 6 --contimeout 15s --timeout 5m
}

# list_r2_backups <rclone-config> <prefix>
# Imprime "fecha\tpath" por línea, ordenado ascendente por fecha, extrayendo
# la fecha del nombre del objeto (formato <prefix>/YYYY-MM-DD.age).
# El 2>/dev/null trata "prefijo inexistente" (primera corrida) como lista
# vacía. Es seguro: enforce_retention se llama siempre DESPUÉS de un
# upload_to_r2 exitoso con las mismas credenciales, así que un fallo real
# de auth/red ya habría abortado el script antes de llegar aquí (set -e).
list_r2_backups() {
  local rclone_config="$1" prefix="$2"
  rclone --config "${rclone_config}" lsf "r2:${R2_BUCKET}/${prefix}/" 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}\.age$' \
    | sed -E 's#^([0-9]{4}-[0-9]{2}-[0-9]{2})\.age$#\1\t'"${prefix}"'/\1.age#' \
    | sort
}

# Aritmética de fechas portable GNU/BSD (macOS en dev, Ubuntu en CI/prod).
# _date_shift_days <YYYY-MM-DD> <±N> — fecha desplazada N días.
# _date_field <YYYY-MM-DD> <formato strftime> — campo extraído de la fecha.
_date_shift_days() {
  local base="$1" delta="$2"
  [[ "${delta}" == "0" ]] && { echo "${base}"; return; }
  date -u -d "${base} ${delta} days" +%Y-%m-%d 2>/dev/null \
    || date -u -j -v"${delta}"d -f "%Y-%m-%d" "${base}" +%Y-%m-%d
}

_date_field() {
  local date_str="$1" fmt="$2"
  date -u -d "${date_str}" "+${fmt}" 2>/dev/null \
    || date -u -j -f "%Y-%m-%d" "${date_str}" "+${fmt}"
}

# enforce_retention <rclone-config> <prefix> — 7 diarios, 4 semanales
# (domingo), 3 mensuales (día 1), según BLUEPRINT 3.5. Recibe la lista ya
# generada por list_r2_backups para facilitar el testing con datos sintéticos.
compute_retention_keep_set() {
  # stdin: "fecha\tpath" ordenado ascendente. stdout: paths a conservar.
  local daily_cutoff
  daily_cutoff="$(_date_shift_days "$(date -u +%Y-%m-%d)" -7)"

  local -a monthlies=() weeklies=() dailies=()
  local date path dow dom
  while IFS=$'\t' read -r date path; do
    [[ -z "${date}" ]] && continue

    if [[ "${date}" > "${daily_cutoff}" || "${date}" == "${daily_cutoff}" ]]; then
      dailies+=("${path}")
      continue
    fi

    dom="$(_date_field "${date}" %d)"
    dow="$(_date_field "${date}" %u)"
    if [[ "${dom}" == "01" ]]; then
      monthlies+=("${path}")
    elif [[ "${dow}" == "7" ]]; then
      weeklies+=("${path}")
    fi
  done

  # dailies: todos los que caen en la ventana de 7 días.
  # monthlies/weeklies: se recorta a los más recientes de cada categoría
  # (la entrada ya viene ordenada ascendente por fecha).
  printf '%s\n' "${dailies[@]}"
  printf '%s\n' "${monthlies[@]}" | tail -n 3
  printf '%s\n' "${weeklies[@]}" | tail -n 4
}

# enforce_retention <rclone-config> <prefix>
enforce_retention() {
  local rclone_config="$1" prefix="$2"
  local keep all to_delete

  all="$(list_r2_backups "${rclone_config}" "${prefix}")"
  [[ -z "${all}" ]] && { log "enforce_retention: sin objetos en ${prefix}, nada que podar."; return 0; }

  keep="$(printf '%s\n' "${all}" | compute_retention_keep_set | sort -u)"

  to_delete="$(comm -23 \
    <(printf '%s\n' "${all}" | awk -F'\t' '{print $2}' | sort -u) \
    <(printf '%s\n' "${keep}" | sort -u))"

  if [[ -z "${to_delete}" ]]; then
    log "enforce_retention: nada fuera de retención en ${prefix}."
    return 0
  fi

  while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    log "enforce_retention: borrando ${path} (fuera de 7d/4w/3m)."
    rclone --config "${rclone_config}" deletefile "r2:${R2_BUCKET}/${path}"
  done <<< "${to_delete}"
}

# notify_telegram <message>
# STUB (PROMPTS.md Fase 1.2): la integración real con el bot grammY llega en
# la Fase 2.4. Por ahora solo logea — nunca falla el script que lo llama.
notify_telegram() {
  log "notify_telegram (stub, Fase 2.4 la implementa): $*"
}
