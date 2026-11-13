#!/usr/bin/env bash
# =============================================================================
# network-show.sh — Vizualizare detalii retea libvirt
# Intraba: nume retea (cerut interactiva)
# Afiseaza: informatii libvirt, XML, detalii din registry, lease-uri DHCP
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== Vizualizare retea libvirt ==="
echo

echo "Retele libvirt disponibile:"
virsh net-list --all 2>/dev/null | awk 'NR>2 {print "  "$1}' || true
echo

read -r -p "Nume retea: " NET_NAME
[ -n "$NET_NAME" ] || { echo "[FAIL] Nume obligatoriu." >&2; exit 1; }

if ! virsh net-info "$NET_NAME" >/dev/null 2>&1; then
    echo "[FAIL] Retea '$NET_NAME' nu exista in libvirt." >&2
    exit 1
fi

echo
echo "--- Informatii din libvirt ---"
virsh net-info "$NET_NAME"

echo
echo "--- XML retea ---"
virsh net-dumpxml "$NET_NAME"

# Detalii din registry (daca exista)
NET_CIDR=$(net_cidr_of "$NET_NAME" 2>/dev/null || true)
if [ -n "$NET_CIDR" ]; then
    echo
    echo "--- Detalii din registry wsl-kvm ---"
    awk -F'|' -v n="$NET_NAME" \
        '$1==n {printf "  CIDR: %s\n  Gateway: %s\n  Netmask: %s\n  DHCP: %s - %s\n  Bridge: %s\n", $2, $3, $4, $5, $6, $7}' \
        "$NET_REGISTRY"
fi

# Lease-uri DHCP
echo
echo "--- Lease-uri DHCP (daca reteaua ruleaza si are DHCP activ) ---"
virsh net-dhcp-leases "$NET_NAME" 2>/dev/null || echo "  (fara lease-uri sau reteaua nu ruleaza)"
