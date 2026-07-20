# AGENTS.md — Yormun_Infra

Lee `../Yormun_Docs/AGENTS.md`: todas sus reglas aplican aquí (énfasis: sección 4.4, resources obligatorios).
Este repo: **Yormun_Infra** — manifests Kustomize (Flux los aplica al clúster), bootstrap y scripts de backup.
Ownership: **Antigravity**, excepto `scripts/backup/**` (Claude Code). Ningún secreto en YAML; image tags siempre pinneados.