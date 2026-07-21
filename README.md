# Yormun_Infra

Infraestructura de YORMUNGANDER: manifests Kustomize, scripts de bootstrap y (Fase 1.2) scripts de backup. Flux reconcilia `k8s/overlays/production` contra el clúster K3s.

Documentación canónica en `../Yormun_Docs/` (BLUEPRINT, AGENTS, WORKFLOW). Este README es el **runbook de bootstrap**: de una VM Ubuntu 24.04 limpia a clúster operativo en <2 h.

## Layout

```
k8s/
  base/
    namespaces/        yormun, yormun-executor, agents-sandbox (+quota/limits), observability
    network-policies/  aislamiento entre namespaces (BLUEPRINT 4.3)
    postgres/          Postgres 16 + pgvector, PVC 50Gi
    redis/             Redis 7 con AOF
    infisical/         gestor de secretos (usa el Postgres/Redis del clúster)
    cert-manager/      ClusterIssuer DNS-01 + Certificates wildcard (la app se instala en bootstrap)
    cloudflared/       túnel Cloudflare (modo token)
    traefik/           HelmChartConfig del Traefik bundled de K3s
    observability/     Prometheus + Loki + promtail + Grafana (mínimos; Tempo/PgBouncer pospuestos)
  overlays/
    production/        entrypoint que Flux reconcilia
scripts/
  bootstrap/           pasos 01-06 del runbook
```

Versiones de imágenes pinneadas en los manifests, verificadas contra Docker Hub/GitHub el 2026-07-20. Prohibido `latest`.

## Prerequisitos

- VM OCI Always Free ARM (4 vCPU / 24 GB / 200 GB), Ubuntu 24.04, acceso SSH.
- Dominios `yormun.com` y `yormungander.com` con DNS en Cloudflare.
- Cuenta Cloudflare con Zero Trust habilitado (plan free basta).
- En tu máquina o la VM: `git`, `curl`, `dig`.
- Llavero (Bitwarden/1Password) listo para guardar las credenciales que generes.

## Runbook de bootstrap

Todos los scripts se corren **en la VM**, desde la raíz de este repo clonado. Son idempotentes: re-ejecutar es seguro.

### 1. K3s (~10 min)

```bash
./scripts/bootstrap/01-install-k3s.sh
```

Instala K3s pinneado (`K3S_VERSION` para cambiarlo) con `servicelb` deshabilitado: la única entrada al clúster es el túnel — la IP pública de OCI no escucha en 80/443. Deja `kubectl` configurado para tu usuario.

### 2. Túnel y tokens en Cloudflare (~20 min, manual)

En el dashboard de Cloudflare:

1. **Zero Trust → Networks → Tunnels → Create tunnel** (tipo Cloudflared), nombre `yormun`. Copia el **token del túnel** (lo pide el paso 3).
2. En el túnel, **Public Hostnames** — crea dos entradas:
   - `*.yormun.com` → Service `https://traefik.kube-system.svc.cluster.local:443`, TLS → Origin Server Name: `*.yormun.com`.
   - `*.yormungander.com` → Service `https://traefik.kube-system.svc.cluster.local:443`, TLS → Origin Server Name: `*.yormungander.com`.
3. **DNS de cada zona**: si el wizard no los creó, añade CNAME `*` → `<tunnel-id>.cfargotunnel.com` (proxied) en `yormun.com` y en `yormungander.com`.
4. **API token** (My Profile → API Tokens): permisos `Zone.DNS: Edit` **solo** sobre las dos zonas. Es para el DNS-01 de cert-manager.

### 3. Secrets semilla (~10 min)

Infisical corre dentro del clúster, así que estos secretos iniciales se siembran a mano — es la única excepción a "todo en Infisical". Genera y exporta (y guarda en tu llavero):

```bash
export POSTGRES_PASSWORD="$(openssl rand -base64 24)"
export REDIS_PASSWORD="$(openssl rand -base64 24)"
export INFISICAL_ENCRYPTION_KEY="$(openssl rand -hex 16)"
export INFISICAL_AUTH_SECRET="$(openssl rand -base64 32)"
export CLOUDFLARE_API_TOKEN="<token del paso 2.4>"
export CLOUDFLARED_TUNNEL_TOKEN="<token del paso 2.1>"
export GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"

./scripts/bootstrap/02-seed-secrets.sh
```

### 4. Aplicar manifests (~20 min)

```bash
./scripts/bootstrap/04-apply-manifests.sh
```

Instala cert-manager pinneado, hace `kubectl apply --dry-run=server` de todo el overlay (falla temprano si algo está mal), aplica, y espera cada rollout. Los certificados wildcard tardan ~2 min en emitirse (DNS-01).

### 5. Verificación del túnel y DNS

```bash
./scripts/bootstrap/03-verify-tunnel-dns.sh
kubectl get certificate -A          # READY=True en los tres
curl -sI https://grafana.yormun.com # 200/302 (o pantalla de Cloudflare Access si ya está el paso 7)
```

### 6. GitOps con Flux (~10 min)

```bash
export GITHUB_TOKEN="<PAT con scope repo>"
./scripts/bootstrap/05-flux-bootstrap.sh
```

A partir de aquí, `git push` a `main` ⇒ Flux aplica en ≤5 min. Los cambios de infra ya no se aplican a mano.

### 7. Cloudflare Access (~10 min, manual)

Zero Trust → Access → Applications: crea una aplicación self-hosted para `grafana.yormun.com` (y futuras: `dash.yormun.com`, `app-*.yormungander.com`) con política de allow solo para tu email. Obligatorio según BLUEPRINT 5.1/5.4.

### 8. Pre-pull de la imagen Deno

```bash
./scripts/bootstrap/06-prepull-deno.sh
```

No hay warm pool: los pods de agentes se crean bajo demanda y la imagen cacheada da arranques de ~2-5 s. Re-ejecutar tras cada upgrade de imagen.

## Criterio de éxito de la Fase 1

- `https://grafana.yormun.com` responde con TLS válido (wildcard de Let's Encrypt) detrás de Cloudflare Access, y su dashboard muestra métricas de K3s (datasource Prometheus).
- `kubectl get certificate -A` muestra los tres certificados `READY=True`.
- `kubectl get pods -A` sin CrashLoopBackOff.
- Backups cifrados subiendo a R2 — llega en la **Fase 1.2** (`scripts/backup/`).

## Notas de diseño

- **Secrets:** ningún YAML de este repo contiene un secreto; todos referencian Secrets de K8s sembrados por `02-seed-secrets.sh` (semilla) o gestionados vía Infisical después. `gitleaks` corre en pre-commit en los repos de app.
- **agents-sandbox:** ResourceQuota como techo de ráfaga (6Gi/1500m, consumo idle cero), LimitRange con default 512Mi/500m y máximo 2Gi/1500m, PSA `restricted`, y NetworkPolicy default-deny con solo DNS de salida — las whitelists por tool las inyecta el Executor en runtime (Fase 5).
- **1 réplica + `maxSurge: 1, maxUnavailable: 0`** en los Deployments con rolling update: cero downtime sin pods redundantes (ANALISIS §7).
- **Infisical UI:** solo interna. `kubectl -n yormun port-forward svc/infisical 8080:8080` → `http://localhost:8080`. No se expone por el túnel.
- **Postgres/Redis compartidos con Infisical:** el init de Postgres crea la DB `infisical`; Redis se comparte con password. A este presupuesto de RAM no hay sitio para instancias dedicadas.

## Operación

- Cambios de infra: PR a `main` de este repo → CI (kube-linter + shellcheck) → merge humano → Flux aplica.
- CronJobs de backup y su verificación: Fase 1.2, `scripts/backup/` y `k8s/base/backup/`.
- Runbooks operativos (restore, VM perdida, rotación de tokens): `../Yormun_Docs/docs/runbooks/`.
