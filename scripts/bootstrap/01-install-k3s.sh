#!/usr/bin/env bash
# Instala K3s en la VM (Ubuntu 24.04 ARM). Correr como usuario con sudo.
# - servicelb deshabilitado: la única entrada al clúster es el Cloudflare
#   Tunnel; no queremos puertos 80/443 escuchando en la IP pública de OCI.
# - Traefik queda habilitado (es nuestro Ingress controller).
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"

echo ">> Instalando K3s ${K3S_VERSION} (servicelb deshabilitado)..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
  --disable=servicelb \
  --write-kubeconfig-mode=0600

echo ">> Esperando a que el nodo esté Ready..."
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=300s

echo ">> Configurando kubeconfig para el usuario actual..."
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 0600 "${HOME}/.kube/config"

echo ">> K3s instalado:"
kubectl get nodes -o wide
