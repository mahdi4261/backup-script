# Termux USB Pendrive Multi-Part Backup System & Syncthing Sync

Automated, robust, and encrypted USB pendrive backup system designed for **Android (Termux)** with multi-part chunking (~500MB per file), self-healing Syncthing synchronization, and cross-platform restoration.

---

## ⚡ 1-Command Quick Setup (Termux)

On your Android phone in Termux, run this single command to download and set up everything automatically:

```bash
pkg upgrade -y && pkg install curl -y && bash -c "$(curl -fsSL https://raw.githubusercontent.com/mahdi4261/backup-script/main/setup-backup.sh)"
```

*(Alternatively, via Git clone:)*
```bash
pkg upgrade -y && pkg install git -y && git clone https://github.com/mahdi4261/backup-script.git ~/backup-script && bash ~/backup-script/setup-backup.sh
```

---

## ✨ Features

- **Dedicated Folders per Drive**: Each pendrive is backed up into its own folder: `~/storage/shared/.backups/<UUID>/`.
- **~500MB Multi-Part Splitting**: Archives are chunked into 500MB parts (`part-001`, `part-002`, ...), overcoming the 4GB FAT32 Android file limit.
- **In-Memory Streaming**: Zero multi-gigabyte temporary files on disk; compression, encryption, and splitting stream directly through memory pipelines.
- **Hybrid RSA + AES Encryption (Optional)**: Secures pendrive data using public-key hybrid encryption before storing or syncing.
- **Syncthing Integration**:
  - Automatically installs and starts Syncthing in the background (`--no-browser`).
  - Auto-triggers immediate sync when a new backup is created.
  - Watchdog in `backup.sh` ensures Syncthing stays running.
- **Android CPU Wake Lock**: Holds `termux-wake-lock` to keep backups and Syncthing alive when the screen is locked.
- **Safe Atomic Operations**: Writes to temporary staging directories and only moves to destination upon verified completion.
- **Cross-Platform Restore Utility**: Includes `restore.sh` to decrypt and extract backup parts back into original directory structures.

---

## 📂 Repository Contents

| File | Description |
| :--- | :--- |
| [`setup-backup.sh`](setup-backup.sh) | Automated 1-step installer for dependencies, permissions, Syncthing, and scripts |
| [`backup.sh`](backup.sh) | Main scanner and backup engine (detects pendrives, compresses, splits, encrypts) |
| [`restore.sh`](restore.sh) | Restore & extraction utility (works on Android Termux, Linux, macOS, and WSL) |
| [`backup_public_key.pem`](backup_public_key.pem) | Public key certificate used for encrypting backups |
| [`run_tests.sh`](run_tests.sh) | Automated local test suite verifying multi-part backups, restore, and rotation |

---

## 🚀 Usage

### 1. Manual Backup Run
Plug in your USB pendrive via OTG and run:
```bash
bash ~/backup.sh
```

### 2. Automatic Scheduled Backups (Cron)
The setup script automatically registers the backup job and starts the `crond` daemon to scan every 1 minute in the background.

To inspect or edit your scheduled cron schedule:
```bash
crontab -l
```
*(The configured entry runs every 1 minute: `* * * * * ... ~/backup.sh`)*

### 3. Restoring Files with `restore.sh`
To extract original files from a backup folder:

```bash
# For unencrypted backups:
./restore.sh ~/storage/shared/.backups/<UUID> [destination_folder]

# For encrypted backups (with your private key):
./restore.sh ~/storage/shared/.backups/<UUID> ~/backup_private_key.pem [destination_folder]
```

---

## 🔄 Syncthing Pairing Guide

1. Open your phone's browser to **`http://127.0.0.1:8384`**.
2. Click **Actions** $\to$ **Show ID** to view your phone's Syncthing Device ID.
3. On your remote PC / Server, install Syncthing and click **Add Remote Device**, then paste your phone's Device ID.
4. On your phone, add folder `~/storage/shared/.backups` (or `/storage/emulated/0/.backups`), check the box for your remote PC under **Sharing**, and set Folder Type to **Send Only**.
5. Accept the folder on your PC as **Receive Only** to automatically mirror all pendrive backups!

---

## 🔒 Security Best Practices

> [!IMPORTANT]
> Keep your **`backup_private_key.pem`** safe and **never** commit it to public repositories. Only the public key (`backup_public_key.pem`) is stored on the phone to encrypt data.
