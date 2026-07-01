# Despliegue del visor 3D en una VM de Azure

Arquitectura: **una VM** corre Orthanc + microservicio + Caddy (HTTPS). El backend
sigue en Render y el frontend en Vercel; ambos apuntan a la VM.

```
Navegador (médico)
   ├─ /api/imaging/... ──> Render (Spring) ──> https://VM/imaging (microservicio)
   └─ iframe VolView  ──> https://VM/volview  +  https://VM/imaging/.../lung-volume
                          (mismo origen VM = sin CORS)
```

## 1. Crear la VM
- Azure Portal → **Virtual Machine** → Ubuntu Server 22.04 LTS.
- Tamaño: **B2s** (2 vCPU / 4 GB) mínimo; **B2ms** (8 GB) si segmentarás estudios nuevos con holgura.
- **DNS name label**: pon uno (p. ej. `oncontrol-imaging`) → obtienes
  `oncontrol-imaging.<region>.cloudapp.azure.com` (gratis, sirve para el TLS).
- Networking / NSG: permitir **inbound 22, 80, 443**.

## 2. Preparar la VM (por SSH)
```bash
# Docker + compose
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # reconecta la sesión SSH tras esto
```

## 3. Copiar el código
Copia a la VM las **dos** carpetas juntas (mismo directorio padre):
```
~/oncontrol/OnControlImaging-orthanc/     (este DEPLOY, docker-compose.deploy.yml, Caddyfile, orthanc.json)
~/oncontrol/OnControlImaging-Service/     (Dockerfile, app/, requirements.txt)
```
Con `scp -r` desde tu PC, o súbelas a un repo git y clónalas.
> No copies `OnControlImaging-Service/.venv` ni `storage/raw` (pesan); el `.dockerignore` ya excluye lo necesario para el build.

## 4. Levantar todo
```bash
cd ~/oncontrol/OnControlImaging-orthanc
export PUBLIC_HOST=oncontrol-imaging.<region>.cloudapp.azure.com
docker compose -f docker-compose.deploy.yml up -d --build
```
Caddy saca el certificado HTTPS solo (puede tardar ~30 s la primera vez).
Verifica: `curl https://$PUBLIC_HOST/imaging/health` → `{"status":"ok"}`.

## 5. Cargar el estudio DICOM
- Abre `https://$PUBLIC_HOST/ui/app/` (Orthanc Explorer 2) → botón **Upload** → arrastra
  el ZIP de DICOM (o los .dcm). El **Study ID de Orthanc es determinístico**: para el
  estudio demo seguirá siendo `1d907417-899bad5c-c0c54a1a-b77214c5-aa0d857e`
  (por eso `imaging-studies.ts` no cambia).
- Pre-calienta la caché (deja el volumen liviano listo):
```bash
curl -X POST "https://$PUBLIC_HOST/imaging/studies/1d907417-899bad5c-c0c54a1a-b77214c5-aa0d857e/segment-lungs"
```

## 6. Conectar backend y frontend
- **Render** (backend) → variable de entorno:
  `IMAGING_SERVICE_URL=https://oncontrol-imaging.<region>.cloudapp.azure.com/imaging`
  (guardar dispara un deploy en Render).
- **Vercel** (frontend) → variable de entorno:
  `NEXT_PUBLIC_ORTHANC_WEB_URL=https://oncontrol-imaging.<region>.cloudapp.azure.com/ui/app/`
  (`NEXT_PUBLIC_API_URL` ya apunta a Render). Redeploy.

## 7. Probar
Entra como médico → paciente **Juan Pérez** → pestaña **Tomografía 3D** →
**Generar reconstrucción**. Debe cargar el volumen liviano (~0.9 MB) casi al instante.

---

## Notas / endurecimiento
- **Apaga la VM cuando no la uses** (Portal → Stop/deallocate) para no gastar créditos.
- Orthanc va **sin auth** (`AuthenticationEnabled:false`) para que VolView cargue en el
  iframe. Es aceptable en un piloto con datos sintéticos. Para endurecer: añade
  `basic_auth` en Caddy solo sobre `/ui*` y `/app*` (deja `/volview` y `/studies` abiertos).
- Almacenamiento: los volúmenes docker (`orthanc-storage`, `imaging-storage`) persisten
  entre reinicios. Para nuevos estudios, la primera segmentación corre a resolución
  completa (la VM tiene RAM de sobra) y luego queda cacheada + liviana.
- Alternativa sin costo para demos puntuales: el mismo `docker-compose.deploy.yml` corre
  en tu PC; expón `PUBLIC_HOST` con un Cloudflare Tunnel en vez de la DNS de Azure.
