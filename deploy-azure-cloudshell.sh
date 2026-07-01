#!/usr/bin/env bash
# =============================================================================
# OnControl Imaging — despliegue en Azure con UN solo pegado en Azure Cloud Shell
# Abre https://shell.azure.com (o el icono >_ del Portal), elige Bash, y pega esto.
# Crea la VM, instala Docker, clona los repos, levanta Orthanc + microservicio +
# Caddy (HTTPS automático via nip.io), IP estática y abre 80/443.
# Requisito: los repos OnControlImaging-Service y -orthanc deben ser PÚBLICOS.
# =============================================================================
set -e

RG=OnControl            # resource group existente (eastus2)
LOC=eastus2
VM=oncontrol-imaging
SIZE=Standard_B2s       # 2 vCPU / 4 GB

# --- cloud-init: se ejecuta dentro de la VM en el primer arranque ---
cat > cloud-init.yaml <<'EOF'
#cloud-config
package_update: true
packages: [git]
runcmd:
  - curl -fsSL https://get.docker.com | sh
  - install -d -m 0755 /opt/oncontrol
  - git clone https://github.com/WiJeGo/OnControlImaging-Service.git /opt/oncontrol/OnControlImaging-Service
  - git clone https://github.com/WiJeGo/OnControlImaging-orthanc.git /opt/oncontrol/OnControlImaging-orthanc
  - IP=$(curl -s https://api.ipify.org)
  - echo "PUBLIC_HOST=${IP}.nip.io" > /opt/oncontrol/OnControlImaging-orthanc/.env
  - cd /opt/oncontrol/OnControlImaging-orthanc && docker compose -f docker-compose.deploy.yml up -d --build
EOF

echo ">> Creando la VM (Ubuntu 24.04, $SIZE)..."
az vm create -g "$RG" -n "$VM" -l "$LOC" \
  --image Ubuntu2404 --size "$SIZE" \
  --admin-username azureuser --generate-ssh-keys \
  --custom-data cloud-init.yaml -o none

echo ">> Fijando IP pública estática (para que PUBLIC_HOST no cambie al apagar/encender)..."
IPID=$(az network nic show --ids "$(az vm show -g "$RG" -n "$VM" --query 'networkProfile.networkInterfaces[0].id' -o tsv)" \
  --query 'ipConfigurations[0].publicIpAddress.id' -o tsv)
az network public-ip update --ids "$IPID" --allocation-method Static -o none

echo ">> Abriendo puertos 80 y 443..."
az vm open-port -g "$RG" -n "$VM" --port 80  --priority 1001 -o none
az vm open-port -g "$RG" -n "$VM" --port 443 --priority 1002 -o none

IP=$(az vm list-ip-addresses -g "$RG" -n "$VM" \
  --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' -o tsv)

echo ""
echo "=================================================================="
echo " ✅ VM creada.  PUBLIC_HOST = ${IP}.nip.io"
echo " (espera 3-5 min a que cloud-init instale Docker y levante el stack)"
echo ""
echo " Verifica:   https://${IP}.nip.io/imaging/health   ->  {\"status\":\"ok\"}"
echo " Orthanc UI: https://${IP}.nip.io/ui/app/"
echo ""
echo " Luego setea estas variables de entorno:"
echo "   Render (backend):  IMAGING_SERVICE_URL = https://${IP}.nip.io/imaging"
echo "                      ORTHANC_URL         = https://${IP}.nip.io"
echo "   Vercel (frontend): NEXT_PUBLIC_ORTHANC_WEB_URL = https://${IP}.nip.io/ui/app/"
echo ""
echo " Apaga la VM cuando no la uses:  az vm deallocate -g $RG -n $VM"
echo " Enciéndela:                     az vm start      -g $RG -n $VM"
echo "=================================================================="
