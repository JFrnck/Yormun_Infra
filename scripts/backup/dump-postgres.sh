#!/usr/bin/env bash
# pg_dump --format=custom, cifrado con age, subido a R2 (BLUEPRINT 3.5).
# Streaming puro: pg_dump | age | rclone. Nunca toca disco sin cifrar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env \
  PGHOST PGUSER PGPASSWORD PGDATABASE \
  AGE_RECIPIENT_PUBLIC_KEY \
  R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET

RCLONE_CONFIG="$(configure_rclone)"
trap 'rm -f "${RCLONE_CONFIG}"' EXIT

DATE="$(date -u +%Y-%m-%d)"
REMOTE_PATH="postgres/${DATE}.age"

log "Iniciando dump de Postgres (${PGDATABASE}@${PGHOST}) -> r2:${R2_BUCKET}/${REMOTE_PATH}"

pg_dump --format=custom --no-owner --no-privileges \
  | age_encrypt_stream "${AGE_RECIPIENT_PUBLIC_KEY}" \
  | upload_to_r2 "${RCLONE_CONFIG}" "${REMOTE_PATH}"

log "Dump de Postgres subido correctamente."

enforce_retention "${RCLONE_CONFIG}" "postgres"

log "Backup de Postgres completo."
