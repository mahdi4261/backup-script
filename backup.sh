#!/usr/bin/env bash
# ==============================================================================
# Script Name: backup.sh
# Description: Automatically scans for connected USB pendrives, excludes the internal
#              storage and SD cards, verifies available space on the Android device,
#              compresses pendrive data into ~500MB split parts in dedicated per-drive
#              folders, supports public-key encryption, and keeps rotated logs.
# Target:      Termux (Android)
# ==============================================================================

set -o pipefail

# Configuration
BACKUP_DIR="$HOME/storage/shared/.backups"
LOG_DIR="$HOME/.logs"
LOG_FILE="$LOG_DIR/pendrive_backup.log"
MAX_LOG_SIZE=$((1 * 1024 * 1024)) # 1 MB in bytes

# Part split size (e.g. 500M for ~500 MB per part)
PART_SIZE="500M"

# 4 GB in 1K-blocks (4 * 1024 * 1024)
BUFFER_BLOCKS=$((4 * 1024 * 1024))

# Manual exclusions (optional list of UUIDs to ignore, e.g. ("AAAA-1111" "BBBB-2222"))
MANUAL_EXCLUDED_UUIDS=()

# Skip file: If a pendrive contains a file with this name at its root, it will be skipped.
# Set to empty "" to disable this check.
SKIP_FILE_NAME=".nobackup"

# Encryption settings
ENCRYPT_BACKUPS=false
PUBKEY_PATH="$HOME/backup_public_key.pem"

# Syncthing integration settings
ENABLE_SYNCTHING=true

# Lock file to prevent concurrent cron runs
LOCK_FILE="$LOG_DIR/backup.lock"

# ==============================================================================
# Function: log_msg
# Logs timestamped messages to stdout and the log file with size limit rotation.
# ==============================================================================
log_msg() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local entry="[$timestamp] [$level] $msg"
    
    # Print to standard output
    echo "$entry"
    
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"
    
    # Append to log file
    echo "$entry" >> "$LOG_FILE"
    
    # Rotate log file if it exceeds size limit
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(wc -c < "$LOG_FILE" | tr -d '[:space:]')
        if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            echo "[$timestamp] [INFO] Log rotated. Previous logs saved to ${LOG_FILE}.old." > "$LOG_FILE"
        fi
    fi
}

# ==============================================================================
# Function: get_avail_blocks
# Gets the available space of a directory in 1K-blocks using df.
# ==============================================================================
get_avail_blocks() {
    local path="$1"
    local blocks
    blocks=$(df "$path" 2>/dev/null | tail -n 1 | awk '{print $4}')
    if [[ ! "$blocks" =~ ^[0-9]+$ ]]; then
        # Fallback parsing in pure bash if awk is unavailable
        local line
        line=$(df "$path" 2>/dev/null | tail -n 1)
        local parts=($line)
        if [ "${#parts[@]}" -ge 4 ]; then
            blocks="${parts[3]}"
        fi
    fi
    if [[ "$blocks" =~ ^[0-9]+$ ]]; then
        echo "$blocks"
    else
        echo "0"
    fi
}

# ==============================================================================
# Function: get_used_blocks
# Gets the used space of a directory in 1K-blocks using df.
# ==============================================================================
get_used_blocks() {
    local path="$1"
    local blocks
    blocks=$(df "$path" 2>/dev/null | tail -n 1 | awk '{print $3}')
    if [[ ! "$blocks" =~ ^[0-9]+$ ]]; then
        # Fallback parsing in pure bash if awk is unavailable
        local line
        line=$(df "$path" 2>/dev/null | tail -n 1)
        local parts=($line)
        if [ "${#parts[@]}" -ge 3 ]; then
            blocks="${parts[2]}"
        fi
    fi
    if [[ "$blocks" =~ ^[0-9]+$ ]]; then
        echo "$blocks"
    else
        echo "0"
    fi
}

# ==============================================================================
# Function: setup_backup_dir
# Selects and sets up the first writable backup directory in order of preference.
# ==============================================================================
setup_backup_dir() {
    # If the user specified a custom BACKUP_DIR in config, check and use it if writable
    if [ -n "$BACKUP_DIR" ]; then
        if mkdir -p "$BACKUP_DIR" 2>/dev/null && [ -w "$BACKUP_DIR" ]; then
            log_msg "INFO" "Using configured backup directory: $BACKUP_DIR"
            setup_stignore "$BACKUP_DIR"
            return 0
        fi
        log_msg "WARNING" "Configured backup directory '$BACKUP_DIR' is not writable. Falling back to search..."
    fi

    local dirs=(
        "$HOME/storage/shared/.backups"
        "$HOME/storage/shared/Documents/.backups"
        "$HOME/storage/shared/Download/.backups"
        "$HOME/storage/shared/Backups"
    )
    for d in "${dirs[@]}"; do
        if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
            BACKUP_DIR="$d"
            log_msg "INFO" "Using writable backup directory: $BACKUP_DIR"
            setup_stignore "$BACKUP_DIR"
            return 0
        fi
    done
    
    # Last resort fallback to local Termux home directory
    local home_backup="$HOME/.backups"
    if mkdir -p "$home_backup" 2>/dev/null && [ -w "$home_backup" ]; then
        BACKUP_DIR="$home_backup"
        log_msg "WARNING" "Could not write to shared storage. Using fallback: $BACKUP_DIR"
        setup_stignore "$BACKUP_DIR"
        return 0
    fi
    
    log_msg "ERROR" "Unable to find or create any writable backup directory."
    return 1
}

# ==============================================================================
# Function: setup_stignore
# Creates .stignore file in the backup directory if not already present.
# ==============================================================================
setup_stignore() {
    local dir="$1"
    if [ -d "$dir" ] && [ ! -f "$dir/.stignore" ]; then
        cat > "$dir/.stignore" << 'EOF'
.tmp_*
.*.tmp
backup.lock
.nobackup
*.tmp
EOF
    fi
}

# ==============================================================================
# Function: ensure_syncthing_running
# Verifies that Syncthing is alive; if not, launches it in the background
# with --no-browser and acquires termux-wake-lock to prevent background sleep.
# ==============================================================================
ensure_syncthing_running() {
    if [ "$ENABLE_SYNCTHING" != true ]; then
        return 0
    fi
    
    if ! command -v syncthing >/dev/null 2>&1; then
        return 0
    fi
    
    # Ensure Termux CPU wake lock is held to keep background tasks alive
    if command -v termux-wake-lock >/dev/null 2>&1; then
        termux-wake-lock 2>/dev/null || true
    fi
    
    if ! pgrep -x "syncthing" >/dev/null 2>&1; then
        log_msg "INFO" "Syncthing is not running. Starting background daemon (--no-browser)..."
        mkdir -p "$LOG_DIR"
        nohup syncthing --no-browser --no-restart > "$LOG_DIR/syncthing.log" 2>&1 &
        sleep 1
        if pgrep -x "syncthing" >/dev/null 2>&1; then
            log_msg "INFO" "Syncthing started successfully in background."
        else
            log_msg "WARNING" "Attempted to start Syncthing, but process was not detected."
        fi
    fi

    # Ensure crond daemon is running if installed
    if command -v crond >/dev/null 2>&1 && ! pgrep -x "crond" >/dev/null 2>&1; then
        crond 2>/dev/null || true
    fi
}

# ==============================================================================
# Function: trigger_syncthing_scan
# Notifies Syncthing via REST API to immediately sync new backup parts.
# ==============================================================================
trigger_syncthing_scan() {
    if [ "$ENABLE_SYNCTHING" = true ] && pgrep -x "syncthing" >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1; then
            curl -s -X POST "http://127.0.0.1:8384/rest/db/scan" >/dev/null 2>&1 || true
            log_msg "INFO" "Notified Syncthing to trigger immediate backup sync."
        fi
    fi
}

# ==============================================================================
# Main execution flow
# ==============================================================================

log_msg "INFO" "Starting connected pendrive scan..."

# Check and ensure Syncthing is running in background if enabled
ensure_syncthing_running

# 1. Prevent concurrent runs using a PID lock file
mkdir -p "$LOG_DIR"
if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Verify if the process with this PID is actually running backup.sh (prevents stale PID lock after reboot)
        if [ -f "/proc/$pid/cmdline" ] && grep -q "backup.sh" "/proc/$pid/cmdline" 2>/dev/null; then
            log_msg "INFO" "Another backup instance is currently running (PID: $pid). Exiting."
            exit 0
        fi
    fi
fi

# Write current PID to lock file and register exit cleanup trap
echo $$ > "$LOCK_FILE"
CURRENT_TMP_DIR=""
cleanup() {
    rm -f "$LOCK_FILE"
    if [ -n "$CURRENT_TMP_DIR" ] && [ -d "$CURRENT_TMP_DIR" ]; then
        rm -rf "$CURRENT_TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# 1. Check if Termux storage is set up
if [ ! -d "$HOME/storage/shared" ]; then
    log_msg "ERROR" "Directory ~/storage/shared does not exist. Please run 'termux-setup-storage' in Termux and grant permission."
    exit 1
fi

# Ensure backup directory exists and is writable
if ! setup_backup_dir; then
    exit 1
fi

# 2. Check if required packages are installed
if ! command -v zip >/dev/null 2>&1; then
    log_msg "ERROR" "The 'zip' utility is not installed. Please run 'pkg install zip' in Termux first."
    exit 1
fi

if ! command -v split >/dev/null 2>&1; then
    log_msg "ERROR" "The 'split' utility is not installed. Please run 'pkg install coreutils' in Termux first."
    exit 1
fi

if ! command -v realpath >/dev/null 2>&1; then
    log_msg "ERROR" "The 'realpath' utility is not installed. Please run 'pkg install coreutils' in Termux first."
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    log_msg "ERROR" "The 'openssl' utility is not installed. Please run 'pkg install openssl' in Termux first."
    exit 1
fi

# 2b. Check encryption key requirements if enabled
if [ "$ENCRYPT_BACKUPS" = true ]; then
    if [ ! -f "$PUBKEY_PATH" ]; then
        log_msg "ERROR" "Encryption is enabled, but the public key certificate was not found at $PUBKEY_PATH"
        log_msg "ERROR" "To generate a key pair and self-signed certificate, run the following commands:"
        log_msg "ERROR" "  openssl genrsa -out \"\$HOME/backup_private_key.pem\" 4096"
        log_msg "ERROR" "  openssl req -new -x509 -key \"\$HOME/backup_private_key.pem\" -out \"$PUBKEY_PATH\" -days 3650 -subj \"/CN=Backup/\""
        exit 1
    fi
fi

# 3. Dynamic SD Card Detection
# Termux links physical external SD cards to ~/storage/external-* which resolves to
# paths like /storage/XXXX-XXXX/Android/data/com.termux/files
EXCLUDED_UUIDS=("${MANUAL_EXCLUDED_UUIDS[@]}")

for ext in "$HOME"/storage/external-*; do
    if [ -L "$ext" ]; then
        target=$(realpath "$ext")
        if [[ "$target" =~ /storage/([A-Za-z0-9]{4}-[A-Za-z0-9]{4}) ]]; then
            uuid="${BASH_REMATCH[1]}"
            EXCLUDED_UUIDS+=("$uuid")
            log_msg "INFO" "Auto-detected memory card: $uuid (linked via $(basename "$ext")). Added to exclusion list."
        fi
    fi
done

# 4. Scan Mount Points
# We look for mounted filesystems under /storage/ that match the UUID format /storage/XXXX-XXXX
# but are NOT in our exclusion list.
found_any_usb=false

while read -r fs blocks used avail percent mount; do
    # Match /storage/XXXX-XXXX or /storage/1234567890ABCDEF pattern (avoiding internal /storage/emulated or /storage/self)
    if [[ "$mount" =~ ^/storage/([A-Za-z0-9]{4}-[A-Za-z0-9]{4}|[A-Za-z0-9]{8,16})$ ]]; then
        uuid="${BASH_REMATCH[1]}"
        
        if [ "$uuid" = "emulated" ] || [ "$uuid" = "self" ]; then
            continue
        fi
        
        # Check if UUID is excluded
        is_excluded=false
        for ex_uuid in "${EXCLUDED_UUIDS[@]}"; do
            if [ "${uuid,,}" = "${ex_uuid,,}" ]; then
                is_excluded=true
                break
            fi
        done
        
        if [ "$is_excluded" = true ]; then
            log_msg "INFO" "Skipping excluded mount $mount (UUID: $uuid)."
            continue
        fi
        
        found_any_usb=true
        log_msg "INFO" "Discovered connected pendrive at $mount (UUID: $uuid)."
        
        # Check if the pendrive contains the skip file (case-insensitive check)
        if [ -n "$SKIP_FILE_NAME" ] && [ -n "$(find "$mount" -maxdepth 1 -iname "$SKIP_FILE_NAME" 2>/dev/null)" ]; then
            log_msg "INFO" "Pendrive $uuid contains skip file '$SKIP_FILE_NAME'. Skipping copy."
            continue
        fi

        target_dir="$BACKUP_DIR/$uuid"
        
        # Skip if backup already exists in dedicated folder or legacy single-file format
        if [ -d "$target_dir" ] && compgen -G "$target_dir/part-*" > /dev/null; then
            log_msg "INFO" "Backup already exists for pendrive $uuid at $target_dir. Skipping copy."
            continue
        elif [ -d "$HOME/storage/shared/Backups/$uuid" ] && compgen -G "$HOME/storage/shared/Backups/$uuid/part-*" > /dev/null; then
            log_msg "INFO" "Backup already exists for pendrive $uuid in legacy folder $HOME/storage/shared/Backups/$uuid. Skipping copy."
            continue
        elif [ -f "$BACKUP_DIR/${uuid}.zip.enc" ] || [ -f "$BACKUP_DIR/${uuid}.zip" ]; then
            log_msg "INFO" "Legacy backup file already exists for pendrive $uuid at $BACKUP_DIR/${uuid}.zip*. Skipping copy."
            continue
        fi
        
        # Ensure used space from df is a valid integer
        if [[ ! "$used" =~ ^[0-9]+$ ]]; then
            log_msg "ERROR" "Failed to parse used space for $mount. Skipping."
            continue
        fi
        
        # Check size constraints
        dest_avail_blocks=$(get_avail_blocks "$BACKUP_DIR")
        
        # Check if used blocks + 4GB buffer is less than available blocks
        required_blocks=$((used + BUFFER_BLOCKS))
        
        used_gb=$(echo "scale=2; $used / 1024 / 1024" | bc 2>/dev/null || awk "BEGIN {print $used/1024/1024}" 2>/dev/null || echo "$((used / 1024 / 1024))")
        avail_gb=$(echo "scale=2; $dest_avail_blocks / 1024 / 1024" | bc 2>/dev/null || awk "BEGIN {print $dest_avail_blocks/1024/1024}" 2>/dev/null || echo "$((dest_avail_blocks / 1024 / 1024))")
        
        log_msg "INFO" "Pendrive data size: ${used_gb} GB. Available space on Android device: ${avail_gb} GB."
        
        if [ "$dest_avail_blocks" -lt "$required_blocks" ]; then
            log_msg "WARNING" "Insufficient available space on Android storage to safely copy $uuid."
            log_msg "WARNING" "Required: ${used_gb} GB + 4 GB buffer. Available: ${avail_gb} GB. Skipping copy."
            continue
        fi
        
        # Temporary staging folder for atomic backup creation
        temp_staging_dir="$BACKUP_DIR/.tmp_${uuid}_$$"
        CURRENT_TMP_DIR="$temp_staging_dir"
        rm -rf "$temp_staging_dir"
        mkdir -p "$temp_staging_dir"
        
        if [ "$ENCRYPT_BACKUPS" = true ]; then
            log_msg "INFO" "Starting compressed and encrypted multi-part backup for pendrive $uuid (part size: $PART_SIZE)..."
            
            temp_key_file="$temp_staging_dir/key.txt"
            temp_enc_key_file="$temp_staging_dir/key.enc"
            
            # 1. Generate random base64 symmetric key
            if ! openssl rand -base64 32 > "$temp_key_file" 2>/dev/null; then
                log_msg "ERROR" "Failed to generate symmetric key for pendrive $uuid."
                rm -rf "$temp_staging_dir"
                CURRENT_TMP_DIR=""
                continue
            fi
            
            # 2. Encrypt symmetric key with RSA public certificate
            if ! openssl smime -encrypt -binary -aes-256-cbc -in "$temp_key_file" -out "$temp_enc_key_file" "$PUBKEY_PATH" 2>/dev/null; then
                log_msg "ERROR" "Failed to encrypt symmetric key with public certificate for pendrive $uuid."
                rm -rf "$temp_staging_dir"
                CURRENT_TMP_DIR=""
                continue
            fi
            
            # 3. Stream: zip -> openssl aes enc -> split into parts
            (cd "$mount" && zip -q -r - . -x "Android/*" -x "System Volume Information/*" -x "lost+found/*" -x ".android_secure/*" -x ".Trashes/*") | \
                openssl enc -aes-256-cbc -salt -pbkdf2 -pass file:"$temp_key_file" | \
                split -b "$PART_SIZE" --numeric-suffixes=1 -a 3 - "$temp_staging_dir/part-"
            pipe_status=("${PIPESTATUS[@]}")
            
            # Clean up plaintext symmetric key immediately
            rm -f "$temp_key_file"
            
            zip_status="${pipe_status[0]:-1}"
            enc_status="${pipe_status[1]:-1}"
            split_status="${pipe_status[2]:-1}"
            
            if { [ "$zip_status" -eq 0 ] || [ "$zip_status" -eq 18 ]; } && [ "$enc_status" -eq 0 ] && [ "$split_status" -eq 0 ] && compgen -G "$temp_staging_dir/part-*" > /dev/null; then
                if [ "$zip_status" -eq 18 ]; then
                    log_msg "WARNING" "Backup completed with non-critical zip warning(s)."
                fi
                mv "$temp_staging_dir" "$target_dir"
                CURRENT_TMP_DIR=""
                part_count=$(ls -1 "$target_dir"/part-* 2>/dev/null | wc -l | tr -d ' ')
                log_msg "INFO" "Successfully compressed, encrypted, and saved backup for pendrive $uuid to $target_dir ($part_count parts)."
                trigger_syncthing_scan
            else
                log_msg "ERROR" "Failed during encrypted backup of pendrive $uuid (zip code: $zip_status, enc code: $enc_status, split code: $split_status)."
                rm -rf "$temp_staging_dir"
                CURRENT_TMP_DIR=""
            fi
        else
            log_msg "INFO" "Starting compressed multi-part backup for pendrive $uuid (part size: $PART_SIZE)..."
            
            # Stream: zip -> split into parts
            (cd "$mount" && zip -q -r - . -x "Android/*" -x "System Volume Information/*" -x "lost+found/*" -x ".android_secure/*" -x ".Trashes/*") | \
                split -b "$PART_SIZE" --numeric-suffixes=1 -a 3 - "$temp_staging_dir/part-"
            pipe_status=("${PIPESTATUS[@]}")
            
            zip_status="${pipe_status[0]:-1}"
            split_status="${pipe_status[1]:-1}"
            
            if { [ "$zip_status" -eq 0 ] || [ "$zip_status" -eq 18 ]; } && [ "$split_status" -eq 0 ] && compgen -G "$temp_staging_dir/part-*" > /dev/null; then
                if [ "$zip_status" -eq 18 ]; then
                    log_msg "WARNING" "Backup completed with non-critical zip warning(s)."
                fi
                mv "$temp_staging_dir" "$target_dir"
                CURRENT_TMP_DIR=""
                part_count=$(ls -1 "$target_dir"/part-* 2>/dev/null | wc -l | tr -d ' ')
                log_msg "INFO" "Successfully compressed and saved backup for pendrive $uuid to $target_dir ($part_count parts)."
                trigger_syncthing_scan
            else
                log_msg "ERROR" "Failed during compression backup of pendrive $uuid (zip code: $zip_status, split code: $split_status)."
                rm -rf "$temp_staging_dir"
                CURRENT_TMP_DIR=""
            fi
        fi
    fi
done < <(df -P 2>/dev/null || df)

if [ "$found_any_usb" = false ]; then
    log_msg "INFO" "No connected pendrives detected during scan."
fi

log_msg "INFO" "Scan completed."
