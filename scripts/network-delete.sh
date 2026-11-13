#!/usr/bin/env bash
# =============================================================================
# network-delete.sh — Stergere retea libvirt (doar daca nu are VM-uri)
# Intraba: nume retea
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== 4) Stergere retea in libvirt ==="
echo

read -r -p "Nume retea de sters: " NET_NAME
[ -n "$NET_NAME" ] || { echo "[FAIL] Nume obligatoriu." >&2; exit 1; }

if ! virsh net-info "$NET_NAME" >/dev/null 2>&1; then
    echo "[WARN] Retea '$NET_NAME' nu exista in libvirt."
    exit 0
fi

# Verificare: are vreun VM inregistrat care o foloseste?
if reg_has_vm_on_net "$NET_NAME"; then
    echo "[FAIL] Retea '$NET_NAME' este folosita de cel putin un VM inregistrat."
    echo "       Stergeti mai intai VM-urile (opt. 5) sau stergeti-le manual, apoi reveniti aici."
    exit 1
fi

# Verificare suplimentare: este atașat vreun domeniu libvirt la retea?
ATTACHED=$(virsh -c "$VIRSH_URI" list --all --name 2>/dev/null | while read -r d; do
    [ -z "$d" ] && continue
    virsh -c "$VIRSH_URI" dumpxml "$d" 2>/dev/null | grep -q "source network='$NET_NAME'" && echo "$d"
done)
if [ -n "$ATTACHED" ]; then
    echo "[FAIL] Retea '$NET_NAME' este attasata la domeniile: $ATTACHED"
    echo "       Stergeti-le mai intai."
    exit 1
fi

read -r -p "Confirmare stergere '$NET_NAME' (destroy + undefine)? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }

virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
virsh net-undefine "$NET_NAME" >/dev/null 2>&1 || true
reg_rm_net "$NET_NAME"
rm -f "$STATE_DIR/$NET_NAME.xml"

echo "[OK] Retea '$NET_NAME' stearsa."
