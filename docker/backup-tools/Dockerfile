# Imagen mínima con las herramientas + scripts de scripts/backup/
# (BLUEPRINT 3.5): ninguna imagen oficial trae pg_dump + redis-cli +
# sqlite3 + age + rclone juntos. Todos los paquetes verificados en los
# repos main/community de Alpine 3.20 el 2026-07-20.
#
# Build context = raíz del repo (no este directorio): necesita copiar
# scripts/backup/. Ver .github/workflows/backup-tools.yaml.
#
# Bump manual de versión al cambiar este Dockerfile o los scripts (ver
# README de este directorio) — prohibido `latest` como tag (AGENTS.md /
# PROMPTS 1.1).
FROM alpine:3.20

# postgresql16 (no solo -client): verify-restore.sh necesita initdb/pg_ctl
# para levantar un Postgres efímero local y probar el restore ahí mismo.
# Versiones pinneadas (aarch64, Alpine 3.20) verificadas en
# pkgs.alpinelinux.org el 2026-07-20 — actualizar aquí junto con el bump
# de IMAGE_TAG cuando cambien.
RUN apk add --no-cache \
    bash=5.2.26-r0 \
    coreutils=9.5-r2 \
    findutils=4.9.0-r5 \
    grep=3.11-r0 \
    sed=4.9-r2 \
    postgresql16=16.14-r0 \
    redis=7.2.9-r0 \
    sqlite=3.45.3-r3 \
    age=1.2.1-r0 \
    rclone=1.66.0-r5 \
  && rm -rf /var/cache/apk/*

RUN addgroup -g 10001 backup && adduser -D -u 10001 -G backup backup

COPY --chown=backup:backup scripts/backup /scripts
RUN chmod -R a+rX /scripts && chmod 0555 /scripts/*.sh /scripts/lib/*.sh

USER backup

ENTRYPOINT ["/bin/bash"]
