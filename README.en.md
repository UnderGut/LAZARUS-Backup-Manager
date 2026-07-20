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
[![Version](https://img.shields.io/badge/version-6.0.0-green?style=flat-square)](https://github.com/UnderGut/LAZARUS-Backup-Manager/releases)
[![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

**LAZARUS** is a backup system for **Remnawave Panel** and the **[Remnawave Telegram Shop Bot](https://remnawave-telegram-shop-bot-doc.vercel.app/ru/private/overview/)**: panel, bot, infra-billing, and the AI-support knowledge base — all in a single tool. Everything is discovered **automatically** (by images and Docker labels — container names and paths do not matter), destructive operations are protected against data loss, there is **panel migration to a new server**, and two menu modes — **Simple** (for newcomers: 4 items + a step-by-step wizard) and **Advanced** (full control).

---

## 🚀 Quick start

One command — install and run:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup)
```

Or install into the system:

```bash
curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup -o /usr/local/bin/lazarus && chmod +x /usr/local/bin/lazarus && lazarus
```

> 💡 The script installs to `/opt/lazarus-backup/lazarus-backup` and creates a symlink `/usr/local/bin/lazarus` (the `lazarus` command). You can leave the config **empty** — on first run the wizard asks only for what's necessary, and everything else is discovered automatically. To check what was found: `lazarus stacks`.

---

## 🆕 What's new in 6.0

- **Panel is the primary target.** LAZARUS backs up the **Remnawave Panel** (directory + database + cluster roles), not just the bot. The bot became an optional secondary target.
- **Stack auto-discovery.** Panel, bot, and infra-billing are discovered by Docker images and compose labels — **you don't need to specify container names or paths**. `lazarus stacks` shows what was found.
- **Panel migration to another server** — `lazarus migrate panel`: pulls the panel from the old server over SSH (read-only), deploys it on the new one, and provides a cutover checklist. An SSH key is **not required** — you can enter a root password or paste the key directly into the wizard.
- **Sidecars** — infra-billing, the AI-support knowledge base (pgvector), and arbitrary paths outside the panel directory (e.g. `certwarden`) are included in the backup automatically, each with its own rollback point on restore.
- **Two menu modes** — Simple (4 items) and Advanced, with a unified design system (the "0 = Back" invariant, destructive actions always on "9", statuses `✓` / `— off`).
- **One Telegram notification when backing up both targets.** If both the panel and the bot are backed up, you get a **single** album message with both archives and a combined summary (targets, sizes, versions, encryption, cloud upload status) instead of two separate ones.
- ⚠️ **Bot update removed.** LAZARUS only handles backup / restore / migration. Update the bot with its own tooling.

---

## 📚 Guides

Step-by-step guides for each scenario live in **[docs/](docs/README.md)** (written in Russian):

| | | |
|---|---|---|
| [Install](docs/install.md) | [Backup](docs/backup.md) | [Restore](docs/restore.md) |
| **[Panel migration](docs/panel-migration.md)** | [Disaster recovery](docs/disaster-recovery.md) | [Remote backup over SSH](docs/remote-backup.md) |
| [Cloud storage](docs/remote-storage.md) | [Encryption](docs/encryption.md) | [Automation (cron)](docs/automation.md) |
| [Sidecars](docs/sidecars.md) | [Troubleshooting](docs/troubleshooting.md) | [Uninstall](docs/uninstall.md) |

---

## ✨ Features

### 🛡️ Data-loss protection
The script is designed to **not lose data** even on failures:
- **Restore with a rollback point** — before destroying the database, a snapshot of the LIVE database is taken (with a content check). The destructive step runs only when the snapshot is valid; on import failure — auto-rollback + containers brought back up. Any early guard failure brings the stack back up (panel/bot are never left offline).
- **Verify before delete** — every archive (full and incremental) is verified (for `.enc` — a full decrypt round-trip) BEFORE the plaintext is deleted and success is reported.
- **Encryption is mandatory** — if a password is set and encryption failed, the unencrypted archive is NOT uploaded (cron — abort; interactive — explicit confirmation). Intermediate plaintext dumps (including during remote backup) are wiped with `shred` on exit/interrupt.
- **Rotation never zeroes out** — size-rotation never deletes the newest backup and cascades to clean up orphaned incrementals.
- **Upload with verify** — S3/FTP/WebDAV/rclone check the size on the remote BEFORE `delete-local` removes the local copy; if the size is unverified, the local copy is left untouched.
- **Identification by role, not by name** — containers are identified by image/label/`DATABASE_URL`, and a destructive action on a "foreign" stack is rejected fail-closed.
- **Serialization under flock** — parallel backups (cron + manual) don't corrupt each other.

### 💾 Backup
- **Auto-discovery** — panel, bot, infra-billing, and the knowledge base database are discovered on their own (images + Docker labels); names don't matter.
- **4 backup types** — Full (DB + files), DB only, Files only, **Incremental** (changed files + a fresh DB dump relative to the last full).
- **Sidecars** — cluster roles (`globals`), infra-billing (`billing_*.sql`), the AI-support knowledge base (`kb_*.sql`, pgvector), additional paths outside the panel directory (`extra_*.tar`, e.g. `certwarden`).
- **AES-256-CBC + HMAC-SHA256** — envelope encrypt-then-MAC (v2), detects a wrong password and byte tampering BEFORE decryption.
- **gzip / zstd** — gzip (everywhere), zstd (opt-in, smaller and faster on SQL dumps). Old archives are restored regardless of the current format (detected by magic bytes).
- **Version in the filename** — if a bot is present on the server, its version is added to the name (`__vX.Y.Z`); on a panel-only server the suffix is omitted.
- **v1→v2 migration** — `lazarus migrate-v2` to convert old archives.

### 🖥️ Backup targets
- **panel** — Remnawave Panel (recommended): the `/opt/remnawave` directory (`.env`, compose, certificates, nginx) + database + cluster roles.
- **bot** — the `rwp_shop` Telegram shop bot (+ knowledge base sidecar).
- **both targets** — panel and bot on the same server, in a single run (archives separated by the `lazarus_panel_*` / `lazarus_*` namespaces).
- **remote target over SSH** — backing up a panel/bot from ANOTHER server (pull over SSH).

### 🔀 Panel migration to a new server
`lazarus migrate panel` — migrates the Remnawave Panel from the old server to this one (run it on the **new** server):
- the source is read over SSH **read-only** — the old panel keeps running until you decide to switch over;
- pulls the panel directory + DB dump + roles (globals) + infra-billing;
- an SSH key is **not required** — the wizard asks for the host and lets you enter a root password (installs `sshpass`), accept a key path, or **paste the key directly into the terminal**;
- both installation layouts are supported: the official one (docs.rw) and eGames (panel + node on the same server);
- after migration — a cutover checklist (DNS, nodes, certificates, webhooks) with "Check → Switch → Finish" phases.

### ☁️ Storage and delivery
- **Telegram** — files and notifications with premium emoji + retry × 3.
- **S3-compatible** — AWS, MinIO, RustFS, Yandex Cloud, Selectel, **Cloudflare R2** (`region=auto`), **Backblaze B2**, custom endpoint. After upload — `head-object` verify (size + ETag), cleanup of dangling multipart uploads on failure.
- **FTP / FTPS / WebDAV / Rclone** — with retry and a step-by-step setup; post-upload size verify.
- **Rotation** — by time (days) or count; a separate rotation on S3 (`S3_RETENTION_DAYS`, touches only its own archives).

### 🔔 Telegram alerts
- **Severity bands** — CRITICAL 🔴 / ERROR ❌ / WARN ⚠️ / INFO ℹ️, hashtags on the first line for quick search.
- **Disk monitoring** — a TG alert on fill-up (WARN 90% / CRITICAL 95%, configurable; on CRITICAL the backup is aborted).

### ⚙️ Automation
- **Cron from the menu** — schedule Full / DB only / Files only, including "every N minutes".
- **flock** — protection against parallel runs (cron + manual).
- **Timeout wrappers** — a hard limit on pg_dump / tar / encrypt / restore (60 min by default, configurable; `0` = no limit).
- **Logrotate** — `/etc/logrotate.d/lazarus` (weekly, rotate 8, compress).
- **Self-update** — `lazarus update` (updates the LAZARUS script itself).

### 🩺 Diagnostics
- **`lazarus stacks`** — the server's discovered stacks (panel / infra-billing / bot) + config↔reality discrepancies.
- **`lazarus diag`** — a full system snapshot for troubleshooting.
- **`lazarus verify`** — an integrity check of all archives (gzip + zstd + MAC) with a TG alert on corruption.
- **`lazarus report [weekly|daily|month]`** — backup-activity statistics.
- **Debug** (`--debug`) and **Dry-run** (`--dry-run`).

---

## 📋 Requirements

- Linux (Debian/Ubuntu/CentOS), bash 5+, root.
- Docker Compose v2 (`docker compose`, not `docker-compose`).
- **Required:** tar (≥1.31), gzip, curl/wget, openssl.
- **Optional:** `zstd` (for `COMPRESSION=zstd`), `aws` CLI v1/v2 (for S3/R2/B2), `rclone` (for Rclone storages), `sshpass` (for password-based panel migration — the wizard offers to install it).

---

## 🖥️ Interface

> 📸 Screenshot gallery: [screenshots/README.md](screenshots/README.md)

Two menu modes (toggled with item **99**):

- **Simple mode** — 4 items (Create backup · Restore · Configure · Migrate panel) + a step-by-step setup wizard. For those seeing a terminal for the first time.
- **Advanced mode** — a dashboard (what we back up · protection · latest backups · auto-backup) + full access to all settings, rotation, storages, and schedules.

A unified design system: **0 = Back** always, destructive actions only on "9" (and only when there's something to disable), statuses `✓ …` / `— off`.

---

## 💻 CLI commands

```bash
lazarus                       # interactive menu
lazarus stacks                # discovered stacks: panel / infra-billing / bot

# Backup
lazarus backup create         # full backup (DB + files)     ·  -B -c
lazarus backup db             # DB only                        ·  -B -d
lazarus backup files          # files only                     ·  -B -f
lazarus backup inc            # incremental (changes + DB)
lazarus backup list           # list of backups                ·  -B -l
lazarus backup_full|backup_db|backup_files   # legacy aliases (for cron)

# Restore and maintenance
lazarus restore               # restore menu (with date filter)
lazarus cleanup               # rotate old backups
lazarus skipped               # files skipped in the last backup
lazarus verify                # integrity check of all archives (MAC + gzip/zstd)
lazarus migrate-v2            # convert old v1 archives to v2 (HMAC)
lazarus report weekly|daily|month   # TG activity report
lazarus diag                  # full system snapshot

# Panel migration
lazarus migrate panel [--from user@host] [--port 22] [--key /path] [--path /opt/remnawave]

# Bot container management
lazarus bot status            # status + version + healthcheck   ·  -b -s
lazarus bot up | down         # start / stop the bot containers
lazarus bot logs [N]          # last N log lines                 ·  -b -l

# S3 and script update
lazarus s3 test | list | upload <file>   # check / list / upload          ·  -S
lazarus update                # update the LAZARUS script ITSELF

# Telegram Premium emoji
lazarus emoji probe <id> | scan
```

> ⚠️ **Restore** requires confirmation by word: `RESTORE` (restore), `DELETE` (delete volume), `DROP` (DROP SCHEMA). Without input — auto-cancel after 60 s. Non-interactively you need **both** flags: `--yes --i-know-what-i-am-doing`. By default `.env` is preserved, the DB volume is **not** deleted, and DROP SCHEMA is **not** executed.

### Global flags

| Flag | Description |
|------|----------|
| `--yes`, `-y` | Auto-confirm (for cron) |
| `--dry-run`, `-n` | Preview without executing |
| `--debug`, `-d` | Verbose logging |
| `--report-tg` | Send a report to Telegram |
| `--i-know-what-i-am-doing` | Allow destructive actions in non-interactive mode |
| `--restore-include-env` | Restore `.env` from the backup (preserved by default) |
| `--restore-drop-volume` | Delete the DB Docker volume on restore |
| `--restore-drop-schema` | Run `DROP SCHEMA` before the DB import |

### Examples

```bash
lazarus --yes backup db                 # cron mode: DB backup
lazarus --debug backup create           # with a verbose log
lazarus --dry-run cleanup               # preview cleanup

# Daily full backup (cron)
0 4 * * *  /usr/local/bin/lazarus --yes backup_full >> /var/log/lazarus_backup.log 2>&1
# Weekly verify (cron)
0 4 * * 0  /usr/local/bin/lazarus --report-tg verify >> /var/log/lazarus_backup.log 2>&1
```

---

## ⚙️ Configuration

The config **can be left empty** — run `lazarus`, and the wizard plus auto-discovery (`lazarus stacks`) will set everything up on their own. File: `/opt/lazarus-backup/config.env` (chmod 600).

- **Template with the essentials:** [config.env.sample](config.env.sample)
- **Full reference of all keys** (targets, panel, sidecars, SSH backup from another server, S3, timings, rotation): **[CONFIG_REFERENCE.md](CONFIG_REFERENCE.md)**

The essentials in brief:

| What | Key | Default |
|---|---|---|
| What to back up | `BACKUP_TARGET` | `panel` (or `bot`) |
| Second target (panel + bot on the same server) | `BACKUP_SECONDARY` | — |
| Telegram | `BOT_TOKEN`, `CHAT_ID` | — |
| How long to keep locally | `RETENTION_DAYS` | `7` |
| How long to keep on S3 | `S3_RETENTION_DAYS` | `0` (don't delete) |
| Compression | `COMPRESSION` | `gzip` (or `zstd`) |
| Encryption password | `.password` file (chmod 600) | — |

> 💡 You **don't need** to specify the paths and container names of the panel/bot/billing — they are discovered automatically and self-heal on discrepancy. Fill them in only for exotic layouts.

---

## ☁️ Remote storages

Configured in the menu: **Settings → Remote storage** (step-by-step wizard).

```
S3 / R2 / B2   via aws-cli (R2 — region=auto)
WebDAV         https://webdav.yandex.ru/backups
FTP / FTPS     ftp://backup.example.com/backups
Rclone         gdrive:backups   (requires a configured rclone)
```

---

## ♻️ Restore

`lazarus restore` (or menu → Restore). The safe restore order:

1. A snapshot of the LIVE database is taken (a rollback point).
2. Containers are stopped (for db-only — only the application; the DB stays up for the import).
3. Files are synced from the archive; on a version conflict (the archive is older than a freshly installed panel) — an explicit choice: data only / keep the current infra / an exact copy.
4. `DROP SCHEMA` + DB import; on failure — auto-rollback from the snapshot and the stack brought back up.
5. Optionally — importing infra-billing and the knowledge base (each with its own rollback point).
6. The stack is brought back up (a fresh connection pool).

Restore is available only for a **local** target (a remote SSH target is restored on its own server).

---

## 🔄 Update

```bash
lazarus update        # update the LAZARUS script itself (check + install the new version)
```

If the auto-check doesn't trigger (CDN cache) — update manually:

```bash
curl -sSL "https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup" -o /opt/lazarus-backup/lazarus-backup && chmod +x /opt/lazarus-backup/lazarus-backup
```

> ⚠️ Updating the **bot** from LAZARUS was removed (as of 6.0) — update the bot with its own tooling. `lazarus update` updates only LAZARUS itself.

---

## 🐛 Debug

```bash
lazarus --debug backup create
```

Log categories: `BACKUP`, `LOCK`, `DISK`, `HEALTH`, `DB`, `TAR`, `ENC`, `VERIFY`, `UPLOAD`, `TG`, `REMOTE`, `SCAN`, `RESTORE`, `MIGRATE`.

---

## 📁 File structure

```
/opt/lazarus-backup/
├── config.env              # configuration (chmod 600)
├── .password               # encryption password (chmod 600, optional)
├── lazarus-backup          # main script
└── backup/                 # archives
    ├── lazarus_panel_full_2026-01-01_04_00_00__vX.Y.Z.tar.gz     # panel, full
    ├── lazarus_full_2026-01-01_04_00_00__vX.Y.Z.tar.gz           # bot, full
    └── ..._db_..._..__vX.Y.Z.tar.gz.enc                          # encrypted

/usr/local/bin/lazarus       # symlink to the script
/var/log/lazarus_backup.log  # log (logrotate rotation)
```

Naming format (the `__vX.Y.Z` suffix is the bot version, if a bot is present on the server):
- full / db / files: `lazarus[_panel]_{full|db|files}_YYYY-MM-DD_HH_MM_SS__vX.Y.Z.tar.{gz|zst}[.enc]`
- incremental: `lazarus[_panel]_inc_<ts>__base_<full_ts>__vX.Y.Z.tar.{gz|zst}[.enc]` (references the base full via `__base_`)

Panel backups have the `lazarus_panel_` prefix, the bot — `lazarus_`.

---

## 🗑️ Uninstall

Menu item **666** (Advanced mode) removes `/opt/lazarus-backup/`, the symlink, and LAZARUS cron jobs.

> ⚠️ The backups folder (`/opt/lazarus-backup/backup/`) is not removed automatically.

---

## 🙏 Acknowledgements

Based on: https://github.com/distillium/remnawave-backup-restore

## 📄 License

MIT License — see [LICENSE](LICENSE)

---

<div align="center">

**Developed with ❤️ by [UnderGut](https://github.com/UnderGut)**

</div>
