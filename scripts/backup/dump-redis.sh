#!/usr/bin/env bash
# Snapshot de Redis: SAVE + streaming del RDB vía protocolo (redis-cli --rdb),
# sin montar el PVC de Redis (BLUEPRINT 3.5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env \
  REDIS_HOST REDIS_PORT REDIS_PASSWORD \
  AGE_RECIPIENT_PUBLIC_KEY \
  R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET

RCLONE_CONFIG="$(configure_rclone)"
trap 'rm -f "${RCLONE_CONFIG}"' EXIT

DATE="$(date -u +%Y-%m-%d)"
REMOTE_PATH="redis/${DATE}.age"

log "Forzando SAVE en Redis (${REDIS_HOST}:${REDIS_PORT})..."
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning SAVE

log "Iniciando snapshot de Redis -> r2:${R2_BUCKET}/${REMOTE_PATH}"

redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning --rdb - \
  | age_encrypt_stream "${AGE_RECIPIENT_PUBLIC_KEY}" \
  | upload_to_r2 "${RCLONE_CONFIG}" "${REMOTE_PATH}"

log "Snapshot de Redis subido correctamente."

enforce_retention "${RCLONE_CONFIG}" "redis"

log "Backup de Redis completo."
