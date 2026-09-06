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

echo "=== 1. Updating and upgrading Termux packages ==="
pkg upgrade -y || (apt-get update -y && apt-get upgrade -y)

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
mkdir -p "$HOME/storage/shared/.backups" "$HOME/.backups"
for bdir in "$HOME/storage/shared/.backups" "$HOME/.backups"; do
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

echo "=== 8. Configuring and starting automated cron job ==="
BASH_PATH="$(command -v bash || echo "${PREFIX:-/data/data/com.termux/files/usr}/bin/bash")"
CRON_ENTRY="*/5 * * * * $BASH_PATH $HOME/backup.sh >/dev/null 2>&1"

if command -v crontab >/dev/null 2>&1; then
    # Add cron job if not already present
    if ! crontab -l 2>/dev/null | grep -Fq "backup.sh"; then
        (crontab -l 2>/dev/null || true; echo "$CRON_ENTRY") | crontab -
        echo "Configured crontab to run backup.sh every 5 minutes."
    else
        echo "Cron job for backup.sh is already configured in crontab."
    fi
fi

# Ensure crond daemon is running in the background
if command -v crond >/dev/null 2>&1; then
    if ! pgrep -x "crond" >/dev/null 2>&1; then
        crond
        echo "Started crond daemon in the background."
    else
        echo "crond daemon is already running."
    fi
fi

echo "=== 9. Configuring auto-start on Termux launch and boot ==="
BASHRC="$HOME/.bashrc"
AUTOSTART_MARKER="# Pendrive Backup & Syncthing background services"

if ! grep -Fq "$AUTOSTART_MARKER" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" << 'EOF'

# Pendrive Backup & Syncthing background services
termux-wake-lock 2>/dev/null || true
pgrep -x "crond" >/dev/null 2>&1 || crond
pgrep -x "syncthing" >/dev/null 2>&1 || nohup syncthing --no-browser --no-restart > "$HOME/.logs/syncthing.log" 2>&1 &
EOF
    echo "Added auto-start hook to ~/.bashrc (starts crond & Syncthing whenever Termux opens)."
fi

# Configure Termux:Boot script (runs on device reboot if Termux:Boot app is installed)
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/start-backup-services.sh" << 'EOF'
#!/usr/bin/env bash
termux-wake-lock 2>/dev/null || true
pgrep -x "crond" >/dev/null 2>&1 || crond
pgrep -x "syncthing" >/dev/null 2>&1 || nohup syncthing --no-browser --no-restart > "$HOME/.logs/syncthing.log" 2>&1 &
EOF
chmod +x "$HOME/.termux/boot/start-backup-services.sh"
if command -v termux-fix-shebang >/dev/null 2>&1; then
    termux-fix-shebang "$HOME/.termux/boot/start-backup-services.sh" 2>/dev/null || true
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
echo "  - Automated Cron Job: Active (scanning for pendrives every 5 minutes)"
echo "  - Termux Wake Lock:   Active (keeps CPU running when screen is locked)"
echo "  - Syncthing:          Running in background (browser auto-open disabled)"
echo "  - Syncthing Web UI:   http://127.0.0.1:8384"
echo ""
echo " Quick Commands:"
echo "  - Run backup now:     bash ~/backup.sh"
echo "  - Check cron status:  crontab -l"
echo "  - Pair Syncthing:     Open http://127.0.0.1:8384 in your phone browser and share ~/storage/shared/.backups"
echo ""
echo " Note: In Android Settings -> Apps -> Termux -> Battery, select 'Unrestricted'."
echo "=============================================================================="
