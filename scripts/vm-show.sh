#!/usr/bin/env bash
# =============================================================================
# vm-show.sh - Vizualizare detalii VM libvirt + instructiuni SSH
# Intraba: nume VM (cerut interactiva)
# Afiseaza: stare domeniu, detalii din registry, XML dumpxml, SSH din WSL/Windows
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SSH_PUB_KEY="${SSH_PUB_KEY:-/home/dpirvu/.ssh/id_rsa.pub}"
SSH_PRIV_KEY="${SSH_PUB_KEY%.pub}"

echo "=== Vizualizare VM libvirt ==="
echo

echo "VM-uri disponibile (libvirt):"
virsh -c "$VIRSH_URI" list --all --name 2>/dev/null | grep -v '^$' | awk '{print "  "$1}' || true
echo

read -r -p "Nume VM: " VM_NAME
[ -n "$VM_NAME" ] || { echo "[FAIL] Nume obligatoriu." >&2; exit 1; }

if ! virsh -c "$VIRSH_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "[FAIL] Domeniul '$VM_NAME' nu exista in libvirt." >&2
    exit 1
fi

echo
echo "--- Stare domeniu ---"
virsh -c "$VIRSH_URI" dominfo "$VM_NAME"

echo
echo "--- Detalii din registry wsl-kvm ---"
if reg_vm_exists "$VM_NAME"; then
    awk -F'|' -v n="$VM_NAME" \
        '$1==n {printf "  OS: %s\n  RAM: %s GB\n  CPU: %s\n  Stocare: %s GB\n  Retea: %s\n  IP: %s\n  Disc: %s\n", $2, $3, $4, $9, $5, $6, $7}' \
        "$REGISTRY"
else
    echo "  (nu este inregistrat in registry)"
fi

# Extragem IP din registry pentru instructiunile SSH
VM_IP=""
if reg_vm_exists "$VM_NAME"; then
    VM_IP=$(awk -F'|' -v n="$VM_NAME" '$1==n {print $6; exit}' "$REGISTRY")
fi

echo
echo "--- XML domeniu (dumpxml) ---"
virsh -c "$VIRSH_URI" dumpxml "$VM_NAME"

echo
echo "=== Conectare SSH ==="
if [ -n "$VM_IP" ]; then
    echo "IP VM: $VM_IP"
else
    echo "IP VM: (necunoscut - cauta in 'virsh dumpxml $VM_NAME' sau in registry)"
fi
echo
echo "Din WSL:"
echo "  ssh -i \"$SSH_PRIV_KEY\" ubuntu@${VM_IP:-<IP-VM>}"
echo "  # daca nu e injectata cheia, inceteaza parola default din imaginea cloud"
echo
echo "Din Windows (PowerShell):"
echo "  wsl -e ssh -i \"$SSH_PRIV_KEY\" ubuntu@${VM_IP:-<IP-VM>}"
echo "  # sau direct din Windows (daca portproxy / WSL IP forwarding e configurat):"
echo "  ssh -i C:\\\\Users\\\\<tu>\\\\.ssh\\\\id_rsa ubuntu@<IP-WSL-forwardat>"
echo
echo "Nota: cheia privata este identica pe Windows si WSL."
echo "      Asigura-te ca $SSH_PUB_KEY este injectata in VM (fie la creare, fie manual)."
if [ -f "$SSH_PUB_KEY" ]; then
    echo "[OK] Cheia publica gasita: $SSH_PUB_KEY"
else
    echo "[INFO] Cheia publica NU a fost gasita la: $SSH_PUB_KEY"
    echo "       Adauga-o manual in VM sau injecteaz-o la creare (vezi vm-create.sh)."
fi
