#!/usr/bin/env bats
# Cobertura BLUEPRINT 3.5 / PROMPTS 1.2: "la rotación de retención
# (7 diarios, 4 semanales, 3 mensuales) funciona."

setup() {
  LIB_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../lib" && pwd)"
  FIXTURES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/fixtures" && pwd)"
  # shellcheck source=../lib/common.sh
  source "${LIB_DIR}/common.sh"

  export MOCK_RCLONE_ROOT
  MOCK_RCLONE_ROOT="$(mktemp -d)"
  export PATH="${FIXTURES_DIR}/bin:${PATH}"
  RCLONE_CONFIG="dummy-config-not-read-by-mock"

  # R2_BUCKET lo usan upload_to_r2/list_r2_backups vía la variable global.
  export R2_BUCKET="test-bucket"
}

teardown() {
  rm -rf "${MOCK_RCLONE_ROOT}"
}

seed_backup() {
  local date="$1"
  mkdir -p "${MOCK_RCLONE_ROOT}/postgres"
  echo "backup-${date}" > "${MOCK_RCLONE_ROOT}/postgres/${date}.age"
}

@test "list_r2_backups: lista y ordena por fecha ascendente" {
  seed_backup "2026-07-01"
  seed_backup "2026-06-15"
  seed_backup "2026-07-10"

  run list_r2_backups "${RCLONE_CONFIG}" "postgres"
  [ "$status" -eq 0 ]
  first_date="$(echo "$output" | head -n1 | awk -F'\t' '{print $1}')"
  last_date="$(echo "$output" | tail -n1 | awk -F'\t' '{print $1}')"
  [ "${first_date}" = "2026-06-15" ]
  [ "${last_date}" = "2026-07-10" ]
}

find_old_non_sunday_non_first() {
  # Busca, relativo a "hoy" (sin fechas hardcodeadas: el test sigue siendo
  # válido en cualquier fecha futura), un día >7 atrás que no sea domingo
  # (dow=7) ni día 1 del mes — candidato inequívoco de poda.
  local today candidate dow dom i
  today="$(date -u +%Y-%m-%d)"
  for i in -10 -11 -12 -13 -14 -15 -16 -17; do
    candidate="$(_date_shift_days "${today}" "${i}")"
    dow="$(_date_field "${candidate}" %u)"
    dom="$(_date_field "${candidate}" %d)"
    if [[ "${dow}" != "7" && "${dom}" != "01" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

@test "compute_retention_keep_set: conserva los ultimos 7 dias sin filtrar por dow/dom" {
  today="$(date -u +%Y-%m-%d)"
  input=""
  for i in 0 -1 -2 -3 -4 -5 -6; do
    d="$(_date_shift_days "${today}" "${i}")"
    input+="${d}"$'\t'"postgres/${d}.age"$'\n'
  done

  keep="$(printf '%s' "${input}" | compute_retention_keep_set)"
  count=$(printf '%s\n' "${keep}" | grep -c . || true)
  # Los 7 días dentro de la ventana se conservan todos, sin importar
  # si caen en domingo o día 1 del mes.
  [ "${count}" -eq 7 ]
}

@test "compute_retention_keep_set: descarta un diario viejo que no es domingo ni dia 1" {
  old_date="$(find_old_non_sunday_non_first)"
  [ -n "${old_date}" ]

  input="${old_date}"$'\t'"postgres/${old_date}.age"$'\n'
  keep="$(printf '%s' "${input}" | compute_retention_keep_set)"
  run grep -F "${old_date}" <<< "${keep}"
  [ "$status" -ne 0 ]
}

@test "enforce_retention: borra un backup diario fuera de la ventana de 7 dias" {
  old_date="$(find_old_non_sunday_non_first)"
  [ -n "${old_date}" ]
  recent_date="$(date -u +%Y-%m-%d)"
  seed_backup "${old_date}"
  seed_backup "${recent_date}"

  enforce_retention "${RCLONE_CONFIG}" "postgres"

  [ ! -f "${MOCK_RCLONE_ROOT}/postgres/${old_date}.age" ]
  [ -f "${MOCK_RCLONE_ROOT}/postgres/${recent_date}.age" ]
}

@test "enforce_retention: conserva un backup del dia 1 del mes aunque sea viejo" {
  monthly_date="2025-01-01"
  recent_date="$(date -u +%Y-%m-%d)"
  seed_backup "${monthly_date}"
  seed_backup "${recent_date}"

  enforce_retention "${RCLONE_CONFIG}" "postgres"

  [ -f "${MOCK_RCLONE_ROOT}/postgres/${monthly_date}.age" ]
  [ -f "${MOCK_RCLONE_ROOT}/postgres/${recent_date}.age" ]
}

@test "enforce_retention: no falla y no borra nada si el prefijo esta vacio" {
  run enforce_retention "${RCLONE_CONFIG}" "postgres"
  [ "$status" -eq 0 ]
}
