#!/usr/bin/env bash
# ==============================================================================
# Script Name: setup-backup.sh
# Description: Automated setup script for Termux USB pendrive backup system
#              with Syncthing integration, Wake Lock, and multi-part support.
# GitHub Repo: https://github.com/mahdi4261/backup-script
# ==============================================================================

set -e

REPO_RAW_URL="https://raw.githubusercontent.com/mahdi4261/backup-script/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "$HOME")"

echo "=============================================================================="
echo " Starting Pendrive Backup & Syncthing Setup"
echo "=============================================================================="

echo "=== 1. Updating Termux packages ==="
pkg update -y || apt-get update -y
pkg upgrade -y || apt-get upgrade -y

echo "=== 2. Installing dependencies ==="
pkg install curl wget zip bc openssl-tool cronie coreutils syncthing -y 2>/dev/null || \
  pkg install curl wget zip bc openssl cronie coreutils syncthing -y

echo "=== 3. Setting up Termux storage access ==="
echo "Please allow storage permissions if prompted by Android..."
termux-setup-storage 2>/dev/null || true

echo "=== 4. Preventing Android CPU sleep (Wake Lock) ==="
termux-wake-lock 2>/dev/null || true

echo "=== 5. Deploying scripts to Termux home ($HOME) ==="

deploy_file() {
    local file="$1"
    local dest="$HOME/$file"
    
    if [ -f "$SCRIPT_DIR/$file" ] && [ "$SCRIPT_DIR" != "$HOME" ]; then
        echo "Copying $file from local folder to $dest..."
        cp -f "$SCRIPT_DIR/$file" "$dest"
    else
        echo "Downloading $file from GitHub repository..."
        curl -fsSL "$REPO_RAW_URL/$file" -o "$dest" 2>/dev/null || \
          wget -qO "$dest" "$REPO_RAW_URL/$file" 2>/dev/null || {
            if [ -f "$dest" ]; then
                echo "Using existing $file in $HOME"
            else
                echo "Warning: Could not download $file from GitHub."
                return 1
            fi
        }
    fi
}

deploy_file "backup.sh"
chmod +x "$HOME/backup.sh"

deploy_file "restore.sh"
chmod +x "$HOME/restore.sh"

deploy_file "backup_public_key.pem" || true

# Fix shebangs for Termux environment
if command -v termux-fix-shebang >/dev/null 2>&1; then
    termux-fix-shebang "$HOME/backup.sh" "$HOME/restore.sh" 2>/dev/null || true
fi

echo "=== 6. Setting up Syncthing ignore rules (.stignore) ==="
mkdir -p "$HOME/storage/shared/Backups" "$HOME/Backups"
for bdir in "$HOME/storage/shared/Backups" "$HOME/Backups"; do
    if [ -d "$bdir" ]; then
        cat > "$bdir/.stignore" << 'EOF'
.tmp_*
.*.tmp
backup.lock
.nobackup
*.tmp
EOF
    fi
done

echo "=== 7. Starting Syncthing daemon in background (headless) ==="
mkdir -p "$HOME/.logs"
if ! pgrep -x "syncthing" >/dev/null 2>&1; then
    nohup syncthing --no-browser --no-restart > "$HOME/.logs/syncthing.log" 2>&1 &
    sleep 2
fi

echo "=============================================================================="
echo " Setup Completed Successfully!"
echo "=============================================================================="
echo " Installed files in: $HOME"
echo "  - $HOME/backup.sh          (USB pendrive backup script)"
echo "  - $HOME/restore.sh         (Multi-part restore & decryption utility)"
echo "  - $HOME/backup_public_key.pem (Public key certificate)"
echo ""
echo " Background Services:"
echo "  - Termux Wake Lock: Active (keeps CPU running when screen is locked)"
echo "  - Syncthing: Running in background (browser auto-open disabled)"
echo "  - Syncthing Web UI: http://127.0.0.1:8384"
echo ""
echo " Quick Commands:"
echo "  - Run backup now:   bash ~/backup.sh"
echo "  - Pair Syncthing:   Open http://127.0.0.1:8384 in your phone browser"
echo ""
echo " Note: In Android Settings -> Apps -> Termux -> Battery, select 'Unrestricted'."
echo "=============================================================================="
