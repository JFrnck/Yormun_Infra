#!/usr/bin/env bash
# Pre-pull de la imagen Deno en el nodo. No hay warm pool (BLUEPRINT 4.4):
# los pods se crean bajo demanda y la imagen cacheada da arranques de ~2-5 s.
# Re-ejecutar tras cada upgrade de la imagen (y añadirlo al proceso de
# upgrade en el runbook correspondiente).
set -euo pipefail

DENO_IMAGE="${DENO_IMAGE:-docker.io/denoland/deno:distroless-2.9.3}"

echo ">> Pre-pulling ${DENO_IMAGE} en el containerd de K3s..."
sudo k3s ctr images pull "${DENO_IMAGE}"

echo ">> Verificando..."
sudo k3s ctr images ls | grep -F "${DENO_IMAGE#docker.io/}" || {
  echo "ERROR: la imagen no aparece en el cache del nodo." >&2
  exit 1
}
echo ">> OK: imagen Deno cacheada en el nodo."
