# LAZARUS Backup Manager - AI Coding Agent Instructions

## Project Overview

**LAZARUS** is a comprehensive bash-based backup management system for Docker containers running Telegram bots (particularly `telegram-shop-bot` variants). It provides automated full system backups, selective DB/file backups, encryption, remote storage uploads, and Telegram notifications.

**North Star:** Надёжность и безопасность данных превыше всего. Любая операция должна быть атомарной, валидируемой и логируемой.

### Architecture Components

- **Single Monolithic Script** (`lazarus`): ~1663-line bash script handling all functionality
- **Configuration**: `config.env` (runtime settings) + `$INSTALL_DIR/config.env` (persistent storage)
- **Backup Storage**: `$BACKUP_DIR` (default: `/opt/lazarus-backup/backup/`)
- **Installation**: `/opt/lazarus-backup/lazarus` with symlink to `/usr/local/bin/lazarus`
- **Logging**: `/var/log/lazarus_backup.log` (rotated at 10MB)

### Key Data Flows

1. **Backup Pipeline**: Config validation → Path/container detection → Docker exec dump → Tar archival → Optional encryption → Remote upload → Telegram notification
2. **Restore Pipeline**: File selection with metadata caching → Decryption (if needed) → Archive extraction → Container restart → DB import
3. **Auto-cleanup**: Cron jobs trigger scheduled backups → Rotation logic (time-based or count-based) → Old file deletion

---

## Tech Stack & Dependencies

- **Language:** Bash 5+ (shebang: `#!/bin/bash`)
- **System deps:** `tar`, `gzip`, `openssl`, `docker compose` (v2), `curl`/`wget`, `cron`
- **GNU coreutils required:** `stat -c`, `du -h`, `find`, `date`
- **Target OS:** Linux (Debian/Ubuntu/CentOS), requires root
- **Config format:** `/opt/lazarus-backup/config.env` (KEY="value")
- **⚠️ Windows не поддерживается** — скрипт рассчитан исключительно на Linux

### PostgreSQL Database
- Assumes `pg_dumpall` available in container
- User specified by `$DB_USER` (default: "postgres")
- Import: `psql -U $DB_USER -d postgres` (recreates all databases)

### Key Variables & Files
```bash
INSTALL_DIR="/opt/lazarus-backup"        # Папка установки
CONFIG_FILE="$INSTALL_DIR/config.env"    # Конфигурация (chmod 600)
BACKUP_DIR="$INSTALL_DIR/backup"         # Папка с архивами
DB_VOLUME_NAME="remnawave-telegram-shop-db-data"  # Docker volume БД
DB_SERVICE_NAME="db"                     # Имя сервиса в docker-compose
KEYWORDS=("remnawave" "telegram-shop" "shop-bot" "shopbot")  # Авто-поиск
```

### Backup File Naming Convention
```
lazarus_full_YYYY-MM-DD_HH_MM_SS.tar.gz      # Полный бэкап
lazarus_full_YYYY-MM-DD_HH_MM_SS.tar.gz.enc  # Зашифрованный
lazarus_db_YYYY-MM-DD_HH_MM_SS.tar.gz        # Только БД
lazarus_files_YYYY-MM-DD_HH_MM_SS.tar.gz     # Только файлы
*.version                                     # Кэш версии бота (рядом с архивом)
```
**Внутри архива:** `bot_version.txt` — версия бота на момент создания бэкапа

---

## Core Architectural Rules

### DO's:
- Используй `print_message "TYPE" "message"` для всего вывода (INFO/SUCCESS/WARN/ERROR/ACTION)
- Используй `log_message "LEVEL" "message"` для записи в `/var/log/lazarus_backup.log`
- Создавай временные директории через `mktemp -d` и добавляй в `TEMP_DIRS+=()` для автоочистки
- Проверяй зависимости через `command -v` перед использованием
- Используй `acquire_lock` для неинтерактивных операций (cron)
- Передавай пароли через `env:VAR`, никогда через аргументы командной строки
- Используй `escape_markdown_v2()` при формировании Telegram-сообщений с пользовательскими данными

### DON'Ts:
- НЕ используй `echo` напрямую для пользовательского вывода — только `print_message`
- НЕ храни секреты в коде — только в `config.env` с `chmod 600`
- НЕ используй `eval` без крайней необходимости
- НЕ оставляй временные файлы — cleanup должен сработать через trap

---

## Code Style & Conventions

### Naming
```bash
# Глобальные переменные и константы — UPPER_SNAKE_CASE
REMOTE_STORAGE_TYPE="off"
MAX_BACKUPS_COUNT="100"

# Функции — lower_snake_case
create_backup() { ... }
send_telegram_document() { ... }
```

### Wrong vs Right

```bash
# ❌ WRONG: Прямой echo, нет логирования
echo "Backup created!"

# ✅ RIGHT: Через print_message + log_message
print_message "SUCCESS" "Бэкап создан: $FILE_FINAL ($SIZE)"
log_message "SUCCESS" "Backup created: $FILE_FINAL (type=$TYPE, size=$SIZE)"
```

```bash
# ❌ WRONG: Пароль в аргументах (виден в ps)
openssl enc -aes-256-cbc -pass pass:$PASSWORD ...

# ✅ RIGHT: Пароль через переменную окружения
export LAZARUS_ENC_PASS="$BACKUP_PASSWORD"
openssl enc -aes-256-cbc -pass env:LAZARUS_ENC_PASS ...
unset LAZARUS_ENC_PASS
```

### UI Language
- **Пользовательский интерфейс:** Русский язык
- **Логи и системные сообщения:** Английский язык
- **Комментарии в коде:** Русский (допускается английский для TODO/FIXME)

### Interactive vs Non-Interactive Mode
- Detected via TTY check: `[[ ! -t 0 ]]` (sets `IS_INTERACTIVE=false` for cron jobs)
- Colors only applied in interactive mode (prevents log clutter)
- Default behavior: prompt for missing config in interactive; skip in cron

---

## CLI Commands & Flags

### Manual Backup Commands
```bash
lazarus backup_full      # Full backup (DB + files)
lazarus backup_db        # Database only
lazarus backup_files     # Files only
lazarus cleanup          # Cleanup old backups (interactive)
lazarus restore          # Restore menu (interactive)
lazarus check_update     # Check remote version
```

### Global CLI Flags
- `--yes` / `-y`: Auto-confirm in non-interactive mode
- `--dry-run` / `-n`: Preview actions without deleting
- `--report-tg`: Send cleanup reports to Telegram

### Cron Integration
Scripts create cron entries with format: `# LAZARUS-JOB-{FULL|DB|FILES}` comments for tracking

---

## Project-Specific Patterns

### Backup Rotation Logic
- **Count-based**: `rotate_backups_by_count()` - keeps `MAX_BACKUPS_COUNT` newest files per category
- **Age-based**: `rotate_backups_by_age()` - deletes files older than `RETENTION_DAYS`
- **Categories**: Separate rotation for `lazarus_full`, `lazarus_db`, `lazarus_files` prefixes
- **Deletion Safety**: Always run preview first (DRY_RUN), uses strict glob patterns

### Encryption Implementation
- Uses OpenSSL AES-256-CBC with PBKDF2 and salt
- Password passed via `LAZARUS_ENC_PASS` env var (avoids `ps` leaks)
- Verification: Decrypt to `/dev/null` + gzip test before confirming success
- Telegram respects 50MB upload limit; larger files trigger warning message

### Large File Handling
- При архивации создаётся `skipped_files.txt` с файлами, превышающими `MAX_FILE_SIZE_MB`
- Большие файлы исключаются через `--exclude-from` в tar
- В Telegram-отчёте показывается количество и общий размер пропущенных файлов

### Versioning System
- **Inside archive**: `bot_version.txt` — версия бота (из Docker image tag)
- **Alongside archive**: `*.version` — кэш для быстрого отображения в UI без распаковки
- Версия извлекается из `docker inspect` → `Config.Image` → tag после `:`

### Container Auto-detection Workflow
1. Check running Docker containers matching keywords → extract `working_dir` label
2. If not found, search filesystem for `docker-compose.yml` files
3. Validate `docker compose` v2 (not legacy `docker-compose`)
4. Handle mismatches: prompt user to update if container name changed
5. **Фильтрация**: Исключаются контейнеры панели управления (`remnawave/backend`, `remnawave/subscription-page`)

### Message Routing
- **Console Output**: `print_message()` with color codes (INFO/SUCCESS/WARN/ERROR/ACTION)
- **Log File**: `log_message()` appends timestamped entries to `$LOG_FILE`
- **Telegram Errors**: Only ERROR level auto-sends via `send_telegram_notification()`
- **Documents**: `send_telegram_document()` with caption; fallback message if >50MB

---

## Key Functions Reference

| Function | Purpose |
|----------|---------|
| `create_backup "full\|db_only\|files_only"` | Основная логика бэкапа |
| `send_telegram_document` | Отправка файла в TG |
| `upload_to_remote` | Загрузка на FTP/WebDAV/Rclone |
| `rotate_backups_by_age` / `rotate_backups_by_count` | Ротация бэкапов |
| `save_config` / `load_or_create_config` | Персистентность настроек |
| `scan_system_for_bot` | Smart-поиск установки Remnawave |
| `escape_markdown_v2` | Экранирование для Telegram MarkdownV2 |
| `acquire_lock` | Блокировка для предотвращения параллельного запуска |
| `execute_restore` | Логика восстановления из бэкапа |

---

## Integration Points

### Docker API (Critical)
- `docker ps --format`: List running containers with labels
- `docker compose version`: Verify v2 available
- `docker compose up/down`: Container lifecycle in `$BOT_PATH`
- `docker exec`: DB dumps via `pg_dumpall -U $DB_USER`
- `docker volume rm`: Clear DB data during full restore
- `docker inspect`: Container metadata and working directory labels

### Telegram Bot API
- `sendMessage`: Text updates (MarkdownV2 parse mode)
- `sendDocument`: Backup file uploads (50MB max)
- Supports message threads via `message_thread_id` parameter

### Remote Storage Protocols
- **FTP/FTPS**: `curl -T` upload with basic auth
- **WebDAV**: `curl -X PUT` with `Depth: 0` PROPFIND validation
- **Rclone**: External tool integration; uses `rclone copy`

---

## Debugging & Testing

### Check Current Configuration
```bash
cat /opt/lazarus-backup/config.env
tail -f /var/log/lazarus_backup.log  # Real-time debug info
```

### Dry-Run Cleanup
```bash
lazarus --dry-run cleanup  # Preview deletions without removing files
```

### Container Discovery Debug
```bash
ls -l /usr/local/bin/lazarus           # Check symlink
docker ps                               # Verify Docker socket
docker inspect <container> | grep working_dir  # View compose labels
```

---

## Common Modification Points

### Adding New Backup Categories
1. Create new rotation prefix (e.g., `lazarus_config`)
2. Update `create_backup()` case statement
3. Add cron job setup in `setup_cron_task()`
4. Include in cleanup menu

### Custom Remote Storage Types
1. Extend `validate_remote_connection()` with new `type` case
2. Add protocol handling in `upload_to_remote()`
3. Document URL format in `configure_remote_storage()` menu

### Modifying Telegram Message Format
- Update `$CAPTION` construction in `create_backup()` (~line 1040)
- Keep hashtags for thread filtering on Telegram side
- Test with actual 50MB+ files to verify fallback messages

---

## AI Agent Guidelines (Что автогенерировать / избегать)

### DO's for AI:
- Концентрируйся на изменениях в `lazarus-backup` (единственный исполняемый файл)
- Сохраняй существующие переменные (`INSTALL_DIR`, `CONFIG_FILE`, `BACKUP_DIR`)
- Поддерживай совместимость с `save_config` / `load_or_create_config`
- При добавлении новых функций следуй паттерну `print_message` + `log_message`

### DON'Ts for AI:
- **НЕ меняй формат имён архивов** (`lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS.tar.gz`)
- **НЕ меняй логику `.version` файлов** — это используется для UI и внешнего мониторинга
- **НЕ удаляй маркеры cron-задач** (`# LAZARUS-JOB-{FULL|DB|FILES}`)
- **НЕ добавляй зависимости**, которых нет в базовой Linux-системе

### Known Limitations & Gotchas
- `uninstall_script()` — функция есть в меню (666), реализация присутствует но может быть неполной
- Docker Compose v1 (`docker-compose`) — **не поддерживается**, только v2 (`docker compose`)
- Telegram API limit: файлы >50MB отклоняются; скрипт отправляет текстовое уведомление вместо файла

---

## Changelog

### v4.16.3 (2025-12-27) — Текущий релиз ✅
**Усиление безопасности + Галерея интерфейса**

#### Изменения:
- **Шифрование**: Увеличено количество итераций PBKDF2 с 10,000 до **100,000** для защиты от brute-force атак
  - Затронуты все вызовы `openssl enc`: шифрование, верификация, расшифровка
  - Команда теперь: `openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000`
- **Screenshots Gallery**: Создана папка `screenshots/` с SVG-визуализациями всех экранов интерфейса
  - `01_main_menu.svg` — Главное меню
  - `02_settings.svg` — Меню настроек (19 пунктов)
  - `03_auto_backup.svg` — Настройка cron
  - `04_restore.svg` — Меню восстановления
  - `05_debug_mode.svg` — Debug режим
  - `06_backup_process.svg` — Процесс бэкапа
- **README**: Добавлена ссылка на документацию Remnawave Telegram Shop Bot

#### Файлы изменены:
- `lazarus-backup` — строки с `openssl enc` (3 места)
- `screenshots/` — новая папка с 6 SVG + README.md
- `README.md` — ссылка на документацию бота
- `assets/main_menu.svg` — обновлена версия

---

### v4.16.2 (2025-12-27)
**Debug режим + Исправление ротации**

#### Изменения:
- **Extended Debug Logging**: Добавлены переменные для управления выводом в debug режиме:
  - `SILENT_LOG` — `/dev/null` (обычный) или `/dev/stderr` (debug)
  - `CURL_SILENT` — `-s` (обычный) или `-v` (debug для TLS handshake)
  - `WGET_SILENT` — `-q` (обычный) или пусто (debug)
- **Исправлен баг ротации**: Префикс `db_only` → `lazarus_db`, `files_only` → `lazarus_files`
  - Ранее ротация искала файлы `lazarus_db_only_*` которых не существует
- **Исправлен вывод docker inspect**: JSON и "true" больше не засоряют debug логи
  - Изменено `&> "$SILENT_LOG"` на `> /dev/null 2> "$SILENT_LOG"` для команд с stdout-данными

#### Файлы изменены:
- `lazarus-backup` — ~15 строк (переменные debug, ротация, docker inspect)

---

### v4.16.1 и ранее
- Базовая функциональность backup/restore
- Telegram интеграция
- FTP/WebDAV/Rclone поддержка
- Cron автоматизация
- AES-256 шифрование (PBKDF2 10k iter)

---

## Release Process

При создании нового релиза:
1. Обновить `VERSION` в `lazarus-backup` (строка 4)
2. Обновить badge в `README.md`
3. Обновить версию в `assets/main_menu.svg`
4. Обновить версию в `screenshots/01_main_menu.svg` и `05_debug_mode.svg`
5. Обновить версию в `screenshots/README.md` (шапка)
6. **Добавить запись в этот Changelog** (copilot-instructions.md)
7. Создать GitHub Release с tag `vX.Y.Z`

---

**Version**: 4.16.3 | **Script Size**: ~2625 lines | **Last Updated**: 2025-12-27

