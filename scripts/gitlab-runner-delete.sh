#!/usr/bin/env bash
# =============================================================================
# gitlab-runner-delete.sh - Stergere completa GitLab Runner de pe o VM
# Listeaza DOAR VM-urile configurate ca GitLab Runner, cere selectia si
# dezinstaleaza runnerul (serviciu, pachet, binare, config, user) astfel incat
# VM-ul sa poata fi reconfigurat cu optiunea 8.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SSH_USER="${SSH_USER:-ubuntu}"

echo "=== Stergere GitLab Runner ==="
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
    exit 0
fi

echo "Alege VM-ul de pe care se sterge GitLab Runner:"
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
read -r -p "Confirmare stergere GitLab Runner de pe '$VM_NAME' ($VM_IP)? (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "Anulat."; exit 0; }

echo
echo "[INFO] Dezinstalare GitLab Runner pe $VM_NAME ($VM_IP)..."
echo

# Heredoc CU apostrofe ('REMOTE_EOF'): se expandeaza doar pe VM.
ssh -t "$SSH_USER@$VM_IP" \
    "VM_NAME='$VM_NAME' VM_IP='$VM_IP' SSH_USER='$SSH_USER' bash -s" << 'REMOTE_EOF'
set +u

echo ">>> 1/5: Oprire si eliminare serviciu"
sudo gitlab-runner stop 2>/dev/null || true
sudo systemctl stop gitlab-runner 2>/dev/null || true
sudo systemctl disable gitlab-runner 2>/dev/null || true
sudo gitlab-runner uninstall 2>/dev/null || true
sudo systemctl reset-failed gitlab-runner 2>/dev/null || true
sudo rm -f /etc/systemd/system/gitlab-runner.service
sudo rm -rf /etc/systemd/system/gitlab-runner.service.d
sudo systemctl daemon-reload

echo ">>> 2/5: Purge pachet gitlab-runner"
if dpkg -s gitlab-runner >/dev/null 2>&1; then
    sudo apt-get purge -y gitlab-runner
else
    echo "  (pachetul nu este instalat prin apt)"
fi
sudo apt-get autoremove -y >/dev/null 2>&1 || true

echo ">>> 3/5: Stergere binare si configuratie"
sudo pkill -f gitlab-runner 2>/dev/null || true
sudo rm -f /usr/bin/gitlab-runner /usr/local/bin/gitlab-runner
sudo rm -rf /etc/gitlab-runner /var/lib/gitlab-runner /home/gitlab-runner

echo ">>> 4/5: Stergere utilizator gitlab-runner"
if id gitlab-runner >/dev/null 2>&1; then
    sudo userdel gitlab-runner 2>/dev/null || true
fi

echo ">>> 5/5: Verificare"
if command -v gitlab-runner >/dev/null 2>&1 || sudo -n test -f /etc/gitlab-runner/config.toml; then
    echo "[FAIL] GitLab Runner inca este prezent pe VM."
    exit 1
fi
echo "[OK] GitLab Runner a fost eliminat complet de pe $VM_NAME ($VM_IP)."
echo "     VM-ul poate fi reconfigurat cu optiunea 8."
echo "     Nota: sterge runner-ul si din GitLab UI daca mai apare (Settings > CI/CD > Runners)."
REMOTE_EOF

echo
echo "[OK] GitLab Runner sters de pe $VM_NAME ($VM_IP)."
