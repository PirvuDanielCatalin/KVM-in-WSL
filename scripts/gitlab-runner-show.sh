#!/usr/bin/env bash
# =============================================================================
# gitlab-runner-show.sh — Vizualizare GitLab Runner pe VM existenta
# Listeaza DOAR VM-urile configurate ca GitLab Runner (verificat prin SSH)
# si afiseaza datele runner-ului (echivalentul PAS 10 din config).
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SSH_USER="${SSH_USER:-ubuntu}"

echo "=== Vizualizare GitLab Runner ==="
echo

if [ ! -s "$REGISTRY" ]; then
    echo "[INFO] Nicio VM inregistrata in registry. Creeati mai intai una (opt. 5)."
    exit 0
fi

declare -a RUNNER_VMS=()
declare -a RUNNER_IPS=()

while IFS='|' read -r vm_name _ _ _ _ vm_ip _ _; do
    [ -z "$vm_name" ] && continue
    [ -z "$vm_ip" ] && continue

    if is_gitlab_runner "$vm_ip"; then
        RUNNER_VMS+=("$vm_name")
        RUNNER_IPS+=("$vm_ip")
        echo "  [runner] $vm_name ($vm_ip)"
    fi
done < "$REGISTRY"

echo

if [ ${#RUNNER_VMS[@]} -eq 0 ]; then
    echo "[INFO] Nicio VM nu este configurata ca GitLab Runner."
    echo "       Folositi optiunea 8 pentru a configura una."
    exit 0
fi

echo "Alege VM-ul:"
for i in "${!RUNNER_VMS[@]}"; do
    echo "  $((i + 1))) ${RUNNER_VMS[$i]} (${RUNNER_IPS[$i]})"
done
read -r -p "Alegere [1-${#RUNNER_VMS[@]}]: " SELECTION
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#RUNNER_VMS[@]}" ]; then
    echo "[FAIL] Selectare invalida." >&2
    exit 1
fi
idx=$((SELECTION - 1))

VM_NAME="${RUNNER_VMS[$idx]}"
VM_IP="${RUNNER_IPS[$idx]}"

echo
echo "[INFO] Citire date runner de pe $VM_NAME ($VM_IP)..."
echo

# Heredoc CU apostrofe ('REMOTE_EOF'): se expandeaza doar pe VM.
# VM_NAME / VM_IP / SSH_USER sunt pasate ca env pe linia ssh.
ssh -t "$SSH_USER@$VM_IP" \
    "VM_NAME='$VM_NAME' VM_IP='$VM_IP' SSH_USER='$SSH_USER' bash -s" << 'REMOTE_EOF'
set +u

echo "============================================================"
echo "=== Date Runner — $VM_NAME ($VM_IP) ==="
RUNNER_CFG=/etc/gitlab-runner/config.toml
if ! sudo -n test -f "$RUNNER_CFG"; then
    echo "[FAIL] $RUNNER_CFG nu exista pe aceasta VM."
    exit 1
fi
RUNNER_NAME=$(sudo awk -F' *= *' '/^ *name = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_ID=$(sudo awk -F' *= *' '/^ *id = /{print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_URL_CFG=$(sudo awk -F' *= *' '/^ *url = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_EXEC=$(sudo awk -F' *= *' '/^ *executor = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_CONC=$(sudo awk -F' *= *' '/^concurrent =/{print $2}' "$RUNNER_CFG" | head -1)
RUNNER_TAGS=$(sudo awk -F' *= *' '/^ *tag_list = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)

echo "  Nume:        ${RUNNER_NAME:-$VM_NAME-gitlab-runner}"
echo "  ID:          ${RUNNER_ID:-?}"
echo "  URL:         ${RUNNER_URL_CFG:-?}"
echo "  Executor:    ${RUNNER_EXEC:-?}"
if [ -n "$RUNNER_TAGS" ]; then
    echo "  Tag-uri:     $RUNNER_TAGS"
else
    echo "  Tag-uri:     ${RUNNER_TAGS_DEFAULT:-confluence-export, confluence-export-ui}"
    echo "               (setate in GitLab UI: ${RUNNER_URL_CFG:-<url>} → CI/CD > Runners > ${RUNNER_NAME:-$VM_NAME-gitlab-runner} > Edit)"
fi
echo "  Concurenta:  ${RUNNER_CONC:-1} (un job Docker la un timp)"
echo "  Descriere:   ${RUNNER_NAME:-$VM_NAME-gitlab-runner}"
echo "  SSH:         ssh $SSH_USER@$VM_IP"
echo "============================================================"
REMOTE_EOF

echo
echo "[OK] Date runner afisate pentru $VM_NAME ($VM_IP)"
