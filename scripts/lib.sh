#!/usr/bin/env bash
# =============================================================================
# lib.sh - helpers compartimentati pentru wsl-kvm
# Sursa de aici din orice script din scripts/ cu:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# =============================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATES_DIR="$PROJECT_DIR/templates"
STATE_DIR="${WSL_KVM_STATE_DIR:-$HOME/.infra-lab/wsl-kvm}"
VMS_DIR="$STATE_DIR/vms"
GOLDEN_DIR="$HOME/.infra-lab/golden-images"
REGISTRY="$STATE_DIR/registry"        # vm|os|ram_gb|cpu|net|ip|disk|created_at
NET_REGISTRY="$STATE_DIR/networks"   # net|cidr|gateway|netmask|dhcp_start|dhcp_end|bridge|created_at

mkdir -p "$STATE_DIR" "$VMS_DIR" "$GOLDEN_DIR"
touch "$REGISTRY" "$NET_REGISTRY" 2>/dev/null || true

VIRSH="${VIRSH:-virsh}"
VIRSH_URI="${VIRSH_URI:-qemu:///system}"
virsh() { command "$VIRSH" -c "$VIRSH_URI" "$@"; }

# ---------------------------------------------------------------------------
# CIDR math (fara dependente externe: ipcalc, etc.)
# ---------------------------------------------------------------------------
ip2int() {
    local IFS=.
    local ip=$1 a b c d
    read -r a b c d <<< "$ip"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}
int2ip() {
    local v=$1
    echo "$(( (v >> 24) & 255 )).$(( (v >> 16) & 255 )).$(( (v >> 8) & 255 )).$(( v & 255 ))"
}
parse_cidr() {
    # iesire: network broadcast prefix mask first_usable last_usable netmask
    local cidr="$1"
    local ip="${cidr%/*}" prefix="${cidr#*/}"
    local ipint mask network broadcast first last
    ipint=$(ip2int "$ip")
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    network=$(( ipint & mask ))
    broadcast=$(( network | (~mask & 0xFFFFFFFF) ))
    first=$(( network + 1 ))
    last=$(( broadcast - 1 ))
    echo "$network $broadcast $prefix $mask $first $last $(int2ip $mask)"
}
ip_in_cidr() {
    local ip=$1 cidr=$2
    local ipint net br first last
    ipint=$(ip2int "$ip")
    read -r net br _ _ first last _ <<< "$(parse_cidr "$cidr")"
    [ "$ipint" -ge "$net" ] && [ "$ipint" -le "$br" ] && [ "$ipint" -ne "$net" ] && [ "$ipint" -ne "$br" ]
}
cidr_first_usable() { read -r _ _ _ _ first _ _ <<< "$(parse_cidr "$1")"; int2ip $(( first + 1 )); }
cidr_last_usable()  { read -r _ _ _ _ _ last _ <<< "$(parse_cidr "$1")"; int2ip "$last"; }
cidr_netmask()      { read -r _ _ _ _ _ _ mask <<< "$(parse_cidr "$1")"; echo "$mask"; }

# ---------------------------------------------------------------------------
# Resurse WSL
# ---------------------------------------------------------------------------
wsl_mem_gb() { free -g | awk '/Mem:/ {print $2}'; }
wsl_cpu()    { nproc; }
wsl_mem_used_by_vms() {
    local total=0 v ram
    [ -f "$REGISTRY" ] || { echo 0; return; }
    while IFS='|' read -r vm os ram cpu _ _ _ _; do
        [ -n "$ram" ] && total=$(( total + ram ))
    done < "$REGISTRY"
    echo "$total"
}

# ---------------------------------------------------------------------------
# Utilizator Windows + cale .wslconfig (pe C: /mnt/c)
# ---------------------------------------------------------------------------
win_username() {
    local u
    u=$(powershell.exe -Command '$env:USERNAME' 2>/dev/null | tr -d '\r\n ')
    [ -n "$u" ] && { echo "$u"; return 0; }
    u=$(cmd.exe /c echo %USERNAME% 2>/dev/null | tr -d '\r\n ' | tail -n1)
    [ -n "$u" ] && { echo "$u"; return 0; }
    echo ""
}
wslconfig_path() {
    local u; u=$(win_username)
    if [ -n "$u" ]; then echo "/mnt/c/Users/$u/.wslconfig"; else echo ""; fi
}

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
reg_has_vm_on_net() {
    local net=$1
    [ -f "$REGISTRY" ] || return 1
    grep -qE "^[^|]+\|[^|]+\|[^|]+\|[^|]+\|${net}\|" "$REGISTRY" 2>/dev/null
}
reg_vm_exists() {
    local vm=$1
    [ -f "$REGISTRY" ] || return 1
    grep -qF "${vm}|" "$REGISTRY" 2>/dev/null
}
reg_add_vm() {
    # vm|os|ram_gb|cpu|net|ip|disk|created_at
    echo "$*" >> "$REGISTRY"
}
reg_rm_vm() {
    local vm=$1
    [ -f "$REGISTRY" ] || return 0
    grep -vF "${vm}|" "$REGISTRY" > "$REGISTRY.tmp" 2>/dev/null || true
    mv "$REGISTRY.tmp" "$REGISTRY"
}
net_registered() {
    local net=$1
    [ -f "$NET_REGISTRY" ] || return 1
    grep -qF "${net}|" "$NET_REGISTRY" 2>/dev/null
}
reg_add_net() {
    echo "$*" >> "$NET_REGISTRY"
}
reg_rm_net() {
    local net=$1
    [ -f "$NET_REGISTRY" ] || return 0
    grep -vF "${net}|" "$NET_REGISTRY" > "$NET_REGISTRY.tmp" 2>/dev/null || true
    mv "$NET_REGISTRY.tmp" "$NET_REGISTRY"
}
net_cidr_of() {
    local net=$1
    [ -f "$NET_REGISTRY" ] || return 1
    awk -F'|' -v n="$net" '$1==n {print $2; exit}' "$NET_REGISTRY"
}

# ---------------------------------------------------------------------------
# Preflight KVM
# ---------------------------------------------------------------------------
kvm_preflight() {
    local ok=1
    [ -e /dev/kvm ] || { echo "[FAIL] /dev/kvm lipseste - activeaza nestedVirtualization=true in .wslconfig si reporniti WSL"; ok=0; }
    groups | grep -qw kvm   || { echo "[WARN] utilizatorul nu e in grupul 'kvm' (QEMU va rula pe TCQ - lent)"; }
    groups | grep -qw libvirt || { echo "[WARN] utilizatorul nu e in grupul 'libvirt' (virsh cere sudo)"; }
    systemctl is-active --quiet libvirtd 2>/dev/null || { echo "[WARN] libvirtd nu ruleaza: sudo systemctl start libvirtd"; }
    return $ok
}

# ---------------------------------------------------------------------------
# Imagine de baza (golden) Ubuntu
# ---------------------------------------------------------------------------
golden_url() {
    case "$1" in
        24) echo "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img" ;;
        26) echo "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img" ;;
        *) echo "" ;;
    esac
}
find_golden() {
    local ver=$1 dir
    for dir in "$GOLDEN_DIR/ubuntu-$ver" "$GOLDEN_DIR/ubuntu" "$GOLDEN_DIR"; do
        [ -d "$dir" ] || continue
        local f; f=$(find "$dir" -maxdepth 1 \( -name '*.img' -o -name '*.qcow2' \) -type f 2>/dev/null | head -1)
        [ -n "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
ensure_golden() {
    local ver=$1
    local base; base=$(find_golden "$ver") && { echo "$base"; return 0; }
    echo "[INFO] Nu exista imagine de baza pentru Ubuntu $ver in $GOLDEN_DIR."
    read -r -p "Descarc automat imaginea cloud Ubuntu $ver? (y/N): " ans
    if [[ "$ans" =~ ^[yY]$ ]]; then
        local url; url=$(golden_url "$ver")
        local dest="$GOLDEN_DIR/ubuntu-$ver/ubuntu-cloud.img"
        mkdir -p "$(dirname "$dest")"
        if command -v wget >/dev/null 2>&1; then
            wget "$url" -O "$dest" || { echo "[FAIL] Descarcarea a esuat de la $url"; return 1; }
        elif command -v curl >/dev/null 2>&1; then
            curl -SL "$url" -o "$dest" || { echo "[FAIL] Descarcarea a esuat de la $url"; return 1; }
        else
            echo "[FAIL] Nu am wget/curl pentru descarcare."; return 1
        fi
        echo "$dest"
    else
        echo "[FAIL] Imaginea de baza este necesaria. Furnizati una manual sau raspundeti 'y' la download."; return 1
    fi
}

# ---------------------------------------------------------------------------
# MAC adresa derivata din ultimul octet al IP-ului (prefix QEMU 52:54:00)
# ---------------------------------------------------------------------------
mac_from_ip() {
    local ip="$1"
    local last="${ip##*.}"
    printf '52:54:00:00:00:%02X' "$(( 10#$last ))"
}

# ---------------------------------------------------------------------------
# Detectare GitLab Runner pe o VM (prin SSH)
# /etc/gitlab-runner este drwx------ root root -> test -f cere sudo
# ---------------------------------------------------------------------------
is_gitlab_runner() {
    local ip="$1"
    local user="${SSH_USER:-ubuntu}"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$ip" \
        "command -v gitlab-runner >/dev/null 2>&1 && sudo -n test -f /etc/gitlab-runner/config.toml" \
        >/dev/null 2>&1
}
