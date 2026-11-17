#!/usr/bin/env bash
# =============================================================================
# setup.sh - WSL KVM Tool (meniu interactiv)
# Ruleaza in WSL (Ubuntu). Nu ruleaza nimic in sine; doar populeaza directorul
# cu tool-urile necesare pentru crearea rapida de VM-uri KVM sub WSL2.
#
# Optiuni:
#   1) Configurare WSL      (.wslconfig: RAM, CPU, Swap + prerequisites KVM/libvirt)
#   2) Configurare retea    (nume + CIDR -> libvirt)
#   3) Vizualizare retea    (detalii libvirt + registry + lease-uri DHCP)
#   4) Stergere retea       (doar daca nu are VM-uri)
#   5) Configurare VM       (OS Ubuntu 24/26, IP, RAM, CPU raportate la WSL)
#   6) Vizualizare VM       (detalii libvirt + instructiuni SSH WSL/Windows)
#   7) Stergere VM
#   8) Configure GitLab Runner      (runner GitLab pe VM existenta)
#   9) Vizualizare GitLab Runner    (doar VM-urile deja configurate ca runner)
#  10) Stergere GitLab Runner       (dezinstalare completa; VM reconfigurabil)
#   0) Iesire
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

chmod +x "$SCRIPTS_DIR"/*.sh 2>/dev/null || true

menu() {
    clear 2>/dev/null || true
    echo "============================================================"
    echo "   WSL KVM Tool - crearea rapida de VM-uri KVM   "
    echo "   (WSL2 + libvirt + QEMU + KVM nested)                   "
    echo "============================================================"
    echo "   0) Iesire"
    echo "------------------------------------------------------------"
    echo "   1) Configurare WSL             (.wslconfig: RAM, CPU, Swap + prerequisites)"
    echo "------------------------------------------------------------"
    echo "   2) Configurare retea   (nume + CIDR)"
    echo "   3) Vizualizare retea   (detalii + lease-uri DHCP)"
    echo "   4) Stergere retea      (doar daca nu are VM-uri)"
    echo "------------------------------------------------------------"
    echo "   5) Configurare VM      (Ubuntu 24/26, IP, RAM, CPU)"
    echo "   6) Vizualizare VM      (detalii + instructiuni SSH)"
    echo "   7) Stergere VM"
    echo "------------------------------------------------------------"
    echo "   8) Configure GitLab Runner     (doar VM-urile care NU sunt runneri)"
    echo "   9) Vizualizare GitLab Runner   (doar VM-urile deja configurate)"
    echo "  10) Stergere GitLab Runner      (dezinstalare completa de pe VM)"
    echo "------------------------------------------------------------"
    echo "   Dir lucru: $SCRIPT_DIR"
    echo "   Stare:     ${WSL_KVM_STATE_DIR:-$HOME/.infra-lab/wsl-kvm}"
    echo "============================================================"
}

run() {
    local opt="$1"
    case "$opt" in
        1) bash "$SCRIPTS_DIR/wsl-config.sh" ;;
        2) bash "$SCRIPTS_DIR/network-create.sh" ;;
        3) bash "$SCRIPTS_DIR/network-show.sh" ;;
        4) bash "$SCRIPTS_DIR/network-delete.sh" ;;
        5) bash "$SCRIPTS_DIR/vm-create.sh" ;;
        6) bash "$SCRIPTS_DIR/vm-show.sh" ;;
        7) bash "$SCRIPTS_DIR/vm-delete.sh" ;;
        8) bash "$SCRIPTS_DIR/gitlab-runner-config.sh" ;;
        9) bash "$SCRIPTS_DIR/gitlab-runner-show.sh" ;;
        10) bash "$SCRIPTS_DIR/gitlab-runner-delete.sh" ;;
        *) echo "Optiune necunoscuta: $opt" >&2 ;;
    esac
}

# Daca rulat cu argument, executam direct si iesim
if [ "${1:-}" != "" ]; then
    run "$1"
    exit $?
fi

# Buclu interactiv
while true; do
    menu
    read -r -p "Alegere [0-10]: " choice
    case "$choice" in
        0) echo "La revedere."; exit 0 ;;
        1|2|3|4|5|6|7|8|9|10) run "$choice" ;;
        *) echo "Optiune invalida." ;;
    esac
    echo
    read -r -p "Apasati ENTER pentru a continua..." _
done
