#!/usr/bin/env bash
# =============================================================================
# network-create.sh - Configurare retea in libvirt
# Intraba: nume retea + CIDR -> genereaza XML + virsh net-define/start/autostart
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== 2) Configurare retea in libvirt ==="
echo

kvm_preflight >/dev/null 2>&1 || true

read -r -p "Nume retea libvirt (ex. lab-privata): " NET_NAME
[ -n "$NET_NAME" ] || { echo "[FAIL] Numele retelei este obligatoriu." >&2; exit 1; }

# Daca exista deja in libvirt, anunzam
if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
    echo "[WARN] Retea '$NET_NAME' exista deja in libvirt."
    read -r -p "Continuare suprascris? (y/N): " c
    [[ "$c" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }
fi

read -r -p "CIDR retea (ex. 192.168.100.0/24): " CIDR
[ -n "$CIDR" ] || { echo "[FAIL] CIDR obligatoriu." >&2; exit 1; }

# Validare CIDR simplu
if ! [[ "$CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "[FAIL] CIDR invalid: $CIDR" >&2; exit 1
fi

read -r network broadcast prefix mask first last netmask <<< "$(parse_cidr "$CIDR")"

DEFAULT_GW=$(int2ip "$first")
DEFAULT_DHCP_START=$(int2ip $(( first + 9 )))   # .10 de obicei
if [ "$DEFAULT_DHCP_START" = "$(int2ip $(( last + 1 )))" ]; then DEFAULT_DHCP_START=$DEFAULT_GW; fi
DEFAULT_DHCP_END=$(int2ip "$last")

read -r -p "Gateway IP (default $DEFAULT_GW): " GATEWAY
GATEWAY="${GATEWAY:-$DEFAULT_GW}"
read -r -p "DHCP start (default $DEFAULT_DHCP_START): " DHCP_START
DHCP_START="${DHCP_START:-$DEFAULT_DHCP_START}"
read -r -p "DHCP end (default $DEFAULT_DHCP_END): " DHCP_END
DHCP_END="${DHCP_END:-$DEFAULT_DHCP_END}"

BRIDGE="virbr-$NET_NAME"

echo
echo "Retea: $NET_NAME | CIDR: $CIDR | Bridge: $BRIDGE"
echo "Gateway: $GATEWAY/$netmask | DHCP: $DHCP_START - $DHCP_END"
read -r -p "Creare retea? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }

# Generare XML din template
sed -e "s/__NET_NAME__/$NET_NAME/" \
    -e "s/__BRIDGE__/$BRIDGE/" \
    -e "s/__GATEWAY__/$GATEWAY/" \
    -e "s/__NETMASK__/$netmask/" \
    -e "s|__DHCP_START__|$DHCP_START|" \
    -e "s|__DHCP_END__|$DHCP_END|" \
    "$TEMPLATES_DIR/network.xml.tmpl" > "$STATE_DIR/$NET_NAME.xml"

XML_FILE="$STATE_DIR/$NET_NAME.xml"

virsh net-define "$XML_FILE" || { echo "[FAIL] net-define esuat"; exit 1; }
virsh net-start "$NET_NAME"    || { echo "[FAIL] net-start esuat"; exit 1; }
virsh net-autostart "$NET_NAME" >/dev/null 2>&1 || true

# Inregistrare in retea-uri create
if ! net_registered "$NET_NAME"; then
    NOW=$(date +%s)
    reg_add_net "$NET_NAME|$CIDR|$GATEWAY|$netmask|$DHCP_START|$DHCP_END|$BRIDGE|$NOW"
fi

echo "[OK] Retea '$NET_NAME' definita, pornita si setata pe autostart."
echo "     Verificare: virsh -c qemu:///system net-list --all"
echo "     Detalii:    virsh -c qemu:///system net-dumpxml $NET_NAME"
