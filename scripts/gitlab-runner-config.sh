#!/usr/bin/env bash
# =============================================================================
# gitlab-runner-config.sh — Configureaza GitLab Runner pe o VM existenta
# Intraba: nume VM (din registry), URL GitLab, registration token
# Listeaza doar VM-urile care NU sunt deja GitLab Runners (verificat prin SSH).
# Face SSH automat pe VM, instaleaza Docker + unelte de scan + GitLab Runner,
# inregistreaza runner-ul cu tag-urile confluence-export si confluence-export-ui
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

# --- Verificare: VM-ul e deja GitLab Runner? (functie partajata din lib.sh) ---

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
# Heredoc CU apostrofe ('REMOTE_EOF'): continutul NU se expandeaza local.
# Toate $(...), $?, $HOME si variabilele de stare se evalueaza pe VM.
# Variabilele necesare remote (GITLAB_URL, GITLAB_TOKEN, VM_NAME, VM_IP, SSH_USER)
# sunt pasate ca prefix env pe linia de comanda ssh; `bash -s` le citeste din mediu.
ssh -t "$SSH_USER@$VM_IP" \
    "GITLAB_URL='$GITLAB_URL' GITLAB_TOKEN='$GITLAB_TOKEN' VM_NAME='$VM_NAME' VM_IP='$VM_IP' SSH_USER='$SSH_USER' bash -s" << 'REMOTE_EOF'
set -e
# Dezactiveaza set -u in sesiunea remote (unele .bashrc-uri il activeaza).
set +u

export DEBIAN_FRONTEND=noninteractive

# Curatare liste de surse corupte de la rulari anterioare (evita 'Malformed entry')
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/trivy.list 2>/dev/null || true

# 1. Docker CE (necesar de job-urile docker_build / docker_push / trivy_image_scan)
echo ">>> PAS 1/10: Instalare Docker CE"
sudo apt-get update -y
sudo apt-get upgrade -y
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

# 3. Unelte de scanare (bandit, flake8, semgrep — pip; trufflehog — binar Go)
echo ">>> PAS 3/10: Instalare unelte de scanare"
# Ubuntu 26.04 are PEP 668 (externally managed environment) -> --break-system-packages
pip3 install --break-system-packages bandit flake8 semgrep
# TruffleHog v3 este un binar Go. Pachetul PyPI 'trufflehog' este vechiul 2.x
# (Python) si crapa cu Traceback pe Python 3.14 -> il eliminam daca exista,
# apoi instalăm binarul oficial de la trufflesecurity.
pip3 uninstall -y trufflehog --break-system-packages 2>/dev/null || true
curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sudo sh -s -- -b /usr/local/bin

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
# Elimina intrările [[runners]] vechi: fiecare reînregistrare adaugă o secțiune
# nouă, iar config.toml crește necontrolat (același runner id se repetă).
if sudo test -f /etc/gitlab-runner/config.toml; then
    sudo awk '/^\[\[runners\]\]/{exit} {print}' /etc/gitlab-runner/config.toml \
        | sudo tee /etc/gitlab-runner/config.toml.tmp > /dev/null
    sudo mv /etc/gitlab-runner/config.toml.tmp /etc/gitlab-runner/config.toml
fi
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

echo "GitLab Runner:"
set +e
VER=$(gitlab-runner --version 2>&1)
RC=$?
if [ $RC -ne 0 ]; then
    VER=$(gitlab-runner version 2>&1)
fi
set -e
if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo
echo "Docker:"
set +e
VER=$(docker --version 2>&1)
set -e
if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo
echo "Docker Compose:"
set +e
VER=$(docker compose version 2>&1)
set -e
if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo
echo "Python:"
set +e
VER=$(python3 --version 2>&1)
set -e
if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo
echo "Pip:"
set +e
VER=$(pip3 --version 2>&1)
set -e
if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo
echo "Git:"
set +e
VER=$(git --version 2>&1)
set -e
if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo
echo "Unelte de scanare:"
echo -n "  bandit:    "; set +e; VER=$(bandit --version 2>&1); [ $? -ne 0 ] && VER=$(bandit -v 2>&1); [ -z "$VER" ] && VER=$(python3 -m bandit --version 2>&1); set -e; if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo -n "  flake8:    "; set +e; VER=$(flake8 --version 2>&1); [ $? -ne 0 ] && VER=$(flake8 -V 2>&1); set -e; if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo -n "  semgrep:   "; set +e; VER=$(semgrep --version 2>&1); set -e; if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo -n "  trufflehog: "; set +e; VER=$(trufflehog --version 2>&1); [ $? -ne 0 ] && VER=$(trufflehog version 2>&1); set -e; if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo -n "  gitleaks:  "; set +e; VER=$(gitleaks version 2>&1); [ $? -ne 0 ] && VER=$(gitleaks --version 2>&1); set -e; if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
echo -n "  trivy:     "; set +e; VER=$(trivy --version 2>&1); set -e; if [ -z "$VER" ]; then echo "nesiguran"; else echo "$VER" | head -1; fi
# Rezumat final: datele REALE ale runner-ului, citite din config.toml
RUNNER_CFG=/etc/gitlab-runner/config.toml
RUNNER_NAME=$(sudo awk -F' *= *' '/^ *name = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_ID=$(sudo awk -F' *= *' '/^ *id = /{print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_URL_CFG=$(sudo awk -F' *= *' '/^ *url = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_EXEC=$(sudo awk -F' *= *' '/^ *executor = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)
RUNNER_CONC=$(sudo awk -F' *= *' '/^concurrent =/{print $2}' "$RUNNER_CFG" | head -1)
RUNNER_TAGS=$(sudo awk -F' *= *' '/^ *tag_list = /{gsub(/"/,"",$2); print $2}' "$RUNNER_CFG" | tail -1)

echo "============================================================"
echo "=== Date Runner ==="
echo "  Nume:        ${RUNNER_NAME:-$VM_NAME-gitlab-runner}"
echo "  ID:          ${RUNNER_ID:-?}"
echo "  URL:         ${RUNNER_URL_CFG:-$GITLAB_URL}"
echo "  Executor:    ${RUNNER_EXEC:-shell}"
if [ -n "$RUNNER_TAGS" ]; then
    echo "  Tag-uri:     $RUNNER_TAGS"
else
    echo "  Tag-uri:     ${RUNNER_TAGS_DEFAULT:-confluence-export, confluence-export-ui}"
    echo "               (setate in GitLab UI: $GITLAB_URL → CI/CD > Runners > ${RUNNER_NAME:-$VM_NAME-gitlab-runner} > Edit)"
fi
echo "  Concurenta:  ${RUNNER_CONC:-1} (un job Docker la un timp)"
echo "  Descriere:   $VM_NAME-gitlab-runner"
echo "  SSH:         ssh $SSH_USER@$VM_IP"
echo "============================================================"

echo "[OK] GitLab Runner configurat pe $VM_NAME ($VM_IP)"
REMOTE_EOF
