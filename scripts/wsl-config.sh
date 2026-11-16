#!/usr/bin/env bash
# =============================================================================
# wsl-config.sh - Configurare WSL (.wslconfig) + prerequisites KVM/libvirt
# Intraba: RAM (GB), CPU, Swap (GB) -> scrie C:\Users\<user>\.wslconfig
# Verifica si instaleaza toolchainul KVM/libvirt, grupurile kvm/libvirt,
# face $HOME traversabil pentru libvirt-qemu si porneste libvirtd.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== 1) Configurare WSL (.wslconfig) ==="
echo
echo "Acest pas scrie fisierul C:\Users\<user>\.wslconfig (de pe WSL: /mnt/c/Users/<user>/.wslconfig)."
echo "Modificarile se aplica DOAR dupa 'wsl --shutdown' rulat din Windows (PowerShell)."
echo

# Valoare default prudenta: 16 GB RAM, 8 CPU, 8 GB Swap
DEFAULT_MEM=16; DEFAULT_CPU=8; DEFAULT_SWAP=8

read -r -p "RAM alocat WSL [GB] (default $DEFAULT_MEM): " MEM_GB
MEM_GB="${MEM_GB:-$DEFAULT_MEM}"
read -r -p "CPU alocati WSL (default $DEFAULT_CPU): " CPUS
CPUS="${CPUS:-$DEFAULT_CPU}"
read -r -p "Swap alocat WSL [GB] (default $DEFAULT_SWAP): " SWAP_GB
SWAP_GB="${SWAP_GB:-$DEFAULT_SWAP}"

# Validare numerica
if ! [[ "$MEM_GB" =~ ^[0-9]+$ ]] || ! [[ "$CPUS" =~ ^[0-9]+$ ]] || ! [[ "$SWAP_GB" =~ ^[0-9]+$ ]]; then
    echo "[FAIL] RAM, CPU si Swap trebuie sa fie numere intregi." >&2
    exit 1
fi

CONFIG_PATH="$(wslconfig_path)"
if [ -z "$CONFIG_PATH" ]; then
    echo "[FAIL] Nu am putut identifica utilizatorul Windows (calea .wslconfig)." >&2
    echo "       Setati manual WSL_KVM_WIN_USER sau editati ~/.wslconfig pe Windows." >&2
    exit 1
fi

echo
echo "Cale detectata: $CONFIG_PATH"
echo "RAM: ${MEM_GB}GB | CPU: $CPUS | Swap: ${SWAP_GB}GB"
read -r -p "Continuare scriere .wslconfig? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }

# Generare din template
sed -e "s/__MEMORY_GB__/$MEM_GB/" \
    -e "s/__CPUS__/$CPUS/" \
    -e "s/__SWAP_GB__/$SWAP_GB/" \
    "$TEMPLATES_DIR/wslconfig.tmpl" > "$CONFIG_PATH"

echo "[OK] .wslconfig scrise in: $CONFIG_PATH"
echo
echo ">>> PASSO OBLIGATORIU: din PowerShell pe Windows rulati:  wsl --shutdown"
echo "     Apoi redeschideti WSL. .wslconfigul se aplica doar dupa repornire."

echo
echo "=== Verificare virtualizare nested + KVM ==="
if [ -c /dev/kvm ]; then
    echo "[OK] /dev/kvm exista: $(ls -l /dev/kvm | awk '{print $1, $3, $4}')"
else
    echo "[FAIL] /dev/kvm lipseste - activeaza nestedVirtualization=true in .wslconfig"
    echo "       si rulati 'wsl --shutdown' din Windows, apoi redeschideti WSL." >&2
    exit 1
fi
echo "Detalii WSL:"
cat /etc/wsl.conf 2>/dev/null || echo "  (fisier /etc/wsl.conf nu exista)"
free -h | grep Mem
echo "CPU: $(nproc)"

echo
echo "=== Instalare toolchain KVM/libvirt (o singura data) ==="
sudo apt-get update
sudo apt-get install -y \
  qemu-system-x86 qemu-utils ovmf \
  libvirt-daemon-system libvirt-clients libvirt-daemon-driver-qemu \
  dnsmasq-base cloud-image-utils genisoimage libguestfs-tools
echo "[OK] Toolchain instalat."

echo
echo "=== Grupuri kvm + libvirt ==="
sudo usermod -aG kvm,libvirt "$USER"
echo "[OK] Utilizatorul '$USER' adaugat in grupurile kvm si libvirt."
echo "     RE-LOGIN in WSL (inchide si redeschide fereastra), sau rulezi:"
echo "       newgrp kvm; newgrp libvirt"

echo
echo "=== $HOME traversabil pentru libvirt-qemu ==="
sudo chmod o+x "$HOME"
echo "[OK] Permisiuni $HOME: $(ls -ld "$HOME" | awk '{print $1}')"

echo
echo "=== Pornire libvirtd ==="
sudo systemctl enable --now libvirtd
virsh -c qemu:///system list --all
echo "[OK] libvirtd pornit."

echo
echo "ATENTIE: 'instanceIdleTimeout' sta in [general], NU in [wsl2]."
echo "         Nu setati swapFile= cu %TEMP% (WSL creeaza swap-ul singur)."
