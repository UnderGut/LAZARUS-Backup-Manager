# 🔄 LAZARUS Bot Update — Remnawave Telegram Shop Bot Update Guide

<div align="center">

### 🌐 Language / Язык

[![English](https://img.shields.io/badge/🇬🇧_English-green?style=for-the-badge)](README.en.md)
[![Русский](https://img.shields.io/badge/🇷🇺_Русский-blue?style=for-the-badge)](README.md)

![Version](https://img.shields.io/badge/LAZARUS-4.30.0--dev-orange)
![Bot](https://img.shields.io/badge/RWP--Shop-3.25.5+-blue)
![Platform](https://img.shields.io/badge/platform-Linux-blue)

**Complete guide for bot updates via LAZARUS Backup Manager**

</div>

---

## 📋 Table of Contents

1. [Quick Start](#-quick-start)
2. [Requirements for 3.25.5+](#-requirements-for-versions-3255)
3. [Update Methods](#-update-methods)
4. [Interactive Update](#-interactive-update)
5. [CLI Commands](#-cli-commands)
6. [Container Management](#-container-management)
7. [Supported Image Formats](#-supported-image-formats)
8. [Troubleshooting](#-troubleshooting)

---

## 🚀 Quick Start

### Update from Menu
```bash
lazarus
# Select: 6. Update bot
```

### Automatic Update (CLI)
```bash
lazarus upgrade
# or
lazarus bot upgrade
# or short form
lazarus -b -u
```

---

## ⚠️ Requirements for Versions 3.25.5+

Starting from version **3.25.5** Remnawave Telegram Shop Bot requires:

### 1. LICENSE_KEY

64-character license key in hex format (`[0-9a-f]{64}`).

**Where to get:** Official Remnawave channels

**Where to configure:**
- `.env` file in bot folder
- Or via LAZARUS menu during update

**Example in .env:**
```env
LICENSE_KEY=a1b2c3d4e5f6...64characters...
```

### 2. Machine-ID Volume

Docker volume for binding license to the server.

**Automatically added to compose.yaml:**
```yaml
volumes:
  - /etc/machine-id:/etc/machine-id:ro
```

### Check on Script Startup

LAZARUS automatically checks these requirements on startup:

```
╔══════════════════════════════════════════════════════════════╗
║            [!] ATTENTION: LICENSE_KEY REQUIRED               ║
╠══════════════════════════════════════════════════════════════╣
║  Bot version 3.25.5+ requires a license key.                 ║
║                                                              ║
║  Current status:                                             ║
║  • LICENSE_KEY:    ❌ NOT CONFIGURED                         ║
║  • machine-id:     ✅ Volume configured                      ║
╚══════════════════════════════════════════════════════════════╝
```

---

## 📦 Update Methods

### 1. From Loaded Docker Image (Recommended)

If image is already loaded in Docker (e.g., via `docker load`), LAZARUS will detect it automatically:

```
╔══════════════════════════════════════════════════════════════╗
║          NEW VERSION ALREADY LOADED IN DOCKER                ║
╠══════════════════════════════════════════════════════════════╣
║  In docker-compose:  3.24.0                                  ║
║  Loaded image:       3.25.5 (newer)                          ║
║                                                              ║
║  Can update without searching for tar files!                 ║
╚══════════════════════════════════════════════════════════════╝
```

### 2. From tar File

LAZARUS searches for tar files in following directories:
- `/root/`
- `/opt/`
- `/home/*/`
- `/tmp/`
- Bot folder (`BOT_PATH`)
- Current directory

---

## 🖥️ Interactive Update

### Step 1: Version Selection

```
═══════════════════════════════════════════════════
  BOT UPDATE — Remnawave Telegram Shop Bot
═══════════════════════════════════════════════════

Current version: 3.24.0

📦 Loaded Docker images:
  1. [NEW] rwp_shop:3.25.5

📄 Found tar files:
  2. [NEW] rwp_shop_3.26.0.tar (/root/)
  3.       rwp_shop_3.24.0.tar (/opt/)

Enter version number (or 0 to cancel):
```

### Step 2: Requirements Check (for 3.25.5+)

```
╔══════════════════════════════════════════════════════════════╗
║            REQUIREMENTS FOR VERSION 3.25.5+                  ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  • LICENSE_KEY:    ❌ NOT FOUND                              ║
║  • machine-id:     ✅ Volume configured                      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

Configure LICENSE_KEY now? [Y/n]:
```

### Step 3: Automatic Backup

Before update creates:
- **Full backup** — complete copy (DB + files)
- **DB backup** — separate database copy

### Step 4: Update

1. Load image (if from tar)
2. Update version in `compose.yaml`
3. Add LICENSE_KEY to `.env` (if configured)
4. Add machine-id volume (if missing)
5. Restart containers
6. Health-check

### Step 5: Tar Files Cleanup

```
🧹 Found installation tar files:
  1. /root/rwp_shop_3.25.5.tar (245 MB)
  2. /root/rwp_shop_3.24.0.tar (240 MB)

Delete these files to free space? [Y/n]:
```

---

## 💻 CLI Commands

### Bot Update

| Command | Description |
|---------|-------------|
| `lazarus upgrade` | Automatic update |
| `lazarus bot upgrade` | Same |
| `lazarus bot update` | Same |
| `lazarus -b -u` | Short form |

### Container Management

| Command | Description |
|---------|-------------|
| `lazarus bot up` | Start containers |
| `lazarus bot down` | Stop containers |
| `lazarus bot status` | Show status |
| `lazarus -b -s` | Short form for status |

### Examples

```bash
# Check container status
lazarus bot status

# Restart bot
lazarus bot down && lazarus bot up

# Update with auto-confirm (for scripts)
lazarus --yes upgrade
```

---

## 🐳 Container Management

### Container Status

```bash
lazarus bot status
```

Output:
```
═══════════════════════════════════════════════════
  CONTAINER STATUS
═══════════════════════════════════════════════════

📦 rwp_shop:        ✅ Running (Up 2 hours)
🗄️  rwp_shop_db:     ✅ Running (Up 2 hours)
🌐 rwp_shop_redis:  ✅ Running (Up 2 hours)

Bot version: 3.25.5
```

### Start Containers

```bash
lazarus bot up
```

Executes:
```bash
cd /opt/private-remnawave-telegram-shop-bot && docker compose up -d
```

### Stop Containers

```bash
lazarus bot down
```

Executes:
```bash
cd /opt/private-remnawave-telegram-shop-bot && docker compose down
```

---

## 📄 Supported Image Formats

| File Format | Example | Note |
|-------------|---------|------|
| `rwp_shop_X.Y.Z.tar` | `rwp_shop_3.25.5.tar` | Recommended |
| `rwp_shop-X.Y.Z-amd64.tar` | `rwp_shop-3.25.5-amd64.tar` | Legacy |
| `private-remnawave-telegram-shop-bot-X.Y.Z.tar` | `private-remnawave-telegram-shop-bot-3.25.5.tar` | Full name |

### Docker Images

| Image Name | Example |
|------------|---------|
| `rwp_shop` | `rwp_shop:3.25.5` |
| `private-remnawave-telegram-shop-bot` | `private-remnawave-telegram-shop-bot:3.25.5` |

---

## 🔧 Troubleshooting

### ❌ LICENSE_KEY Not Found

**Problem:** Bot doesn't start with license error

**Solution:**
1. Get LICENSE_KEY from official channels
2. Add to `.env`:
   ```env
   LICENSE_KEY=your64characterkey
   ```
3. Or configure via LAZARUS:
   ```bash
   lazarus
   # 6. Update bot → Configure LICENSE_KEY
   ```

### ❌ Machine-ID Volume Not Configured

**Problem:** License doesn't bind to server

**Solution:**
LAZARUS automatically adds volume during update. If needed manually:

```yaml
# compose.yaml
services:
  rwp_shop:
    volumes:
      - /etc/machine-id:/etc/machine-id:ro
```

### ❌ Image Not Found

**Problem:** No available versions for update

**Solution:**
1. Download tar file with image
2. Place in `/root/` or `/opt/`
3. Or load directly to Docker:
   ```bash
   docker load -i rwp_shop_3.25.5.tar
   ```

### ❌ Container Doesn't Start After Update

**Problem:** Health-check fails

**Solution:**
1. Check logs:
   ```bash
   docker logs rwp_shop
   ```
2. Verify LICENSE_KEY and machine-id
3. Restore from backup:
   ```bash
   lazarus restore
   ```

### ❌ Version Mismatch

**Problem:** Version in compose.yaml doesn't match loaded image

**Solution:**
LAZARUS automatically updates compose.yaml. If needed manually:

```yaml
# compose.yaml
services:
  rwp_shop:
    image: rwp_shop:3.25.5  # Specify needed version
```

---

## 📊 Logging

For detailed diagnostics use debug mode:

```bash
lazarus --debug bot upgrade
```

Log categories:
- `UPDATE` — update process
- `DOCKER` — Docker operations
- `COMPOSE` — compose.yaml changes
- `LICENSE` — license check
- `HEALTH` — container health-check

---

## 🔗 Related Documents

- [Main README](../README.en.md) — LAZARUS overview
- [Bedolaga Migration](../migration/README.en.md) — data transfer
- [Official RWP-Shop Documentation](https://remnawave-telegram-shop-bot-doc.vercel.app/ru/private/overview/)

---

<div align="center">

**LAZARUS Backup Manager v4.30.0-dev**

</div>
