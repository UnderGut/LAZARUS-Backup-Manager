# 🔄 LAZARUS Migration — Bedolaga to RWP-Shop Migration

<div align="center">

![Version](https://img.shields.io/badge/version-1.0--beta-orange)
![Status](https://img.shields.io/badge/status-TESTING-yellow)
![Platform](https://img.shields.io/badge/platform-Linux-blue)

**🇷🇺 [Русская версия](README.md)**

**Complete guide for migrating data from Bedolaga Telegram bot to RWP-Shop (RemnaWave Panel Shop)**

</div>

---

## ⚠️ DISCLAIMER

> [!CAUTION]
> **THIS IS A TEST PRODUCT!**
> 
> This migration tool is in **beta testing** stage.
> 
> **By using this tool, you:**
> - ✅ Fully assume all risks associated with data migration
> - ✅ Understand that unforeseen situations may occur
> - ✅ Agree to resolve any issues independently
> 
> **The author DISCLAIMS RESPONSIBILITY for:**
> - ❌ Data loss during migration
> - ❌ Incomplete or incorrect data migration
> - ❌ Disruption of the target RWP-Shop system
> - ❌ Financial losses related to migration
> - ❌ Any direct or indirect damage
> 
> **ALWAYS make a full backup of BOTH systems before starting migration!**

---

## 📋 Table of Contents

1. [What is LAZARUS Migration](#-what-is-lazarus-migration)
2. [Migrator Features](#-migrator-features)
3. [Screenshot Gallery](#-screenshot-gallery)
4. [Migration Coverage Table](#-migration-coverage-table)
5. [What Does NOT Migrate](#-what-does-not-migrate)
6. [Migration Preparation](#-migration-preparation)
7. [Migration Process](#-migration-process)
8. [After Migration](#-after-migration)
9. [Troubleshooting](#-troubleshooting)

---

## 🎯 What is LAZARUS Migration

**LAZARUS Migration** is a module of the LAZARUS Backup Manager tool designed to transfer data from the **Bedolaga** Telegram bot to **RWP-Shop** (RemnaWave Panel Shop).

### Why is this needed?

If you used the Bedolaga bot and want to switch to RWP-Shop, you need to:
- Transfer users with their Telegram IDs
- Preserve subscriptions and their dates
- Migrate transaction history
- Keep promo codes
- Transfer the referral system
- Configure the bot with the same settings

**LAZARUS Migration does all this automatically!**

---

## ✨ Migrator Features

| Feature | Description |
|---------|-------------|
| 🔄 **Automatic Migration** | Full 10-step migration cycle with minimal user involvement |
| 📊 **Step-by-step Migration** | Manual execution of each stage for full control |
| 🩺 **Healthcheck** | Data integrity verification before and after migration |
| 💾 **Auto-backup** | Automatic DB backup creation before import |
| 📁 **Incompatible Data Preservation** | Data without RWP-Shop equivalent saved to separate folder |
| ⚙️ **Settings Migration** | Transfer of bot token, channels, tariffs from .env |
| 📈 **Reports** | Detailed migration result reports |

---

## 📸 Screenshot Gallery

### 1️⃣ Migration Main Menu

<p align="center">
  <img src="assets/menu_migration.svg" alt="Migration main menu" width="600">
</p>

### 2️⃣ Bedolaga Archive Selection

<p align="center">
  <img src="assets/menu_select_archive.svg" alt="Archive selection" width="600">
</p>

### 3️⃣ Archive Analysis

<p align="center">
  <img src="assets/menu_analysis.svg" alt="Archive analysis" width="600">
</p>

### 4️⃣ Automatic Migration (in progress)

<p align="center">
  <img src="assets/menu_auto_progress.svg" alt="Migration progress" width="600">
</p>

### 5️⃣ Pre-import Warning

<p align="center">
  <img src="assets/menu_import_warning.svg" alt="Import warning" width="600">
</p>

### 6️⃣ Migration Results

<p align="center">
  <img src="assets/menu_results.svg" alt="Migration results" width="600">
</p>

### 7️⃣ NOT_MIGRATED Folder

<p align="center">
  <img src="assets/menu_not_migrated.svg" alt="NOT_MIGRATED" width="600">
</p>

---

## 📊 Migration Coverage Table

### Total Coverage: **~88%**

| Category | Bedolaga | RWP-Shop | Coverage | Status |
|----------|----------|----------|:--------:|:------:|
| **👤 Users** | | | **~95%** | ✅ |
| ├─ telegram_id | telegram_id | telegram_id | 100% | ✅ |
| ├─ username | username | username | 100% | ✅ |
| ├─ first_name | first_name | first_name | 100% | ✅ |
| ├─ last_name | last_name | last_name | 100% | ✅ |
| ├─ language_code | language_code | language_code | 100% | ✅ |
| ├─ is_bot | — | — | — | ➖ |
| ├─ balance | balance_kopeks | — | 0% | ❌ |
| ├─ referral_code | referral_code | referral_code | 100% | ✅ |
| ├─ referred_by | referrer_id | referrer_telegram_id | 100% | ✅ |
| ├─ created_at | created_at | created_at | 100% | ✅ |
| └─ autopay_days_before | autopay_days_before | — (global) | 0% | ⚠️ |
| **📋 Subscriptions** | | | **~90%** | ✅ |
| ├─ subscription_id | id | id | 100% | ✅ |
| ├─ user_id | user_telegram_id → | user_telegram_id | 100% | ✅ |
| ├─ remnawave_uuid | remnawave_username | subscription_uuid | 100% | ✅ |
| ├─ tariff_id | tariff_id | plan_id | 100% | ✅ |
| ├─ start_date | start_date | start_date | 100% | ✅ |
| ├─ end_date | end_date | end_date | 100% | ✅ |
| ├─ status | is_active | is_active | 100% | ✅ |
| ├─ device_limit | device_limit | — (in tariff) | 0% | ⚠️ |
| └─ auto_renew | auto_renew | auto_renew | 100% | ✅ |
| **💳 Transactions** | | | **~85%** | ✅ |
| ├─ transaction_id | id | id | 100% | ✅ |
| ├─ user_id | user_telegram_id → | user_telegram_id | 100% | ✅ |
| ├─ amount | amount | amount | 100% | ✅ |
| ├─ currency | — | currency | 100% | ✅ |
| ├─ status | status | status | 100% | ✅ |
| ├─ payment_system | payment_system | provider | 100% | ✅ |
| ├─ external_id | external_id | provider_payment_id | 100% | ✅ |
| ├─ created_at | created_at | created_at | 100% | ✅ |
| └─ metadata | metadata | — | 0% | ⚠️ |
| **🎟️ Promo Codes** | | | **~100%** | ✅ |
| ├─ code | code | code | 100% | ✅ |
| ├─ type | subscription_days | subscription / discount | 100% | ✅ |
| ├─ value | subscription_days | duration_days / discount | 100% | ✅ |
| ├─ usage_limit | max_usages | max_usages | 100% | ✅ |
| ├─ usage_count | usage_count | usage_count | 100% | ✅ |
| ├─ expires_at | valid_until | end_date | 100% | ✅ |
| └─ bonus_kopeks | bonus_kopeks | — | 0% | ❌ |
| **👥 Referrals** | | | **~80%** | ✅ |
| ├─ referrer_id | referrer_telegram_id | referrer_telegram_id | 100% | ✅ |
| ├─ referred_id | referred_telegram_id | referred_telegram_id | 100% | ✅ |
| ├─ bonus | referral_bonus | referral_bonus_days | ~80% | ⚠️ |
| └─ created_at | created_at | created_at | 100% | ✅ |
| **⚙️ Settings** | | | **~85%** | ✅ |
| ├─ BOT_TOKEN | TELEGRAM_BOT_TOKEN | TELEGRAM_BOT_TOKEN | 100% | ✅ |
| ├─ CHANNEL_ID | PRIVATE_CHANNEL | CHANNEL_ID | 100% | ✅ |
| ├─ NEWS_CHANNEL | NEWS_CHANNEL | NEWS_CHANNEL_ID | 100% | ✅ |
| ├─ ADMIN_IDS | ADMIN_TELEGRAM_IDS | TELEGRAM_ADMIN_IDS | 100% | ✅ |
| ├─ TARIFFS | — (in DB) | — (in DB) | 100% | ✅ |
| └─ TEXTS | — | — | ~70% | ⚠️ |

---

## ❌ What Does NOT Migrate

### Data Without RWP-Shop Equivalent

| Bedolaga Data | Reason | What Happens |
|---------------|--------|--------------|
| **User balances** (`balance_kopeks`) | RWP-Shop doesn't support money balances | Saved to `NOT_MIGRATED/user_balances.csv` |
| **Balance promo codes** (`bonus_kopeks > 0`) | RWP-Shop only supports days/discounts | Saved to `NOT_MIGRATED/promocodes_balance_type.csv` |
| **Individual autopay_days_before** | In RWP-Shop this is a global setting | Saved to `NOT_MIGRATED/user_autopay_settings.csv` |
| **Subscription device_limit** | In RWP-Shop limit is in Remnawave tariff | Not transferred |
| **Transaction metadata** | No equivalent field | Not transferred |
| **TRAFFIC_PACKAGES_CONFIG** | Traffic purchase feature doesn't exist | Not transferred |
| **Referral bonuses in kopeks** | RWP-Shop uses days | Converted with precision loss |

### Architectural Differences

| Aspect | Bedolaga | RWP-Shop |
|--------|----------|----------|
| **Balances** | Money (kopeks) | Not supported |
| **Promo codes** | 3 types (days, balance, discount) | 2 types (days, discount) |
| **Autopay** | Individual setting | Global setting |
| **Device limit** | In subscription | In Remnawave tariff |
| **Referral bonuses** | In kopeks | In subscription days |

---

## 🔧 Migration Preparation

> [!TIP]
> **Recommended time:** 30-60 minutes for preparation + 5-15 minutes for migration

### 📋 Pre-start Checklist

Make sure you have everything needed:

- [ ] **Server with RWP-Shop** — bot must be installed and running
- [ ] **Bedolaga archive** — `backup_*.tar.gz` or `backup_*.tar.zip` file
- [ ] **SSH access** to RWP-Shop server
- [ ] **30-60 minutes** of free time
- [ ] **Archive password** (if archive is encrypted)

---

### Step 1: System Requirements Check

#### Minimum Requirements:
| Component | Requirement | Check |
|-----------|-------------|-------|
| OS | Linux (Ubuntu 20.04+, Debian 10+, CentOS 8+) | `cat /etc/os-release` |
| Docker | 20.10+ | `docker --version` |
| Docker Compose | 2.0+ | `docker compose version` |
| Bash | 4.0+ | `bash --version` |
| Free space | 500MB+ | `df -h /` |
| RWP-Shop | Installed and running | `docker ps \| grep rwp` |

#### Check Commands:

```bash
# 1. Check Docker version
docker --version
# Expected output: Docker version 24.x.x or higher

# 2. Check Docker Compose
docker compose version
# Expected output: Docker Compose version v2.x.x

# 3. Check that RWP-Shop is running
docker ps | grep -E "rwp|shop|postgres"
# Should show containers: rwp-shop-bot, rwp-shop-postgres

# 4. Check DB connection
docker exec rwp-shop-postgres psql -U shop -d shop -c "SELECT 1;"
# Expected output: ?column? = 1

# 5. Check free space
df -h /
# Should have at least 500MB free
```

---

### Step 2: Place Bedolaga Archive

> [!IMPORTANT]
> **Bedolaga backup archive must be located next to the RWP-Shop docker-compose file.**
>
> Usually this is `/opt/rwp-shop/` or `/opt/private-remnawave-telegram-shop-bot/`

#### Upload archive to server:

```bash
# If archive is on your computer — upload via SCP:
scp ~/Downloads/backup_20250101_120000.tar.zip root@your-server:/opt/rwp-shop/

# Or via SFTP (FileZilla, WinSCP, etc.)
```

#### Verify:

```bash
# Go to RWP-Shop folder
cd /opt/rwp-shop  # or /opt/private-remnawave-telegram-shop-bot

# Make sure archive is in place
ls -la backup_*.tar.*
```

> [!NOTE]
> **How to get Bedolaga archive?**
> Refer to Bedolaga documentation or contact developers for backup creation instructions.

---

### Step 3: Create RWP-Shop Backup (REQUIRED!)

> [!CAUTION]
> **CRITICALLY IMPORTANT!** Before migration ALWAYS make RWP-Shop backup!
> If something goes wrong — you can rollback.

#### Method 1: Via LAZARUS (recommended)

```bash
# 1. Start LAZARUS
cd /opt/lazarus-backup
./lazarus

# 2. Select: 1. Create backup
# 3. Select: 4. Full backup (DB + files)
# 4. Wait for completion

# Backup will be saved to /opt/lazarus-backup/backup/
```

#### Method 2: Manual PostgreSQL Backup

```bash
# Create database dump
docker exec rwp-shop-postgres pg_dump -U shop -d shop > /root/rwp_shop_backup_$(date +%Y%m%d_%H%M%S).sql

# Verify file was created
ls -la /root/rwp_shop_backup_*.sql
```

---

### Step 4: Install LAZARUS Backup Manager

```bash
# New installation (DEV version with migration)
bash <(curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/dev/lazarus-backup)

# LAZARUS will be installed to /opt/lazarus-backup
```

#### If LAZARUS is already installed:

```bash
# Update to dev version with migration (backups will be preserved)
curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/dev/lazarus-backup -o /opt/lazarus-backup/lazarus && chmod +x /opt/lazarus-backup/lazarus
```

---

### Step 5: Verify Bedolaga Archive

Make sure the archive is valid:

```bash
# 1. Go to RWP-Shop folder (where archive is located)
cd /opt/rwp-shop

# 2. Check that file exists
ls -la backup_*.tar.gz
# or
ls -la backup_*.tar.zip

# 3. Check size (should be > 1MB for real data)
du -h backup_*.tar.*

# 4. Check archive contents
# For .tar.gz:
tar -tzvf backup_*.tar.gz | head -20

# For .tar.zip (encrypted):
unzip -l backup_*.tar.zip
```

#### What should be inside the archive:

```
backup_20250101_120000/
├── database.json          ← Main data file (REQUIRED)
├── database_backups/      ← Table backups folder
│   ├── users.json
│   ├── subscriptions.json
│   ├── transactions.json
│   └── ...
├── config.env             ← Bot settings
└── .env                   ← Alternative settings file
```

---

### Step 6: Password Preparation (for encrypted archives)

If your archive has `.tar.zip` extension — it's encrypted.

#### Check if password is needed:

```bash
# Try to unpack without password
unzip -t backup_*.tar.zip

# If shows "incorrect password" — password is needed
```

> [!NOTE]
> **Where to find password?**
> You should have received the archive password when creating the Bedolaga backup.
> Refer to Bedolaga documentation if you don't know the password.

---

### 🎯 Final Pre-migration Checklist

Before starting migration, ensure:

| # | Item | Status |
|---|------|--------|
| 1 | RWP-Shop is running (`docker ps`) | ☐ |
| 2 | RWP-Shop backup created | ☐ |
| 3 | Bedolaga archive in RWP-Shop folder | ☐ |
| 4 | LAZARUS installed | ☐ |
| 5 | Archive password known (if needed) | ☐ |
| 6 | 30-60 minutes of free time | ☐ |

**All ready? Proceed to [Migration Process](#-migration-process)!**

---

## 🚀 Migration Process

### 🎬 Quick Start (for the impatient)

```bash
# 1. Start LAZARUS
cd /opt/lazarus-backup
./lazarus

# 2. Select: 5 → Migration
# 3. Enter: YES (accept disclaimer)
# 4. Select archive (or enter path)
# 5. Select: 1 → Automatic migration
# 6. Confirm: y
# 7. Enter: IMPORT (when prompted)
# 8. Select: y (migrate settings) or n (skip)
# 9. Done! 🎉
```

---

### Method 1: Automatic Migration (recommended)

**Suitable for:** Most cases when fast and safe migration is needed.

#### 📖 Step-by-step Instructions

##### 1. Start LAZARUS

```bash
cd /opt/lazarus-backup
./lazarus
```

You'll see the LAZARUS main menu.

##### 2. Navigate to Migration Menu

Enter `5` and press Enter:

```
Select action: 5
```

##### 3. Accept Disclaimer

You'll be shown migration risk warning. Read carefully and enter `YES`:

```
Enter YES to continue: YES
```

> [!WARNING]
> If you enter anything else — you'll return to main menu.

##### 4. Select Bedolaga Archive

Script will automatically find archives in RWP-Shop bot folder and standard directories.

Select archive number or enter `0` for manual path input:

```
Found archives:
  1. 📦 2025-01-01 12:00 (245 MB) ← RECOMMENDED
  2. 📦 2024-12-31 18:30 (240 MB)
  3. 🔒 2024-12-30 06:00 (238 MB)  ← encrypted

File number or command (Enter - Back): 1
```

> [!TIP]
> 🔒 means archive is encrypted — password will be required.

##### 5. Enter Password (if archive is encrypted)

If archive is password protected:

```
⚠️ Archive is password protected

Enter password: ********
✅ Password correct
```

##### 6. Migration Main Menu

After selecting archive, you'll see migration menu. Select `1`:

```
─── QUICK START ───
 1. 🚀 AUTOMATIC MIGRATION (recommended)
    Will transfer all data with confirmation at each stage

Selection (Enter - Back): 1
```

##### 7. Confirm Start

Script will show migration plan. Enter `y`:

```
The following actions will be performed:

  [1/10] 🏥 Archive and DB Healthcheck
  [2/10] 🔍 Bedolaga Archive Analysis
  [3/10] 💾 RWP-Shop DB Backup Creation
  [4/10] 📤 Data Export from Archive
  [5/10] 💰 Balance Analysis and Processing
  [6/10] 🔄 Data Transformation
  [7/10] 📥 Import to RWP-Shop
  [8/10] ⚙️  Settings Migration (optional)
  [9/10] 📁 Save Non-transferable Data
  [10/10] 📋 Report Generation + Final Healthcheck

Continue? (y/N): y
```

##### 8. Watch the Process

Migration runs automatically. You'll see progress:

```
✅ [1/10] Archive and DB Healthcheck
✅ [2/10] Bedolaga Archive Analysis
   → Users: 1247
   → Subscriptions: 1089
   → Transactions: 3456
✅ [3/10] RWP-Shop DB Backup Creation
   → /opt/lazarus-backup/backup/pre_migration_20250101_120000.sql
✅ [4/10] Data Export from Archive
✅ [5/10] Balance Analysis
   ⚠️ 847 users with non-zero balance
✅ [6/10] Data Transformation
```

##### 9. Confirm Import (IMPORTANT!)

Before import, script will show warning and ask for confirmation:

```
┌────────────────────────────────────────────────────────────────────┐
│  ⚠️ WARNING! DATABASE MODIFICATION                                │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Changes will now be made to RWP-Shop DB:                         │
│                                                                    │
│  • Container: rwp-shop-postgres                                   │
│  • Database: shop                                                 │
│                                                                    │
│  🔒 Current DB backup created:                                     │
│     /opt/lazarus-backup/backup/pre_migration_20250101_120000.sql  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘

Enter 'IMPORT' to confirm: IMPORT
```

> [!CAUTION]
> Enter **IMPORT** in uppercase! Any other input will cancel import.

##### 10. Settings Migration (optional)

After data import, script will offer to migrate settings:

```
[10/10] Settings migration...

Do you want to transfer settings from Bedolaga to RWP-Shop?
  • Will transfer: bot token, channels, tariffs, texts, etc.
  • Existing .env settings will be replaced

Migrate settings? (y/n): y
```

- **y** — transfer bot token, channels, admins, etc.
- **n** — keep current RWP-Shop settings

##### 11. Migration Complete

```
═══════════════════════════════════════════════════════════════════
  ✅ MIGRATION COMPLETE!
═══════════════════════════════════════════════════════════════════

  Execution time: 47s
  Work folder: MIGRATION/20250101_120000
  Non-transferable data: MIGRATION/20250101_120000/NOT_MIGRATED

⚠️ Don't forget to:
  • Verify bot operation
  • Restart bot: docker compose restart
```

#### ✅ What to Do Right After Migration

After automatic migration completes, proceed to **"After Migration"** section below.

---

### Method 2: Step-by-step Migration

**Suitable for:** Experienced users who want to control each stage.

#### Execution Order:

```
1. Select archive (item 8)
2. Archive analysis (item 6)
3. Healthcheck (item 7)
4. Data export (item 2)
5. Transformation (item 3)
6. Import (item 4)
7. Settings migration (item 5)
```

#### Detailed Description of Each Item:

| Item | Name | Description |
|:----:|------|-------------|
| **1** | Automatic migration | Executes all steps sequentially |
| **2** | Data export | Extracts JSON from archive, converts to CSV |
| **3** | Transformation | Converts Bedolaga data → RWP-Shop format |
| **4** | Import | Loads data into RWP-Shop PostgreSQL |
| **5** | Settings migration | Transfers token, channels, tariffs from .env |
| **6** | Archive analysis | Shows archive data statistics |
| **7** | Healthcheck | Verifies CSV and DB integrity |
| **8** | Select archive | Changes archive for migration |

---

## ✅ After Migration

### 📋 Required Post-migration Checklist

| # | Action | Command | Status |
|---|--------|---------|--------|
| 1 | Restart bot | `docker compose restart` | ☐ |
| 2 | Check logs for errors | `docker compose logs bot --tail 100` | ☐ |
| 3 | Open bot in Telegram | Press /start | ☐ |
| 4 | Check your profile | Press "Profile" | ☐ |
| 5 | Check subscriptions | Press "My subscriptions" | ☐ |
| 6 | Review NOT_MIGRATED | See command below | ☐ |

---

### Step 1: Restart Bot (REQUIRED!)

```bash
# Go to RWP-Shop folder
cd /opt/rwp-shop
# or
cd /opt/private-remnawave-telegram-shop-bot

# Restart all containers
docker compose restart

# Or just the bot
docker compose restart bot
```

### Step 2: Check Logs

```bash
# Watch logs in real-time
docker compose logs -f bot

# View last 100 lines
docker compose logs bot --tail 100

# Search for errors
docker compose logs bot 2>&1 | grep -i error
```

**What to look for in logs:**
- ✅ Successful startup messages
- ✅ No errors
- ❌ `Error`, `error` — errors (require attention)
- ❌ `Exception`, `exception` — exceptions

### Step 3: Verify in Telegram

1. **Open the bot** in Telegram
2. **Press /start** or "Start" button
3. **Verify:**
   - Profile displays
   - Subscriptions are visible
   - Buttons work

### Step 4: Verify Data in DB

```bash
# Connect to PostgreSQL
docker exec -it rwp-shop-postgres psql -U shop -d shop

# Check user count
SELECT COUNT(*) as users FROM customer;

# Check subscription count
SELECT COUNT(*) as subscriptions FROM customer WHERE subscription_uuid IS NOT NULL;

# Check promo codes
SELECT COUNT(*) as promocodes FROM promo;

# Check transactions
SELECT COUNT(*) as purchases FROM purchase;

# Exit
\q
```

### Step 5: Check Non-migrated Data

After migration, work folder is created in RWP-Shop bot folder:

```bash
# Go to RWP-Shop folder
cd /opt/rwp-shop  # or /opt/private-remnawave-telegram-shop-bot

# View migration work folders
ls -la MIGRATION/

# View what wasn't transferred (in latest migration folder)
ls -la MIGRATION/*/NOT_MIGRATED/

# Read description
cat MIGRATION/*/NOT_MIGRATED/README.txt

# View user balances (if any)
head -20 MIGRATION/*/NOT_MIGRATED/user_balances.csv
```

---

### 💰 What to Do with User Balances

RWP-Shop doesn't have money balances. If users had money on their balance:

#### Option 1: Issue Promo Codes

```bash
# View balances
cat MIGRATION/*/NOT_MIGRATED/user_balances.csv

# Format: telegram_id,username,balance_kopeks,balance_rub
# Example: 123456789,username,15000,150.00
```

Create promo codes for subscription days at a rate (e.g., 100₽ = 30 days).

#### Option 2: Contact Users

Send a message to users with large balances through the bot or directly.

#### Option 3: Leave As Is

Balances will be lost. Suitable if amounts are small.

---

### 🎟️ What to Do with Balance Promo Codes

```bash
# View balance promo codes
cat MIGRATION/*/NOT_MIGRATED/promocodes_balance_type.csv
```

These promo codes gave money to balance. They don't work in RWP-Shop.

**Solution:** Create new promo codes for subscription days with similar codes.

---

## 🔧 Troubleshooting

### 📋 Quick Diagnostics

| Symptom | Probable Cause | Quick Solution |
|---------|----------------|----------------|
| "Archive not found" | Wrong path | Check path, use full path |
| "DB unavailable" | PostgreSQL not running | `docker compose up -d postgres` |
| "Wrong password" | Incorrect archive password | Check case, try another password |
| "JSON error" | Corrupted archive | Check integrity: `tar -tzvf archive.tar.gz` |
| Long import | Lots of data | Normal, wait 5-10 min for 10k+ records |
| Bot won't start | Wrong token | Check BOT_TOKEN in .env |

---

### ❌ Error: "Archive not found"

**Problem:** Script can't find Bedolaga archive.

**Causes:**
- Wrong file path
- File moved or deleted
- No read permissions

**Solution:**
```bash
# 1. Check that file exists
ls -la /path/to/archive.tar.gz

# 2. Check permissions
stat /path/to/archive.tar.gz

# 3. Specify full absolute path
./lazarus
# → Migration → Select archive → Enter path

# 4. If file is on another server - copy to RWP-Shop folder
scp user@old-server:/path/archive.tar.gz /opt/rwp-shop/
```

---

### ❌ Error: "RWP-Shop DB unavailable"

**Problem:** Cannot connect to PostgreSQL.

**Causes:**
- Postgres container not running
- Wrong connection data in config.env
- Docker network not configured

**Solution:**
```bash
# 1. Check containers
docker ps | grep postgres

# 2. If not running - start
cd /opt/rwp-shop  # path to RWP-Shop
docker compose up -d postgres

# 3. Test connection manually
docker exec -it rwp-shop-postgres psql -U shop -d shop -c "SELECT 1"

# 4. If network error - restart all containers
docker compose down && docker compose up -d

# 5. Check settings in LAZARUS config.env
cat /opt/lazarus-backup/config.env | grep RWP
```

**Correct config.env settings:**
```bash
RWP_POSTGRES_CONTAINER="rwp-shop-postgres"
RWP_POSTGRES_USER="shop"
RWP_POSTGRES_DB="shop"
```

---

### ❌ Error: "Archive password incorrect"

**Problem:** Cannot decrypt archive.

**Solution:**
```bash
# 1. Check encryption type
file /path/to/archive.tar.gz

# 2. Try to unpack manually
openssl enc -aes-256-cbc -d -pbkdf2 -in archive.tar.gz.enc -out archive.tar.gz

# 3. If gpg:
gpg --decrypt archive.tar.gz.gpg > archive.tar.gz
```

**Password hints:**
- Password is case-sensitive
- Check for spaces at beginning/end
- Look in bash history: `history | grep backup`
- Check environment variables on old server

---

### ❌ Error: "Duplicates on import"

**Problem:** Uniqueness errors on insert (duplicate key).

**Cause:** Data was already partially imported earlier.

**Solution:**

Migration uses `ON CONFLICT ... DO UPDATE` mode, so duplicates should update automatically. If error still occurs:

```bash
# Option 1: Rollback to backup and retry
docker exec -i rwp-shop-postgres psql -U shop -d shop < /opt/lazarus-backup/backup/pre_migration_XXXXXX.sql

# Option 2: Clear tables (CAUTION!)
docker exec -it rwp-shop-postgres psql -U shop -d shop

# In psql:
TRUNCATE customer, purchase, promo, referral_link CASCADE;
\q

# Then retry migration
./lazarus
```

---

### ❌ Error: "Invalid JSON format"

**Problem:** JSON in archive is corrupted or has unexpected structure.

**Solution:**
```bash
# 1. Check archive integrity
tar -tzvf archive.tar.gz

# 2. Extract and check JSON
cd /tmp
tar -xzf /path/to/archive.tar.gz

# 3. Validate JSON
cat database_backups/users.json | python3 -m json.tool > /dev/null
# If error — file is corrupted

# 4. View structure
cat database_backups/users.json | python3 -m json.tool | head -50
```

---

### ⏱️ Problem: Long Import

**Symptom:** Import takes a long time (more than 5 minutes).

**Cause:** Large amount of data + ON CONFLICT checks.

**This is normal for:**
- 5,000+ users: 2-5 minutes
- 10,000+ users: 5-10 minutes
- 50,000+ records: 15-30 minutes

**What to do:**
- **Wait** — process is running normally
- Don't interrupt import!
- Monitor progress via log: `tail -f /var/log/lazarus_backup.log`

---

### 🔄 How to Rollback Migration

If something went wrong, you can restore DB to pre-migration state:

```bash
# 1. Find backup (created automatically before import)
ls -la /opt/lazarus-backup/backup/ | grep pre_migration

# Example output:
# -rw-r--r-- 1 root root 12M Jan 15 12:00 pre_migration_20250115_120000.sql

# 2. Stop bot
cd /opt/rwp-shop
docker compose stop bot

# 3. Restore DB
docker exec -i rwp-shop-postgres psql -U shop -d shop < /opt/lazarus-backup/backup/pre_migration_20250115_120000.sql

# 4. Start bot
docker compose start bot

# 5. Verify
docker compose logs bot --tail 50
```

---

### 🤔 Bot Won't Start After Migration

**Symptoms:**
- Bot doesn't respond in Telegram
- Errors in logs

**Common causes:**

#### 1. Wrong Bot Token
```bash
# Check token
cd /opt/rwp-shop
cat .env | grep BOT_TOKEN

# Token should be in format: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz
```

#### 2. Container Conflict
```bash
# Stop everything
docker compose down

# Remove old containers
docker container prune -f

# Start again
docker compose up -d
```

#### 3. DB Issues
```bash
# Check connection
docker exec -it rwp-shop-postgres psql -U shop -d shop -c "SELECT COUNT(*) FROM customer"
```

---

### 📋 Logs and Debugging

```bash
# LAZARUS logs
tail -100 /var/log/lazarus_backup.log

# RWP-Shop bot logs
docker compose logs bot --tail 100

# PostgreSQL logs
docker compose logs postgres --tail 100

# All logs with error search
docker compose logs 2>&1 | grep -i "error\|exception\|fail"
```

---

## 📞 Support

If you encounter problems:

1. **Check logs:**
   ```bash
   tail -100 /var/log/lazarus_backup.log
   ```

2. **Create GitHub Issue:**
   - Attach error log
   - Specify LAZARUS version
   - Describe reproduction steps

3. **Telegram:** [@UnderGut](https://t.me/UnderGut)

---

<div align="center">

**LAZARUS Backup Manager** — Reliable backup and migration for RWP-Shop

Made with ❤️ by [UnderGut](https://github.com/UnderGut)

</div>
