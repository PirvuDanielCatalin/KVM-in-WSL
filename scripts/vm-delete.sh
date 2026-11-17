#!/usr/bin/env bash
# =============================================================================
# vm-delete.sh - Stergere VM libvirt
# Intraba: nume VM
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== 5) Stergere VM in libvirt ==="
echo

echo "Domenii libvirt disponibile:"
virsh -c "$VIRSH_URI" list --all --name 2>/dev/null | grep -v '^$' | awk '{print "  "$1}' || true
echo

echo "VM-uri inregistrate (registry wsl-kvm):"
if [ -s "$REGISTRY" ]; then
    awk -F'|' '{printf "  %-20s OS=%-12s RAM=%sGB CPU=%s NET=%s IP=%s\n", $1, $2, $3, $4, $5, $6}' "$REGISTRY"
else
    echo "  (nicio VM inregistrata)"
fi
echo
read -r -p "Nume VM de sters: " VM_NAME
[ -n "$VM_NAME" ] || { echo "[FAIL] Nume obligatoriu." >&2; exit 1; }

if ! virsh -c "$VIRSH_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "[WARN] Domeniul '$VM_NAME' nu exista in libvirt."
fi

read -r -p "Confirmare stergere '$VM_NAME' (destroy + undefine --nvram + stergere disc)? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }

virsh -c "$VIRSH_URI" destroy "$VM_NAME" >/dev/null 2>&1 || true
virsh -c "$VIRSH_URI" undefine --nvram "$VM_NAME" >/dev/null 2>&1 || true

# Stergere directorul VM-ului (disc overlay + log + xml)
VM_DIR="$VMS_DIR/$VM_NAME"
if [ -d "$VM_DIR" ]; then
    rm -rf "$VM_DIR"
    echo "[OK] Artefacte sterse: $VM_DIR"
fi

reg_rm_vm "$VM_NAME"
echo "[OK] VM '$VM_NAME' sters."
