#!/usr/bin/env bash
# =============================================================================
# gitlab-runner-config.sh — Configureaza GitLab Runner pe o VM existenta
# Intraba: nume VM (din registry), URL GitLab, registration token
# Listeaza doar VM-urile care NU sunt deja GitLab Runners (verificat prin SSH).
# Face SSH automat pe VM, instaleaza Docker + unelte de scan + GitLab Runner,
# inregistreaza runner-ul cu tag-urile premdava-export si premdava-export-ui
# si activeaza concurenta = 1 (sigur pentru Docker daemon unic).
#
# Default-uri: URL GitLab si registration token se preiau din variabilele de
# mediu $GITLAB_URL si $GITLAB_TOKEN daca sunt setate; altfel sunt obligatorii
# de la tastatura. Apasarea ENTER pastreaza valoarea din mediu.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SSH_USER="${SSH_USER:-ubuntu}"

echo "=== Configure GitLab Runner ==="
echo

# --- Verificare: exista vreuna VM inregistrata? ---------------------------
if [ ! -s "$REGISTRY" ]; then
    echo "[INFO] Nicio VM inregistrata in registry. Creeati mai intai una (opt. 5)."
    exit 0
fi

# --- Functie: verifica prin SSH daca VM-ul e deja GitLab Runner -------------
is_gitlab_runner() {
    local ip=$1
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_USER@$ip" \
        "command -v gitlab-runner >/dev/null 2>&1 && [ -f /etc/gitlab-runner/config.toml ]" \
        >/dev/null 2>&1
}

# --- Colectare VM-uri care nu sunt GitLab Runners ---------------------------
declare -a ELIGIBLE_VMS=()
declare -a ELIGIBLE_IPS=()

while IFS='|' read -r vm_name _ _ _ _ vm_ip _ _; do
    [ -z "$vm_name" ] && continue
    [ -z "$vm_ip" ] && continue

    if is_gitlab_runner "$vm_ip"; then
        echo "  [sarire] $vm_name ($vm_ip) e deja GitLab Runner"
    else
        ELIGIBLE_VMS+=("$vm_name")
        ELIGIBLE_IPS+=("$vm_ip")
        echo "  [disponibil] $vm_name ($vm_ip)"
    fi
done < "$REGISTRY"

echo

if [ ${#ELIGIBLE_VMS[@]} -eq 0 ]; then
    echo "[INFO] Toate VM-urile inregistrate sunt deja GitLab Runners."
    echo "       Daca vrei sa reconfiguri una, stergi mai intai runner-ul de pe VM."
    exit 0
fi

# --- Selectare VM -----------------------------------------------------------
echo "Alege una dintre VM-urile disponibile:"
for i in "${!ELIGIBLE_VMS[@]}"; do
    echo "  $((i + 1))) ${ELIGIBLE_VMS[$i]} (${ELIGIBLE_IPS[$i]})"
done
echo
read -r -p "Alegere [1-${#ELIGIBLE_VMS[@]}]: " SELECTION
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#ELIGIBLE_VMS[@]}" ]; then
    echo "[FAIL] Selectare invalida." >&2
    exit 1
fi

idx=$((SELECTION - 1))
VM_NAME="${ELIGIBLE_VMS[$idx]}"
VM_IP="${ELIGIBLE_IPS[$idx]}"

echo
echo "[INFO] VM selectat: $VM_NAME ($VM_IP)"
echo

# --- Date GitLab: default din mediu, obligatoriu din tastatura daca lipsește --
if [ -n "${GITLAB_URL:-}" ]; then
    read -r -p "URL GitLab [$GITLAB_URL]: " GITLAB_URL_INPUT
    GITLAB_URL="${GITLAB_URL_INPUT:-$GITLAB_URL}"
else
    read -r -p "URL GitLab (ex. https://gitlab.com/): " GITLAB_URL
    [ -n "$GITLAB_URL" ] || { echo "[FAIL] URL GitLab obligatoriu." >&2; exit 1; }
fi
[ -n "$GITLAB_URL" ] || { echo "[FAIL] URL GitLab obligatoriu." >&2; exit 1; }

if [ -n "${GITLAB_TOKEN:-}" ]; then
    read -r -p "Authentication token [$GITLAB_TOKEN]: " GITLAB_TOKEN_INPUT
    GITLAB_TOKEN="${GITLAB_TOKEN_INPUT:-$GITLAB_TOKEN}"
else
    read -r -p "Authentication token: " GITLAB_TOKEN
    [ -n "$GITLAB_TOKEN" ] || { echo "[FAIL] Authentication token obligatoriu." >&2; exit 1; }
fi
[ -n "$GITLAB_TOKEN" ] || { echo "[FAIL] Authentication token obligatoriu." >&2; exit 1; }

echo
echo "[INFO] Se configureaza GitLab Runner pe $VM_NAME ($VM_IP)..."

# --- Executie pe VM via SSH (fara flag de cheie, cheia default e id_rsa) ---
# Heredoc NEinchis: $GITLAB_URL, $GITLAB_TOKEN, $VM_NAME, $VM_IP se extind local
# (valori cunoscute la momentul rularii). Comenzile specifice remote
# ($(dpkg ...), $(lsb_release ...)) sunt escapse cu backslash ca sa se extinda
# pe VM, nu local. GITLEAKS_VERSION e hardcodat (constanta).
# set -e (fara set -x): oprire la eroare, fara tracerea fiecarei comenzi in log;
# vizibile sunt doar anteturile >>> PAS X/10:.
# Initializare $1 ca gol pentru a evita 'unbound variable' cu set -u local:
# heredoc-ul << REMOTE_EOF (fara apostrofe) este parsat local si orice referinta
# la $1 nedefinita eșuează aici. Scriptul nu primeste argumente posizionale.
set -- "${1:-}"
# Dezactiveaza set -u local inainte de heredoc: << REMOTE_EOF (fara apostrofe)
# este parsat local si orice variabile nedefinita in conținutul remote
# (de ex. $1 in definiția funcției get_version) eșuează cu set -u.
set +u
ssh -t "$SSH_USER@$VM_IP" << REMOTE_EOF
set -e
# Dezactiveaza set -u in sesiunea remote: remote shell poate avea set -u din .bashrc,
# iar $1 (fara argumente pasate la ssh) ar provoca 'unbound variable'.
set +u

export DEBIAN_FRONTEND=noninteractive

# Curatare liste de surse corupte de la rulari anterioare (evita 'Malformed entry')
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/trivy.list 2>/dev/null || true

# 1. Docker CE (necesar de job-urile docker_build / docker_push / trivy_image_scan)
echo ">>> PAS 1/10: Instalare Docker CE"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 2. Python + git (necesar de job-urile python_test / python_unit_tests)
echo ">>> PAS 2/10: Instalare Python + git"
sudo apt-get install -y python3 python3-pip python3-venv git

# 3. Unelte de scanare (bandit, flake8, semgrep, trufflehog)
echo ">>> PAS 3/10: Instalare unelte de scanare Python"
# Ubuntu 26.04 are PEP 668 (externally managed environment) -> --break-system-packages
pip3 install --break-system-packages bandit flake8 semgrep trufflehog

# 4. Gitleaks (binar Go, nu e pe PyPI) — descarcare de la GitHub Releases
echo ">>> PAS 4/10: Instalare gitleaks"
curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v8.18.2/gitleaks_8.18.2_linux_x64.tar.gz" \
    | sudo tar -xz -C /usr/local/bin gitleaks
sudo chmod +x /usr/local/bin/gitleaks

# 5. Trivy (necesar de trivy_dockerfile_scan in pipeline-ul UI)
echo ">>> PAS 5/10: Instalare trivy"
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/trivy.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/trivy.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y trivy

# 6. GitLab Runner
echo ">>> PAS 6/10: Instalare GitLab Runner"
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash
sudo apt-get install -y gitlab-runner

# 7. Utilizatorul gitlab-runner trebuie sa aiba acces la Docker daemon
echo ">>> PAS 7/10: Adaugare gitlab-runner in grupul docker"
sudo usermod -aG docker gitlab-runner

# 8. Registrare runner (executor shell).
#    CU token de autentificare, GitLab interzice --tag-list, --locked,
#    --run-untagged etc. pe linia de comanda: ele se configureaza pe server.
#    --non-interactive este obligatoriu pentru a evita prompt-urile interactiv
#    (URL, nume, executor) care ar consuma liniile urmatore din heredoc.
#    Daca config.toml contine deja 'concurrent = ...' (de la o rulare veche),
#    register paniceaza -> il stergem inainte.
echo ">>> PAS 8/10: Inregistrare runner GitLab"
# Sterge linia 'concurrent' din config.toml (daca exista) pentru a evita panicul
# la register: GitLab interzice cheia duplicata. Se face cu sudo pentru ca
# ubuntu nu are citire directa pe /etc/gitlab-runner/config.toml.
sudo sed -i '/^concurrent =/d' /etc/gitlab-runner/config.toml 2>/dev/null || true
sudo gitlab-runner register \
  --url "$GITLAB_URL" \
  --token "$GITLAB_TOKEN" \
  --executor "shell" \
  --description "$VM_NAME-gitlab-runner" \
  --non-interactive

# 9. Siguranta concurenta: un singur job Docker la un timp pe acest daemon unic
echo ">>> PAS 9/10: Setare concurenta = 1 + pornire serviciu"
if sudo grep -q '^concurrent =' /etc/gitlab-runner/config.toml; then
    sudo sed -i 's/^concurrent = .*/concurrent = 1/' /etc/gitlab-runner/config.toml
else
    sudo sed -i '1i concurrent = 1' /etc/gitlab-runner/config.toml
fi

# Pornire serviciu + activare la boot.
# Daca serviciul exista deja (rulare veche), 'install' esueaza cu
# 'Init already exists' -> il stergem mai intai.
# 'gitlab-runner enable' nu exista ca comanda -> se foloseste systemctl enable.
sudo gitlab-runner stop 2>/dev/null || true
sudo gitlab-runner uninstall 2>/dev/null || true
sudo gitlab-runner install --user gitlab-runner
sudo systemctl enable gitlab-runner 2>/dev/null || true
sudo gitlab-runner start

# 10. Afișare versiunile tuturor tool-urilor instalate (verificare finală)
# Setează PATH explicit: sesiunea SSH non-login nu are PATH complet,
# iar uneltele pip3 stau în ~/.local/bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"

echo ">>> PAS 10/10: Afișare versiuni tool-uri instalate"
echo "============================================================"

# Helper: capturează outputul, returnează prima linie sau "nesiguran".
# set +e / set -e în jurul capturii pentru a nu opri execuția la "command not found".
show_ver() {
    local cmd="$1" out
    set +e
    out=$(eval "$cmd" 2>&1)
    set -e
    if [ -z "$out" ]; then
        echo "nesiguran"
    else
        echo "$out" | head -1
    fi
}

echo "GitLab Runner:"
show_ver "sudo gitlab-runner --version 2>/dev/null || sudo gitlab-runner version 2>/dev/null || true"
echo
echo "Docker:"
show_ver "docker --version 2>&1 || true"
echo
echo "Docker Compose:"
show_ver "docker compose version 2>&1 || true"
echo
echo "Python:"
show_ver "python3 --version 2>&1 || true"
echo
echo "Pip:"
show_ver "pip3 --version 2>&1 || true"
echo
echo "Git:"
show_ver "git --version 2>&1 || true"
echo
echo "Unelte de scanare:"
echo -n "  bandit:    "; show_ver "bandit --version 2>&1 || bandit -v 2>&1 || python3 -m bandit --version 2>&1 || true"
echo -n "  flake8:    "; show_ver "flake8 --version 2>&1 || flake8 -V 2>&1 || true"
echo -n "  semgrep:   "; show_ver "semgrep --version 2>&1 || true"
echo -n "  trufflehog: "; show_ver "trufflehog --version 2>&1 || trufflehog version 2>&1 || true"
echo -n "  gitleaks:  "; show_ver "gitleaks version 2>&1 || gitleaks --version 2>&1 || true"
echo -n "  trivy:     "; show_ver "trivy --version 2>&1 || true"
echo "============================================================"
echo -n "  trufflehog: "; get_version "trufflehog --version 2>&1 || trufflehog version 2>&1"
echo -n "  gitleaks:  "; get_version "gitleaks version 2>&1 || gitleaks --version 2>&1"
echo -n "  trivy:     "; get_version "trivy --version 2>&1"
echo "============================================================"

echo "[OK] GitLab Runner configurat pe $VM_NAME ($VM_IP)"
REMOTE_EOF

echo
echo "[OK] GitLab Runner configurat cu succes pe $VM_NAME ($VM_IP)."
echo "     Executor: shell"
echo "     Tag-uri: premdava-export, premdava-export-ui"
echo "              ^^^ setale manual in GitLab UI (CI/CD > Runners > $VM_NAME-gitlab-runner > Edit)"
echo "              (cu token de autentificare, tag-urile nu pot fi setate de la linia de comanda)"
echo "     Concurenta: 1 (un job Docker la un timp)"
echo "     SSH: ssh $SSH_USER@$VM_IP"
