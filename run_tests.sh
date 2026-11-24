#!/bin/bash
# ==============================================================================
# Script Name: run_tests.sh
# Description: Automated test suite for multi-part backup.sh and restore.sh.
# ==============================================================================

set -euo pipefail

WORKSPACE="/home/mahdi/Documents/my-apps/backup"
TEST_ROOT="$WORKSPACE/test_root"

echo "======================================================================"
echo "Preparing Test Environment..."
echo "======================================================================"
rm -rf "$TEST_ROOT"
rm -f "$WORKSPACE/backup_test.sh" "$WORKSPACE/backup_test_enc.sh" "$WORKSPACE/backup_test_filter.sh"

mkdir -p "$TEST_ROOT/home/storage"
mkdir -p "$TEST_ROOT/home/storage/shared/.backups"
mkdir -p "$TEST_ROOT/home/.logs"
mkdir -p "$TEST_ROOT/storage/831E-10EC/Android/data/com.termux/files"
mkdir -p "$TEST_ROOT/storage/8A6E-8771/subfolder"
mkdir -p "$TEST_ROOT/storage/1234-5678/nested/deep"

# Mock Termux external SD card symlink
ln -s "$TEST_ROOT/storage/831E-10EC/Android/data/com.termux/files" "$TEST_ROOT/home/storage/external-1"

# Generate RSA key pair for testing encryption
openssl genrsa -out "$TEST_ROOT/home/backup_private_key.pem" 2048 2>/dev/null
openssl req -new -x509 -key "$TEST_ROOT/home/backup_private_key.pem" -out "$TEST_ROOT/home/backup_public_key.pem" -days 365 -subj "/CN=TestBackup/" 2>/dev/null

echo "Writing diverse test files to mock pendrive 8A6E-8771..."
echo "Hello World from root" > "$TEST_ROOT/storage/8A6E-8771/hello.txt"
echo "Document in subfolder" > "$TEST_ROOT/storage/8A6E-8771/subfolder/document.txt"
# Create 1.5MB binary file to trigger multi-part splitting (with 400k part size)
head -c 1500000 /dev/urandom > "$TEST_ROOT/storage/8A6E-8771/binary_payload.bin"

echo "Writing test files to mock pendrive 1234-5678 (for encrypted test)..."
echo "Secret data" > "$TEST_ROOT/storage/1234-5678/secret.txt"
head -c 1200000 /dev/urandom > "$TEST_ROOT/storage/1234-5678/nested/deep/secret.bin"

# Prepare test version of backup.sh
cp "$WORKSPACE/backup.sh" "$WORKSPACE/backup_test.sh"

# Escape workspace path for sed
ESC_TEST_ROOT=$(echo "$TEST_ROOT" | sed 's/[&/|]/\\&/g')

# Adapt regex and paths in backup_test.sh for the mock root
sed -i "s|\^/storage/|^${ESC_TEST_ROOT}/storage/|g" "$WORKSPACE/backup_test.sh"
sed -i "s|/storage/([A-Za-z0-9]|${ESC_TEST_ROOT}/storage/([A-Za-z0-9]|g" "$WORKSPACE/backup_test.sh"
# Set part size to 400k so 1.5MB file produces multiple parts (part-001, part-002, ...)
sed -i 's|PART_SIZE="500M"|PART_SIZE="400k"|g' "$WORKSPACE/backup_test.sh"
# Test 1 tests unencrypted backup:
sed -i 's|ENCRYPT_BACKUPS=true|ENCRYPT_BACKUPS=false|g' "$WORKSPACE/backup_test.sh"
# Disable extension filter for Tests 1-5 to verify general all-files backup & recovery
sed -i 's|BACKUP_EXTENSIONS=.*|BACKUP_EXTENSIONS=()|g' "$WORKSPACE/backup_test.sh"

# Replace df input feed with mock data
sed -i "s~done < <(df -P 2>/dev/null || df)~done < <(printf '%s\n%s\n%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/sda1 100000000 50000 95000000 1% ${TEST_ROOT}/storage/8A6E-8771' '/dev/sda3 100000000 10000 95000000 1% ${TEST_ROOT}/storage/831E-10EC')~g" "$WORKSPACE/backup_test.sh"

chmod +x "$WORKSPACE/backup_test.sh"

echo "======================================================================"
echo "Test 1: Running unencrypted multi-part backup..."
echo "======================================================================"
HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test.sh"

echo "Verification 1.1: Checking created backup folder & parts"
test -d "$TEST_ROOT/home/storage/shared/.backups/8A6E-8771"
ls -la "$TEST_ROOT/home/storage/shared/.backups/8A6E-8771/"

PART_COUNT=$(ls -1 "$TEST_ROOT/home/storage/shared/.backups/8A6E-8771"/part-* | wc -l)
echo "Generated $PART_COUNT parts for pendrive 8A6E-8771."
if [ "$PART_COUNT" -lt 2 ]; then
    echo "ERROR: Expected at least 2 parts, got $PART_COUNT"
    exit 1
fi

echo "Verification 1.2: Restoring unencrypted backup with restore.sh..."
RESTORE_OUT_1="$TEST_ROOT/restored_8A6E-8771"
"$WORKSPACE/restore.sh" "$TEST_ROOT/home/storage/shared/.backups/8A6E-8771" "$RESTORE_OUT_1"

echo "Verification 1.3: Comparing restored files byte-for-byte with original source..."
diff -r "$TEST_ROOT/storage/8A6E-8771" "$RESTORE_OUT_1"
echo "PASS: Restored unencrypted files match original pendrive perfectly!"

echo "Verification 1.4: Verifying per-part Syncthing sync was triggered..."
grep -q "Completed part-001 for pendrive 8A6E-8771. Triggered Syncthing sync." "$TEST_ROOT/home/.logs/pendrive_backup.log"
grep -q "Completed part-002 for pendrive 8A6E-8771. Triggered Syncthing sync." "$TEST_ROOT/home/.logs/pendrive_backup.log"
echo "PASS: Per-part Syncthing sync verified in log file!"

echo "======================================================================"
echo "Test 2: Running encrypted multi-part backup..."
echo "======================================================================"
cp "$WORKSPACE/backup_test.sh" "$WORKSPACE/backup_test_enc.sh"
sed -i 's|ENCRYPT_BACKUPS=false|ENCRYPT_BACKUPS=true|g' "$WORKSPACE/backup_test_enc.sh"
sed -i "s|PUBKEY_PATH=\"\$HOME/backup_public_key.pem\"|PUBKEY_PATH=\"$TEST_ROOT/home/backup_public_key.pem\"|g" "$WORKSPACE/backup_test_enc.sh"

# Mock df for drive 1234-5678
sed -i "s|8A6E-8771|1234-5678|g" "$WORKSPACE/backup_test_enc.sh"

HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test_enc.sh"

echo "Verification 2.1: Checking encrypted backup directory contents..."
test -d "$TEST_ROOT/home/storage/shared/.backups/1234-5678"
test -f "$TEST_ROOT/home/storage/shared/.backups/1234-5678/key.enc"
ls -la "$TEST_ROOT/home/storage/shared/.backups/1234-5678/"

echo "Verification 2.2: Restoring encrypted backup with restore.sh..."
RESTORE_OUT_2="$TEST_ROOT/restored_1234-5678"
"$WORKSPACE/restore.sh" "$TEST_ROOT/home/storage/shared/.backups/1234-5678" "$TEST_ROOT/home/backup_private_key.pem" "$RESTORE_OUT_2"

echo "Verification 2.3: Comparing restored encrypted files byte-for-byte with original..."
diff -r "$TEST_ROOT/storage/1234-5678" "$RESTORE_OUT_2"
echo "PASS: Restored encrypted files match original pendrive perfectly!"

echo "Verification 2.4: Verifying key.enc and per-part Syncthing sync for encrypted backup..."
grep -q "Saved key.enc for pendrive 1234-5678. Triggered Syncthing sync." "$TEST_ROOT/home/.logs/pendrive_backup.log"
grep -q "Completed part-001 for pendrive 1234-5678. Triggered Syncthing sync." "$TEST_ROOT/home/.logs/pendrive_backup.log"
echo "PASS: Encrypted key.enc and per-part sync verified!"

echo "======================================================================"
echo "Test 3: Verify Skip Logic on Existing Backups"
echo "======================================================================"
HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test.sh"
grep -q "Backup already exists for pendrive 8A6E-8771" "$TEST_ROOT/home/.logs/pendrive_backup.log"
echo "PASS: Skip logic verified in log file!"

echo "======================================================================"
echo "Test 4: Verify Incomplete Backup Cleanup & Recovery"
echo "======================================================================"
# Simulate an interrupted/incomplete backup
touch "$TEST_ROOT/home/storage/shared/.backups/8A6E-8771/.incomplete"
HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test.sh"
grep -q "Found incomplete previous backup for pendrive 8A6E-8771" "$TEST_ROOT/home/.logs/pendrive_backup.log"
test ! -f "$TEST_ROOT/home/storage/shared/.backups/8A6E-8771/.incomplete"
echo "PASS: Incomplete backup cleanup and recovery verified!"

echo "======================================================================"
echo "Test 5: Verify Specific File Type Extension Filtering"
echo "======================================================================"
mkdir -p "$TEST_ROOT/storage/ABCD-5678/folder1/nested"
echo "Report Doc" > "$TEST_ROOT/storage/ABCD-5678/report.doc"
echo "Slides PPTX" > "$TEST_ROOT/storage/ABCD-5678/folder1/slides.PPTX"
echo "Manual PDF" > "$TEST_ROOT/storage/ABCD-5678/folder1/nested/manual.pdf"
echo "Should be excluded: movie.mp4" > "$TEST_ROOT/storage/ABCD-5678/movie.mp4"
echo "Should be excluded: photo.jpg" > "$TEST_ROOT/storage/ABCD-5678/folder1/photo.jpg"
echo "Should be excluded: data.bin" > "$TEST_ROOT/storage/ABCD-5678/folder1/nested/data.bin"

# Pendrive with ZERO matching files (only .mp4 and .png)
mkdir -p "$TEST_ROOT/storage/9999-0000"
echo "Video clip" > "$TEST_ROOT/storage/9999-0000/clip.mp4"
echo "Picture" > "$TEST_ROOT/storage/9999-0000/image.png"

# Prepare backup_test_filter.sh
cp "$WORKSPACE/backup.sh" "$WORKSPACE/backup_test_filter.sh"
sed -i "s|\^/storage/|^${ESC_TEST_ROOT}/storage/|g" "$WORKSPACE/backup_test_filter.sh"
sed -i "s|/storage/([A-Za-z0-9]|${ESC_TEST_ROOT}/storage/([A-Za-z0-9]|g" "$WORKSPACE/backup_test_filter.sh"
sed -i 's|PART_SIZE="500M"|PART_SIZE="400k"|g' "$WORKSPACE/backup_test_filter.sh"
sed -i 's|ENCRYPT_BACKUPS=true|ENCRYPT_BACKUPS=false|g' "$WORKSPACE/backup_test_filter.sh"
# Ensure BACKUP_EXTENSIONS is set to specific extensions
sed -i 's|BACKUP_EXTENSIONS=.*|BACKUP_EXTENSIONS=("doc" "docx" "docs" "ppt" "pptx" "pdf")|g' "$WORKSPACE/backup_test_filter.sh"

# Mock df output for ABCD-5678 and 9999-0000
sed -i "s~done < <(df -P 2>/dev/null || df)~done < <(printf '%s\n%s\n%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/sdb1 100000000 50000 95000000 1% ${TEST_ROOT}/storage/ABCD-5678' '/dev/sdc1 100000000 50000 95000000 1% ${TEST_ROOT}/storage/9999-0000')~g" "$WORKSPACE/backup_test_filter.sh"
chmod +x "$WORKSPACE/backup_test_filter.sh"

HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test_filter.sh"

echo "Verification 5.1: Verify matching drive was backed up and restored"
test -d "$TEST_ROOT/home/storage/shared/.backups/ABCD-5678"
RESTORE_OUT_FILTER="$TEST_ROOT/restored_ABCD-5678"
"$WORKSPACE/restore.sh" "$TEST_ROOT/home/storage/shared/.backups/ABCD-5678" "$RESTORE_OUT_FILTER"

test -f "$RESTORE_OUT_FILTER/report.doc"
test -f "$RESTORE_OUT_FILTER/folder1/slides.PPTX"
test -f "$RESTORE_OUT_FILTER/folder1/nested/manual.pdf"

test ! -f "$RESTORE_OUT_FILTER/movie.mp4"
test ! -f "$RESTORE_OUT_FILTER/folder1/photo.jpg"
test ! -f "$RESTORE_OUT_FILTER/folder1/nested/data.bin"
echo "PASS: Filtered backup contains all matching documents (.doc, .PPTX, .pdf) and excluded non-matching files!"

echo "Verification 5.2: Verify non-matching drive was cleanly skipped"
test ! -d "$TEST_ROOT/home/storage/shared/.backups/9999-0000"
grep -q "No files matching configured extension filter (doc docx docs ppt pptx pdf) found on pendrive 9999-0000. Skipping." "$TEST_ROOT/home/.logs/pendrive_backup.log"
echo "PASS: Drive with no matching extensions was cleanly skipped without creating an archive!"

echo "======================================================================"
echo "Test 6: Verify Backup Retention Auto-Deletion (Older than X Days)"
echo "======================================================================"
# Create mock expired backup folder (modified 35 days ago)
mkdir -p "$TEST_ROOT/home/storage/shared/.backups/OLD-DRIVE-1"
echo "Old part" > "$TEST_ROOT/home/storage/shared/.backups/OLD-DRIVE-1/part-001"
echo "Old key" > "$TEST_ROOT/home/storage/shared/.backups/OLD-DRIVE-1/key.enc"
touch -d "35 days ago" "$TEST_ROOT/home/storage/shared/.backups/OLD-DRIVE-1/part-001"
touch -d "35 days ago" "$TEST_ROOT/home/storage/shared/.backups/OLD-DRIVE-1/key.enc"

# Create mock fresh backup folder (modified 5 days ago)
mkdir -p "$TEST_ROOT/home/storage/shared/.backups/NEW-DRIVE-2"
echo "New part" > "$TEST_ROOT/home/storage/shared/.backups/NEW-DRIVE-2/part-001"
touch -d "5 days ago" "$TEST_ROOT/home/storage/shared/.backups/NEW-DRIVE-2/part-001"

# Create mock expired legacy archive
echo "Legacy zip" > "$TEST_ROOT/home/storage/shared/.backups/legacy-old.zip"
touch -d "35 days ago" "$TEST_ROOT/home/storage/shared/.backups/legacy-old.zip"

# Prepare test script with RETENTION_DAYS=30
cp "$WORKSPACE/backup.sh" "$WORKSPACE/backup_test_retention.sh"
sed -i "s|\^/storage/|^${ESC_TEST_ROOT}/storage/|g" "$WORKSPACE/backup_test_retention.sh"
sed -i "s|/storage/([A-Za-z0-9]|${ESC_TEST_ROOT}/storage/([A-Za-z0-9]|g" "$WORKSPACE/backup_test_retention.sh"
sed -i 's|RETENTION_DAYS=0|RETENTION_DAYS=30|g' "$WORKSPACE/backup_test_retention.sh"
sed -i "s~done < <(df -P 2>/dev/null || df)~done < <(printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on')~g" "$WORKSPACE/backup_test_retention.sh"
chmod +x "$WORKSPACE/backup_test_retention.sh"

HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test_retention.sh"

echo "Verification 6.1: Verify expired backup directory was deleted"
test ! -d "$TEST_ROOT/home/storage/shared/.backups/OLD-DRIVE-1"
echo "PASS: Expired backup directory OLD-DRIVE-1 was successfully deleted!"

echo "Verification 6.2: Verify expired legacy zip was deleted"
test ! -f "$TEST_ROOT/home/storage/shared/.backups/legacy-old.zip"
echo "PASS: Expired legacy archive was successfully deleted!"

echo "Verification 6.3: Verify fresh backup was preserved"
test -d "$TEST_ROOT/home/storage/shared/.backups/NEW-DRIVE-2"
test -f "$TEST_ROOT/home/storage/shared/.backups/NEW-DRIVE-2/part-001"
echo "PASS: Fresh backup within retention period was safely preserved!"

echo "Verification 6.4: Verify retention log messages"
grep -q "Backup for pendrive OLD-DRIVE-1 is older than 30 days. Deleting" "$TEST_ROOT/home/.logs/pendrive_backup.log"
echo "PASS: Retention cleanup log messages verified!"

echo "======================================================================"
echo "Test 7: Verify Log Rotation"
echo "======================================================================"
sed -i 's|MAX_LOG_SIZE=.*|MAX_LOG_SIZE=300|g' "$WORKSPACE/backup_test.sh"
rm -f "$TEST_ROOT/home/.logs/pendrive_backup.log" "$TEST_ROOT/home/.logs/pendrive_backup.log.old"

for _ in {1..10}; do
    HOME="$TEST_ROOT/home" "$WORKSPACE/backup_test.sh" >/dev/null
done

test -f "$TEST_ROOT/home/.logs/pendrive_backup.log.old"
echo "PASS: Log rotation successfully created pendrive_backup.log.old!"

echo "======================================================================"
echo "ALL TESTS PASSED SUCCESSFULLY!"
echo "======================================================================"

# Clean up test artifacts
rm -rf "$TEST_ROOT" "$WORKSPACE"/backup_test*.sh

