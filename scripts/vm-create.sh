#!/usr/bin/env bash
# =============================================================================
# vm-create.sh - Configurare VM in libvirt (KVM)
# Intraba: OS (Ubuntu 24/26), nume VM, IP din range, RAM (GB), CPU
# Creeaza overlay qcow2 peste imaginea de baza + cloud-init ISO (SSH doar cheie,
# fara parola) + domain XML + virsh define/start
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== 4) Configurare VM in libvirt ==="
echo

kvm_preflight >/dev/null 2>&1 || true

# --- Alegere retea ---
echo "Retele libvirt disponibile:"
virsh -c "$VIRSH_URI" net-list --all 2>/dev/null | awk 'NR>2 {print "  "$1}' || true
echo
read -r -p "Nume retea la care sa se ataseze VM-ul: " NET_NAME
[ -n "$NET_NAME" ] || { echo "[FAIL] Nume retea obligatoriu." >&2; exit 1; }
if ! virsh -c "$VIRSH_URI" net-info "$NET_NAME" >/dev/null 2>&1; then
    echo "[FAIL] Retea '$NET_NAME' nu exista. Creati-o mai intai (opt. 2)." >&2; exit 1
fi
NET_CIDR=$(net_cidr_of "$NET_NAME")
if [ -z "$NET_CIDR" ]; then
    echo "[WARN] Nu am CIDR inregistrat pentru '$NET_NAME'. Validarea IP-ului va fi sarita."
fi

# --- OS ---
echo
echo "Sistem de operare:"
echo "  1) Ubuntu 24.04 LTS"
echo "  2) Ubuntu 26.04 LTS"
read -r -p "Alegere (1/2): " OS_CHOICE
case "$OS_CHOICE" in
    1) OS_VER=24 ;;
    2) OS_VER=26 ;;
    *) echo "[FAIL] Optiune invalida." >&2; exit 1 ;;
esac

# --- Nume VM ---
read -r -p "Nume VM (ex. ubuntu-test-01): " VM_NAME
[ -n "$VM_NAME" ] || { echo "[FAIL] Nume VM obligatoriu." >&2; exit 1; }
if reg_vm_exists "$VM_NAME"; then
    echo "[FAIL] VM-ul '$VM_NAME' este deja inregistrat." >&2; exit 1
fi

# --- IP ---
if [ -n "$NET_CIDR" ]; then
    GW=$(cidr_first_usable "$NET_CIDR")
    echo "Range retea: $NET_CIDR (primul usable: $GW, ultimul: $(cidr_last_usable "$NET_CIDR"))"
fi
read -r -p "IP pentru VM (din range-ul de mai sus): " VM_IP
[ -n "$VM_IP" ] || { echo "[FAIL] IP obligatoriu." >&2; exit 1; }
if [ -n "$NET_CIDR" ] && ! ip_in_cidr "$VM_IP" "$NET_CIDR"; then
    echo "[FAIL] IP-ul $VM_IP nu apartine retelei $NET_CIDR sau este gateway/broadcast." >&2; exit 1
fi

# --- RAM / CPU cu raportare catre WSL ---
WSL_MEM=$(wsl_mem_gb)
WSL_CPU=$(wsl_cpu)
USED_MEM=$(wsl_mem_used_by_vms)
AVAIL_MEM=$(( WSL_MEM - USED_MEM ))
echo
echo "Resurse WSL: RAM total ${WSL_MEM}GB (folosit de VM-uri: ${USED_MEM}GB, disponibil: ${AVAIL_MEM}GB), CPU: $WSL_CPU"
read -r -p "RAM pentru VM [GB] (default 4): " RAM_GB
RAM_GB="${RAM_GB:-4}"
read -r -p "CPU pentru VM (default 2): " VCPU
VCPU="${VCPU:-2}"
read -r -p "Stocare pentru VM [GB] (default 10): " STORAGE_GB
STORAGE_GB="${STORAGE_GB:-10}"
if ! [[ "$RAM_GB" =~ ^[0-9]+$ ]] || ! [[ "$VCPU" =~ ^[0-9]+$ ]] || ! [[ "$STORAGE_GB" =~ ^[0-9]+$ ]]; then
    echo "[FAIL] RAM, CPU si stocare trebuie sa fie numere intregi." >&2; exit 1
fi
if [ "$RAM_GB" -gt "$AVAIL_MEM" ]; then
    echo "[WARN] Cereti $RAM_GB GB RAM dar disponibil sunt doar $AVAIL_MEM GB (inclusiv VM-urile existente)."
    read -r -p "Continuare totusi? (y/N): " c
    [[ "$c" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }
fi

MEM_MIB=$(( RAM_GB * 1024 ))
DISK_SIZE="${STORAGE_GB}G"

# --- Imagine de baza + overlay ---
BASE_IMG=$(ensure_golden "$OS_VER") || exit 1
VM_DIR="$VMS_DIR/$VM_NAME"
mkdir -p "$VM_DIR"
DISK_PATH="$VM_DIR/disk.qcow2"
CONSOLE_LOG="$VM_DIR/serial.log"
SSH_PUB_KEY="${SSH_PUB_KEY:-/home/dpirvu/.ssh/id_rsa.pub}"
SSH_PRIV_KEY="${SSH_PUB_KEY%.pub}"

if [ -f "$DISK_PATH" ]; then
    echo "[WARN] Discul overlay exista deja: $DISK_PATH"
    read -r -p "Suprascris? (y/N): " c
    [[ "$c" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }
    rm -f "$DISK_PATH"
fi

echo "[OK] Imagine baza: $BASE_IMG"
echo "[INFO] Creare overlay qcow2 (nu se booteaza imaginea baza in direct)"
BASE_FMT=$(qemu-img info "$BASE_IMG" 2>/dev/null | sed -n "s/^file format:[[:space:]]*\([a-z0-9]*\).*/\1/p" | head -1 | tr -d '[:space:]')
[ -n "$BASE_FMT" ] || BASE_FMT="qcow2"
qemu-img create -f qcow2 -F "$BASE_FMT" -b "$(readlink -f "$BASE_IMG")" "$DISK_PATH" "$DISK_SIZE" \
    || { echo "[FAIL] qemu-img create esuat"; exit 1; }
echo "[OK] Overlay creat: $DISK_PATH"

# Generare cloud-init ISO (user-data + meta-data) pentru SSH doar cu cheie, fara parola
echo
echo "--- Generare cloud-init ISO ---"
CLOUD_INIT_DIR="$VM_DIR/cloud-init"
CLOUD_INIT_ISO="$VM_DIR/cloud-init.iso"
mkdir -p "$CLOUD_INIT_DIR"
SSH_KEY_CONTENT=""
if [ -f "$SSH_PUB_KEY" ]; then
    SSH_KEY_CONTENT=$(cat "$SSH_PUB_KEY")
    echo "[OK] Cheia publica preluata din: $SSH_PUB_KEY"
else
    echo "[FAIL] Cheia publica nu exista la: $SSH_PUB_KEY"
    echo "       cloud-init necesita cheia pentru a configura SSH fara parola."
    echo "       Setati SSH_PUB_KEY sau adaugati cheia manual."
    exit 1
fi

# user-data: utilizator ubuntu, cheie SSH, parola blocata, autentificare doar cheie
# + script de curatare Docker programat in cron (root, la fiecare 2 ore)
cat > "$CLOUD_INIT_DIR/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_KEY_CONTENT}
    lock_passwd: true
disable_root: true
ssh_pwauth: no
write_files:
  - path: /usr/local/bin/cleanup-docker.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash

      # 1. Sterge imaginile vechi premdava-confluence-export (pastreaza cea mai recenta)
      docker image ls --format "{{.Repository}}:{{.Tag}}" | grep "^premdava-confluence-export:" | tail -n +2 | xargs -r docker image rm

      # 2. Ruleaza scriptul built-in de la GitLab Runner (daca exista pe sistem)
      if [ -x /usr/share/gitlab-runner/clear-docker-cache ]; then
          /usr/share/gitlab-runner/clear-docker-cache
      fi

      # 3. Curata imaginile nefolosite, containerele oprite si retelele mai vechi de 24h
      docker system prune -a -f --filter "until=24h"
runcmd:
  - command -v crontab >/dev/null 2>&1 || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron)
  - (crontab -l 2>/dev/null | grep -v cleanup-docker; echo '0 */2 * * * /usr/local/bin/cleanup-docker.sh > /dev/null 2>&1') | crontab -
EOF

# meta-data
cat > "$CLOUD_INIT_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -output "$CLOUD_INIT_ISO" -volid cidata -joliet -rock \
        "$CLOUD_INIT_DIR/user-data" "$CLOUD_INIT_DIR/meta-data" >/dev/null 2>&1 \
        || { echo "[FAIL] genisoimage a esuat la crearea cloud-init ISO."; exit 1; }
    echo "[OK] cloud-init ISO creat: $CLOUD_INIT_ISO"
else
    echo "[FAIL] genisoimage nu este instalat (pachetul genisoimage). Instalati-l (opt. 1)."
    exit 1
fi

# Pre-creare log citibil
touch "$CONSOLE_LOG" 2>/dev/null || sudo -n touch "$CONSOLE_LOG"
chmod 0644 "$CONSOLE_LOG" 2>/dev/null || sudo -n chmod 0644 "$CONSOLE_LOG" || true

MAC=$(mac_from_ip "$VM_IP")
NVRAM_PATH="/var/lib/libvirt/qemu/nvram/${VM_NAME}.fd"
OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"

echo
echo "VM: $VM_NAME | OS: Ubuntu $OS_VER | IP: $VM_IP | RAM: ${RAM_GB}GB | CPU: $VCPU | Stocare: ${STORAGE_GB}GB | MAC: $MAC"
echo "Retea: $NET_NAME | Disc: $DISK_PATH (${STORAGE_GB}GB) | Cloud-init ISO: $CLOUD_INIT_ISO"
read -r -p "Definire si pornire VM? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }

# Generare domain XML din template
sed -e "s|__VM_NAME__|$VM_NAME|g" \
    -e "s|__MEM_MIB__|$MEM_MIB|" \
    -e "s|__VCPU__|$VCPU|" \
    -e "s|__OVMF_CODE__|$OVMF_CODE|" \
    -e "s|__OVMF_VARS__|$OVMF_VARS|" \
    -e "s|__NVRAM_PATH__|$NVRAM_PATH|" \
    -e "s|__DISK_PATH__|$DISK_PATH|" \
    -e "s|__CLOUD_INIT_ISO__|$CLOUD_INIT_ISO|" \
    -e "s|__NET_NAME__|$NET_NAME|" \
    -e "s|__MAC__|$MAC|" \
    -e "s|__CONSOLE_LOG__|$CONSOLE_LOG|" \
    "$TEMPLATES_DIR/vm-domain.xml.tmpl" > "$VM_DIR/domain.xml"

virsh -c "$VIRSH_URI" define "$VM_DIR/domain.xml" || { echo "[FAIL] virsh define esuat"; exit 1; }
virsh -c "$VIRSH_URI" start "$VM_NAME" || { echo "[FAIL] virsh start esuat"; exit 1; }

# Autostart activat (sigur pentru Ubuntu/ext4; OPNsense/UFS il are dezactivat)
virsh -c "$VIRSH_URI" autostart --enable "$VM_NAME" >/dev/null 2>&1 || true

# Astepta ca cloud-init sa finalizeze si SSH sa devina disponibil (verificare la 10 secunde)
echo
echo "[INFO] Asteptare finalizare cloud-init si disponibilitate SSH (verificare la 10 secunde)..."
READY=0
for i in $(seq 1 60); do
    if ping -c 1 -W 2 "$VM_IP" >/dev/null 2>&1; then
        if ssh -i "$SSH_PRIV_KEY" "ubuntu@$VM_IP" 'echo READY' >/dev/null 2>&1; then
            READY=1
            break
        fi
    fi
    echo "  inca nu e gata (incercarea $i/60)..."
    sleep 10
done

if [ "$READY" -eq 1 ]; then
    echo "[OK] VM-ul '$VM_NAME' este gata - SSH functioneaza pe $VM_IP"
else
    echo "[WARN] Timp expirat (10 min) - cloud-init poate sa nu fi finalizat inca."
    echo "       Verificati manual: virsh -c qemu:///system console $VM_NAME"
fi

NOW=$(date +%s)
reg_add_vm "$VM_NAME|ubuntu-$OS_VER|$RAM_GB|$VCPU|$NET_NAME|$VM_IP|$DISK_PATH|$STORAGE_GB|$NOW"

echo
echo "========================================================================"
echo "[OK] VM '$VM_NAME' definit, pornit si setat pe autostart."
echo "     IP:    $VM_IP"
echo "     Disc:  ${STORAGE_GB}GB qcow2 overlay ($DISK_PATH)"
echo "     SSH:   ssh -i \"$SSH_PRIV_KEY\" ubuntu@$VM_IP"
echo "            (din Windows: wsl -e ssh -i \"$SSH_PRIV_KEY\" ubuntu@$VM_IP)"
echo "     Consola: virsh -c qemu:///system console $VM_NAME"
echo "     Log serial: $CONSOLE_LOG"
echo "     Curatare Docker: /usr/local/bin/cleanup-docker.sh (cron root, la fiecare 2 ore)"
echo
echo ">>> IMPORTANT: inainte de 'wsl --shutdown' (Windows), opriti gratios VM-urile:"
echo "     virsh -c qemu:///system shutdown $VM_NAME"
echo "========================================================================"
