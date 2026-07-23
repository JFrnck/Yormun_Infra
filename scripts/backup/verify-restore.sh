#!/usr/bin/env bash
# Prueba de restore mensual (BLUEPRINT 3.5, regla de oro #3: "ningún backup
# no probado cuenta como backup"). Descarga el dump de Postgres más reciente,
# lo descifra, restaura en un Postgres efímero local (mismo pod, sin tocar
# el Postgres real) y valida con SQL. Notifica el resultado (stub Telegram).
#
# La llave privada de age se monta como archivo (Secret age-backup-key),
# nunca como variable de entorno, para que no aparezca en `env` ni en logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env \
  AGE_IDENTITY_PATH \
  R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET

: "${SCRATCH_DIR:=$(mktemp -d)}"
: "${CRITICAL_TABLES:=}"  # CSV, ej. "audit_log,tasks". Vacío hasta Fase 2.2.
PGDATA_SCRATCH="${SCRATCH_DIR}/pgdata"
SOCKET_DIR="${SCRATCH_DIR}/socket"
ENCRYPTED_DUMP="${SCRATCH_DIR}/dump.age"
DECRYPTED_DUMP="${SCRATCH_DIR}/dump.pgcustom"

cleanup() {
  local exit_code=$?
  if [[ -d "${SOCKET_DIR}" ]] && pg_ctl status -D "${PGDATA_SCRATCH}" >/dev/null 2>&1; then
    pg_ctl stop -D "${PGDATA_SCRATCH}" -m immediate >/dev/null 2>&1 || true
  fi
  rm -rf "${SCRATCH_DIR}" "${RCLONE_CONFIG:-}"
  if [[ "${exit_code}" -eq 0 ]]; then
    notify_telegram "✅ Restore test mensual: OK ($(date -u +%Y-%m-%d))."
  else
    notify_telegram "❌ Restore test mensual: FALLÓ ($(date -u +%Y-%m-%d)). Revisar logs del CronJob verify-restore."
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

mkdir -p "${PGDATA_SCRATCH}" "${SOCKET_DIR}"

RCLONE_CONFIG="$(configure_rclone)"

log "Buscando el backup de Postgres más reciente en R2..."
LATEST_PATH="$(list_r2_backups "${RCLONE_CONFIG}" "postgres" | tail -n 1 | awk -F'\t' '{print $2}')"
if [[ -z "${LATEST_PATH}" ]]; then
  log "ERROR: no hay ningún backup de Postgres en R2 todavía."
  exit 1
fi
log "Backup más reciente: ${LATEST_PATH}"

rclone --config "${RCLONE_CONFIG}" copyto "r2:${R2_BUCKET}/${LATEST_PATH}" "${ENCRYPTED_DUMP}"

log "Descifrando..."
age_decrypt_file "${AGE_IDENTITY_PATH}" "${ENCRYPTED_DUMP}" "${DECRYPTED_DUMP}"
rm -f "${ENCRYPTED_DUMP}"

log "Inicializando Postgres efímero en ${PGDATA_SCRATCH}..."
initdb --username=postgres --auth=trust --no-instructions -D "${PGDATA_SCRATCH}" >/dev/null

pg_ctl start -D "${PGDATA_SCRATCH}" -o "-c listen_addresses='' -c unix_socket_directories=${SOCKET_DIR}" \
  -l "${SCRATCH_DIR}/postgres.log" -w -t 60

createdb -h "${SOCKET_DIR}" -U postgres restore_test

log "Restaurando dump..."
pg_restore -h "${SOCKET_DIR}" -U postgres -d restore_test --no-owner --no-privileges "${DECRYPTED_DUMP}"

log "Validando conectividad e integridad estructural..."
psql -h "${SOCKET_DIR}" -U postgres -d restore_test -v ON_ERROR_STOP=1 -Atc "SELECT 1;" >/dev/null

TABLE_COUNT="$(psql -h "${SOCKET_DIR}" -U postgres -d restore_test -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")"
log "Tablas restauradas en el esquema public: ${TABLE_COUNT}"

if [[ -n "${CRITICAL_TABLES}" ]]; then
  IFS=',' read -ra tables <<< "${CRITICAL_TABLES}"
  for table in "${tables[@]}"; do
    count="$(psql -h "${SOCKET_DIR}" -U postgres -d restore_test -Atc "SELECT count(*) FROM ${table};")"
    log "  ${table}: ${count} filas."
  done
fi

log "Restore test completo: OK."
