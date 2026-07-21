#!/usr/bin/env bats
# Cobertura BLUEPRINT 3.5 / PROMPTS 1.2: "el cifrado age funciona
# correctamente y no se puede descifrar sin la master key."

setup() {
  LIB_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../lib" && pwd)"
  # shellcheck source=../lib/common.sh
  source "${LIB_DIR}/common.sh"

  WORK_DIR="$(mktemp -d)"
  age-keygen -o "${WORK_DIR}/identity.txt" 2>/dev/null
  AGE_PUBLIC_KEY="$(grep '^# public key:' "${WORK_DIR}/identity.txt" | cut -d: -f2 | tr -d ' ')"

  age-keygen -o "${WORK_DIR}/wrong-identity.txt" 2>/dev/null
}

teardown() {
  rm -rf "${WORK_DIR}"
}

@test "age_encrypt_stream + age_decrypt_file: round-trip preserva el contenido" {
  printf 'contenido de prueba %s' "$$" > "${WORK_DIR}/plain.txt"

  age_encrypt_stream "${AGE_PUBLIC_KEY}" < "${WORK_DIR}/plain.txt" > "${WORK_DIR}/cipher.age"
  age_decrypt_file "${WORK_DIR}/identity.txt" "${WORK_DIR}/cipher.age" "${WORK_DIR}/decrypted.txt"

  run diff "${WORK_DIR}/plain.txt" "${WORK_DIR}/decrypted.txt"
  [ "$status" -eq 0 ]
}

@test "age_decrypt_file: falla con la llave privada equivocada" {
  echo "secreto" | age_encrypt_stream "${AGE_PUBLIC_KEY}" > "${WORK_DIR}/cipher.age"

  run age_decrypt_file "${WORK_DIR}/wrong-identity.txt" "${WORK_DIR}/cipher.age" "${WORK_DIR}/out.txt"
  [ "$status" -ne 0 ]
  [ ! -s "${WORK_DIR}/out.txt" ]
}

@test "age_decrypt_file: falla si el ciphertext fue corrompido (tampering)" {
  echo "secreto" | age_encrypt_stream "${AGE_PUBLIC_KEY}" > "${WORK_DIR}/cipher.age"

  # Corrompe el último byte del ciphertext (age falla por MAC inválido).
  size=$(wc -c < "${WORK_DIR}/cipher.age")
  last_byte_offset=$((size - 1))
  printf '\x00' | dd of="${WORK_DIR}/cipher.age" bs=1 seek="${last_byte_offset}" count=1 conv=notrunc 2>/dev/null

  run age_decrypt_file "${WORK_DIR}/identity.txt" "${WORK_DIR}/cipher.age" "${WORK_DIR}/out.txt"
  [ "$status" -ne 0 ]
}
