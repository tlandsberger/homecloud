#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/tlandsberger/homecloud.git"
REPO_DIR="$HOME/homecloud"

echo "=== Homecloud Init ==="
echo ""

# --- Repository ---
if [[ -d "$REPO_DIR/.git" ]]; then
    echo "Repository bereits vorhanden, aktualisiere..."
    git -C "$REPO_DIR" pull --ff-only
else
    echo "Repository klonen..."
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# --- Ansible installieren ---
if ! command -v ansible-playbook &>/dev/null; then
    echo "Ansible installieren..."
    sudo apt update && sudo apt install -y ansible
else
    echo "Ansible bereits installiert."
fi

# --- Ansible Collections ---
echo "Ansible Collections installieren..."
ansible-galaxy collection install -r host/requirements.yml

# --- Partitionsauswahl ---
mapfile -t partitions < <(lsblk -rno NAME,FSTYPE,UUID,SIZE,MOUNTPOINT 2>/dev/null | awk '$3 != ""')

pick_partition() {
    echo "" >&2
    echo "$1" >&2
    local options=()
    for line in "${partitions[@]}"; do
        read -r name fstype uuid size mountpoint <<< "$line"
        options+=("$name  ${size}  ${fstype}  UUID=${uuid}  ${mountpoint}")
    done
    local PS3="Auswahl: "
    select opt in "${options[@]}" "Überspringen"; do
        if [[ "$REPLY" -le "${#partitions[@]}" ]] 2>/dev/null; then
            echo "${partitions[$((REPLY - 1))]}" | awk '{print $3}'
            return
        fi
        echo ""; return
    done
}

docker_uuid=$(pick_partition "Docker-Partition (wird unter /var/lib/docker gemountet):")
media_uuid=$(pick_partition "Media-Partition (wird unter /mnt/media gemountet):")

# --- Playbook ausführen ---
echo ""
echo "Playbook starten..."
ansible-playbook host/playbook.yml \
    -e "docker_uuid=${docker_uuid}" \
    -e "media_uuid=${media_uuid}"
