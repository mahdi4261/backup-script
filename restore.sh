#!/usr/bin/env bash
# ==============================================================================
# Script Name: restore.sh
# Description: Restores and extracts files from a multi-part pendrive backup.
#              Automatically detects encrypted vs unencrypted backups, decrypts
#              with the provided RSA private key if necessary, and extracts
#              all original files into the specified destination folder.
# Target:      Linux / Termux (Android)
# ==============================================================================

set -o pipefail

print_usage() {
    echo "=============================================================================="
    echo " Pendrive Backup Restore Utility"
    echo "=============================================================================="
    echo "Usage:"
    echo "  $0 <backup_folder> [private_key_file] [output_folder]"
    echo ""
    echo "Arguments:"
    echo "  <backup_folder>     Path to the pendrive backup directory (contains part-001, etc.)"
    echo "  [private_key_file]  Path to RSA private key (e.g. ~/backup_private_key.pem)"
    echo "                      Required if the backup is encrypted (key.enc present)."
    echo "  [output_folder]     Destination folder to extract the files into."
    echo "                      (Defaults to ./restored_<UUID> in current directory)"
    echo ""
    echo "Examples:"
    echo "  # Restore unencrypted backup:"
    echo "  $0 ~/storage/shared/.backups/8A6E-8771"
    echo "  $0 ~/storage/shared/.backups/8A6E-8771 /path/to/extracted_files"
    echo ""
    echo "  # Restore encrypted backup:"
    echo "  $0 ~/storage/shared/.backups/8A6E-8771 ~/backup_private_key.pem"
    echo "  $0 ~/storage/shared/.backups/8A6E-8771 ~/backup_private_key.pem /path/to/extracted_files"
    echo "=============================================================================="
}

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    print_usage
    exit 0
fi

BACKUP_FOLDER="$1"
ARG2="${2:-}"
ARG3="${3:-}"

# Check dependencies
for cmd in unzip openssl cat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required utility '$cmd' is not installed."
        exit 1
    fi
done

# Validate backup directory
if [ ! -d "$BACKUP_FOLDER" ]; then
    echo "[ERROR] Backup directory '$BACKUP_FOLDER' not found."
    exit 1
fi

# Ensure part files exist
if ! compgen -G "$BACKUP_FOLDER/part-*" > /dev/null; then
    echo "[ERROR] No backup parts (part-*) found in '$BACKUP_FOLDER'."
    exit 1
fi

UUID=$(basename "$BACKUP_FOLDER")

# Determine if encrypted and parse arguments
IS_ENCRYPTED=false
if [ -f "$BACKUP_FOLDER/key.enc" ]; then
    IS_ENCRYPTED=true
fi

PRIVATE_KEY=""
OUTPUT_DIR=""

if [ "$IS_ENCRYPTED" = true ]; then
    if [ -n "$ARG2" ] && [ -f "$ARG2" ]; then
        PRIVATE_KEY="$ARG2"
        OUTPUT_DIR="${ARG3:-./restored_${UUID}}"
    elif [ -n "$ARG2" ] && [ ! -f "$ARG2" ] && [ -z "$ARG3" ]; then
        # User may have provided output directory as 2nd argument instead of private key
        echo "[ERROR] This backup is encrypted (contains key.enc)."
        echo "[ERROR] Private key '$ARG2' was not found."
        echo "Usage: $0 \"$BACKUP_FOLDER\" <private_key_file> [output_folder]"
        exit 1
    else
        echo "[ERROR] This backup is encrypted (contains key.enc)."
        echo "[ERROR] Please specify the path to your private key file."
        echo "Usage: $0 \"$BACKUP_FOLDER\" <private_key_file> [output_folder]"
        exit 1
    fi
else
    # Unencrypted backup
    if [ -n "$ARG2" ] && [ -f "$ARG2" ] && [ -n "$ARG3" ]; then
        PRIVATE_KEY="$ARG2"
        OUTPUT_DIR="$ARG3"
    elif [ -n "$ARG2" ]; then
        OUTPUT_DIR="$ARG2"
    else
        OUTPUT_DIR="./restored_${UUID}"
    fi
fi

# Set up temporary working directory for reassembly & extraction
TMP_DIR=$(mktemp -d "/tmp/restore_${UUID}_XXXXXX" 2>/dev/null || mktemp -d)
TEMP_ZIP="$TMP_DIR/backup.zip"
TEMP_KEY="$TMP_DIR/session.key"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

echo "[INFO] Starting restoration for pendrive '$UUID'..."
echo "[INFO] Source backup: $BACKUP_FOLDER"
echo "[INFO] Target output: $OUTPUT_DIR"

if [ "$IS_ENCRYPTED" = true ]; then
    echo "[INFO] Backup is encrypted. Decrypting session key using '$PRIVATE_KEY'..."
    if ! openssl smime -decrypt -inkey "$PRIVATE_KEY" -in "$BACKUP_FOLDER/key.enc" -out "$TEMP_KEY" 2>/dev/null; then
        echo "[ERROR] Failed to decrypt session key. Please verify your private key is correct."
        exit 1
    fi
    
    echo "[INFO] Reassembling and decrypting backup parts..."
    if ! cat "$BACKUP_FOLDER"/part-* | openssl enc -d -aes-256-cbc -salt -pbkdf2 -pass file:"$TEMP_KEY" > "$TEMP_ZIP" 2>/dev/null; then
        echo "[ERROR] Decryption or reassembly of backup parts failed."
        exit 1
    fi
    rm -f "$TEMP_KEY"
else
    echo "[INFO] Backup is unencrypted. Reassembling backup parts..."
    if ! cat "$BACKUP_FOLDER"/part-* > "$TEMP_ZIP"; then
        echo "[ERROR] Failed to reassemble backup parts."
        exit 1
    fi
fi

# Verify archive integrity
echo "[INFO] Verifying archive integrity..."
if ! unzip -tq "$TEMP_ZIP" >/dev/null 2>&1; then
    echo "[ERROR] Restored archive failed integrity test. The backup may be corrupted or incomplete."
    exit 1
fi

# Extract archive
echo "[INFO] Extracting files into '$OUTPUT_DIR'..."
mkdir -p "$OUTPUT_DIR"
if ! unzip -q -o "$TEMP_ZIP" -d "$OUTPUT_DIR"; then
    echo "[ERROR] Failed while unzipping files into '$OUTPUT_DIR'."
    exit 1
fi

FILE_COUNT=$(find "$OUTPUT_DIR" -type f | wc -l | tr -d ' ')
DIR_COUNT=$(find "$OUTPUT_DIR" -type d | wc -l | tr -d ' ')

echo "=============================================================================="
echo "[SUCCESS] Restoration completed successfully!"
echo "          Extracted $FILE_COUNT file(s) across $DIR_COUNT directory(s)."
echo "          Location: $OUTPUT_DIR"
echo "=============================================================================="
