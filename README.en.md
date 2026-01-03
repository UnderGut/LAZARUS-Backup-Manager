<p align="center">
  <img src="assets/main_menu.svg?v=1" alt="LAZARUS main menu" width="600">
</p>

# LAZARUS Backup Manager

<div align="center">

### 🌐 Language / Язык

[![English](https://img.shields.io/badge/🇬🇧_English-green?style=for-the-badge)](README.en.md)
[![Русский](https://img.shields.io/badge/🇷🇺_Русский-blue?style=for-the-badge)](README.md)

</div>

[![Bash](https://img.shields.io/badge/Language-Bash_5+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/github/license/UnderGut/LAZARUS-Backup-Manager?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-4.30.0--dev-orange?style=flat-square)](https://github.com/UnderGut/LAZARUS-Backup-Manager/releases)
[![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

**LAZARUS** — an advanced backup system for **[Remnawave Telegram Shop Bot](https://remnawave-telegram-shop-bot-doc.vercel.app/ru/private/overview/)** with encryption, cloud storage support, and smart automation.

---

## 🚀 Quick Start

> ⚠️ **DEV version!** This branch contains experimental features. For stable version use `main` branch.

One command — install and run:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/dev/lazarus-backup)
```

Or install to system:

```bash
curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/dev/lazarus-backup -o /usr/local/bin/lazarus && chmod +x /usr/local/bin/lazarus && lazarus
```

> 💡 The script will automatically install to `/opt/lazarus-backup/` and create symlink `/usr/local/bin/lazarus`

---

## ✨ Features

### Backup
- **Smart Scan** — automatically finds bot in Docker (supports `rwp_shop`, `telegram-shop`, `shopbot`)
- **3 backup types** — Full (DB + files), DB Only, Files Only
- **AES-256 encryption** — archive password protection (PBKDF2, 100k iterations)
- **Versioning** — each backup contains bot version at creation time
- **Smart filtering** — excludes large files and folders (logs, node_modules, .git)

### 🆕 Bedolaga Migration (BETA)
- **Automatic migration** — complete data transfer from Bedolaga to RWP-Shop in 10 steps
- **Users** — telegram_id, username, referral codes (~95% coverage)
- **Subscriptions** — all active subscriptions with dates and statuses (~90% coverage)
- **Transactions** — payment history and promo codes (~85% coverage)
- **Settings** — bot token, channels, admins from .env
- **Incompatible data preservation** — balances, balance promo codes saved to NOT_MIGRATED
- 📖 **[Full migration documentation](migration/README.en.md)**

### Storage and Delivery
- **Telegram** — file and notification sending (separately configurable)
- **FTP / FTPS / WebDAV / Rclone** — cloud storage with retry and step-by-step setup
- **Smart rotation** — by time (days) or file count

### Automation
- **Cron integration** — schedule configuration from menu
- **Parallel run blocking** — prevents conflicts when running from cron
- **Auto-update** — check and install new script versions

### Bot Management
- **Restore** — Full / DB / Files from any backup
- **Bot update** — install new version from tar file with auto-backup
- **Health-check** — container verification before operations

### Debugging
- **Debug mode** — full logging of all operations (`--debug`)
- **Dry-run** — action preview without execution (`--dry-run`)

---

## 📋 Requirements

- Linux (Debian/Ubuntu/CentOS)
- Bash 5+, root privileges
- Docker Compose v2 (`docker compose`, not `docker-compose`)
- tar, gzip, curl/wget, openssl

---

## 🖥️ Interface

> 📸 Full screenshot gallery: [screenshots/README.md](screenshots/README.md)

### Main Menu
<p align="center">
  <img src="assets/main_menu.svg?v=1" alt="LAZARUS main menu" width="600">
</p>

---

## ⚙️ Configuration

Config file: `/opt/lazarus-backup/config.env` (chmod 600)

### Telegram (optional)

> 💡 **Telegram settings are optional.** If not configured, the script will show a notification in the menu but will work without sending notifications.

| Parameter | Description | Example |
|-----------|-------------|---------|
| `BOT_TOKEN` | Telegram bot token | `123456:ABC-DEF1234...` |
| `CHAT_ID` | Chat ID for notifications | `-1001234567890` |
| `TG_MESSAGE_THREAD_ID` | Topic ID (for groups with topics) | `12345` or empty |
| `SEND_TO_TELEGRAM` | TG notifications | `true` / `false` |
| `TG_SEND_FILE` | Send archive to TG | `true` / `false` |

### Bot and Docker

| Parameter | Description | Example |
|-----------|-------------|---------|
| `BOT_PATH` | Path to bot docker-compose | `/opt/private-remnawave-telegram-shop-bot` |
| `BOT_CONTAINER_NAME` | Bot container name | `rwp_shop` |
| `DB_CONTAINER_NAME` | DB container name | `rwp_shop_db` |
| `DB_USER` | PostgreSQL user | `postgres` |
| `IGNORE_MISMATCH` | Ignore container mismatch | `true` / `false` |

> 💡 Script automatically reads `POSTGRES_USER` and `POSTGRES_DB` from bot's `.env` file

### Backup Rotation

| Parameter | Description | Example |
|-----------|-------------|---------|
| `DELETE_MODE` | Deletion mode | `time` (by days) / `count` (by quantity) |
| `RETENTION_DAYS` | Keep N days (if mode=time) | `7` |
| `MAX_BACKUPS_COUNT` | Max count (if mode=count) | `100` |
| `MAX_BACKUP_SIZE_MB` | Total backup size limit in MB | `0` (no limit) |

### Schedule (cron format)

| Parameter | Description | Example |
|-----------|-------------|---------|
| `SCHEDULE_FULL` | Full backup schedule | `0 4 * * *` (daily 04:00) |
| `SCHEDULE_DB` | DB backup schedule | `*/15 * * * *` (every 15 min) |
| `SCHEDULE_FILES` | Files backup schedule | empty (disabled) |

### Remote Storage

| Parameter | Description | Example |
|-----------|-------------|---------|
| `REMOTE_STORAGE_TYPE` | Storage type | `off` / `ftp` / `ftps` / `webdav` / `rclone` |
| `REMOTE_STORAGE_URL` | Server URL with folder | `ftp://backup.server.com/backups/` |
| `REMOTE_STORAGE_USER` | Login | `backup_user` |
| `REMOTE_STORAGE_PASS` | Password | `secret123` |
| `SEND_TO_REMOTE` | Send to remote server | `true` / `false` |

### Encryption and Filtering

| Parameter | Description | Example |
|-----------|-------------|---------|
| `BACKUP_PASSWORD` | AES-256 encryption password | `MySecretPass123` or empty |
| `MAX_FILE_SIZE_MB` | Max file size in archive (MB) | `1` (skip larger) |
| `EXCLUDE_DIRS` | Exclude folders (space-separated) | `node_modules .git cache` |

---

## 💻 CLI Commands

### Main Commands

```bash
lazarus                  # Interactive menu
lazarus restore          # Restore menu
lazarus migrate          # 🆕 Bedolaga migration (BETA)
lazarus cleanup          # Old backup cleanup
lazarus check_update     # Check script updates
```

### 🆕 Backup Commands (v4.30.0+)

```bash
lazarus backup create    # Full backup (DB + files)
lazarus backup db        # Database only
lazarus backup files     # Files only
lazarus backup list      # List backups

# Short flags
lazarus -B -c            # = lazarus backup create
lazarus -B -d            # = lazarus backup db
lazarus -B -f            # = lazarus backup files

# Legacy commands (compatibility)
lazarus backup_full      # = lazarus backup create
lazarus backup_db        # = lazarus backup db
lazarus backup_files     # = lazarus backup files
```

### 🆕 Bot Management (v4.30.0+)

```bash
lazarus upgrade          # Auto-update bot (non-interactive)
lazarus bot up           # Start bot containers
lazarus bot down         # Stop bot containers  
lazarus bot status       # Container status
lazarus bot upgrade      # Auto-update bot

# Short flags
lazarus -b -u            # = lazarus bot upgrade
lazarus -b -s            # = lazarus bot status
```

### Global Flags

| Flag | Description |
|------|-------------|
| `--yes`, `-y` | Auto-confirm (for cron) |
| `--dry-run`, `-n` | Preview without execution |
| `--debug`, `-d` | Debug mode (detailed logging) |
| `--report-tg` | Send report to Telegram |

### Usage Examples

```bash
# Automatic backup from cron
lazarus --yes backup_full

# Cleanup preview
lazarus --dry-run cleanup

# Debug with full output
lazarus --debug backup_db

# Cleanup with Telegram report
lazarus --yes --report-tg cleanup
```

---

## ☁️ Remote Storage

### FTP/FTPS
```
ftp://backup.example.com/backups
ftps://secure.example.com:990/folder
```

### WebDAV
```
https://webdav.yandex.ru/backups
https://cloud.example.com/remote.php/dav/files/user/
```

### Rclone (requires rclone installation)
```
gdrive:backups
s3:bucket/backups
dropbox:backup-folder
```

---

## 🔄 Bedolaga Migration (BETA)

> ⚠️ **Experimental feature!** Use at your own risk. Always make backups!

LAZARUS includes a data migration module from **Bedolaga** Telegram bot to **RWP-Shop**:

### What Gets Migrated (~88% coverage)

| Data | Coverage | Note |
|------|:--------:|------|
| 👤 Users | ~95% | telegram_id, username, ref. codes |
| 📋 Subscriptions | ~90% | All active with dates |
| 💳 Transactions | ~85% | Payment history |
| 🎟️ Promo codes | ~100% | Days and discounts |
| 👥 Referrals | ~80% | Referrer → referred links |
| ⚙️ Settings | ~85% | Token, channels, admins |

### What Does NOT Migrate

- **Money balances** — RWP-Shop doesn't support (saved to CSV)
- **Balance promo codes** — only days/discounts (saved to CSV)
- **Individual autopay** — RWP-Shop uses global setting

### Quick Start

```bash
lazarus migrate
# or via menu: 5 → Migration
```

📖 **Full documentation:** [migration/README.en.md](migration/README.en.md)

---

## 🔄 Bot Update

LAZARUS includes Remnawave Telegram Shop Bot update functionality:

### Smart Update (v4.29.0+)
- **Docker images check** — if image is already loaded in Docker, offers to update immediately without searching for tar files
- **Requirements check** — for versions 3.25.5+ shows LICENSE_KEY and machine-id volume status
- **Warnings** — red notifications if LICENSE_KEY or machine-id are missing

### CLI Update Commands (v4.30.0+)
```bash
lazarus upgrade          # Auto-update bot without interactive menu
lazarus bot upgrade      # Same
lazarus -b -u            # Short form
```

### Script Update
The script uses **jsDelivr CDN** for update checks (faster than raw.githubusercontent.com).
```bash
lazarus check_update     # Check and update script
```

### Update Process
1. Check loaded images in Docker
2. Search tar files in `/opt/`, `/root/`, `/home/`, `/tmp/`, bot folder
3. Display available versions with new ones highlighted
4. Automatic backup before update (Full + DB)
5. Load image (if not loaded) and update `compose.yaml`
6. Check and add LICENSE_KEY / machine-id volume
7. Container health-check after update
8. Offer to delete installation tar files

📖 **Full documentation:** [bot-update/README.en.md](bot-update/README.en.md)

**Supported image formats:**
- `rwp_shop_X.Y.Z.tar` (recommended)
- `rwp_shop-X.Y.Z-amd64.tar` 
- `private-remnawave-telegram-shop-bot-X.Y.Z.tar`

---

## 🐛 Debug Mode

When running with `--debug`, full information is displayed:

```bash
lazarus --debug backup_full
```

**What's displayed:**
- System information (bash version, user, hostname)
- Configuration (paths, containers, settings)
- Telegram and remote storage settings
- Each operation progress with timestamps
- API HTTP response codes

**Log categories:** `BACKUP`, `LOCK`, `DISK`, `HEALTH`, `DB`, `TAR`, `ENC`, `VERIFY`, `UPLOAD`, `TG`, `REMOTE`, `SCAN`, `RESTORE`, `MIGRATE`

---

## 📁 File Structure

```
/opt/lazarus-backup/
├── config.env              # Configuration (chmod 600)
├── lazarus                 # Main script
└── backup/                 # Archive folder
    ├── lazarus_full_2025-01-01_04_00_00.tar.gz
    ├── lazarus_full_2025-01-01_04_00_00.tar.gz.version
    ├── lazarus_db_2025-01-01_12_00_00.tar.gz
    └── lazarus_db_2025-01-01_12_00_00.tar.gz.enc  # Encrypted

/opt/rwp-shop/MIGRATION/     # Migration work folder (created in bot folder)
├── 20250101_120000/         # Migration session
│   ├── export/              # Exported data
│   ├── import/              # Transformed data
│   ├── NOT_MIGRATED/        # Incompatible data
│   └── migration_report.txt # Migration report

/usr/local/bin/lazarus      # Script symlink
/var/log/lazarus_backup.log # Log file (rotates at >10MB)
/var/run/lazarus_backup.lock # Lock file (prevents parallel runs)
```

### Backup Name Format
```
lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS.tar.gz      # Normal
lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS.tar.gz.enc  # Encrypted
*.version                                                # Bot version cache
```

---

## 🗑️ Script Removal

For complete LAZARUS removal use menu option `666`:

```bash
lazarus
# Select: 666. Remove script (Uninstall)
```

Will be removed:
- `/opt/lazarus-backup/` (script and configuration)
- `/usr/local/bin/lazarus` (symlink)
- LAZARUS cron tasks

> ⚠️ Backup folder (`/opt/lazarus-backup/backup/`) is NOT removed automatically

---

## 🙏 Credits

Based on: https://github.com/distillium/remnawave-backup-restore

---

## 📄 License

MIT License — see [LICENSE](LICENSE)

---

<div align="center">

**Developed with ❤️ by [UnderGut](https://github.com/UnderGut)**

</div>
