<p align="center">
  <img src="assets/main_menu.svg?v=1" alt="LAZARUS main menu" width="600">
</p>

# LAZARUS Backup Manager

<div align="center">

### 🌐 Language / Язык

[![English](https://img.shields.io/badge/🇬🇧_English-blue?style=for-the-badge)](README.en.md)
[![Русский](https://img.shields.io/badge/🇷🇺_Русский-green?style=for-the-badge)](README.md)

</div>

[![Bash](https://img.shields.io/badge/Language-Bash_5+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/github/license/UnderGut/LAZARUS-Backup-Manager?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-5.6.4-green?style=flat-square)](https://github.com/UnderGut/LAZARUS-Backup-Manager/releases)
[![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

**LAZARUS** — продвинутая система резервного копирования для **[Remnawave Telegram Shop Bot](https://remnawave-telegram-shop-bot-doc.vercel.app/ru/private/overview/)** с поддержкой шифрования, облачных хранилищ и умной автоматизацией.

---

## 🚀 Быстрый старт

Одна команда — установка и запуск:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup)
```

Или установить в систему:

```bash
curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup -o /usr/local/bin/lazarus && chmod +x /usr/local/bin/lazarus && lazarus
```

> 💡 Скрипт автоматически установится как `/opt/lazarus-backup/lazarus-backup` и создаст symlink `/usr/local/bin/lazarus` (команда `lazarus`)

### 🔄 Принудительное обновление

Если автоматическая проверка обновлений не работает (кэширование CDN), обновите вручную:

```bash
# Обновить через jsDelivr CDN (быстрее)
curl -sSL "https://cdn.jsdelivr.net/gh/UnderGut/LAZARUS-Backup-Manager@main/lazarus-backup?t=$(date +%s)" -o /opt/lazarus-backup/lazarus-backup && chmod +x /opt/lazarus-backup/lazarus-backup

# Или через GitHub напрямую (надёжнее)
curl -sSL "https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup" -o /opt/lazarus-backup/lazarus-backup && chmod +x /opt/lazarus-backup/lazarus-backup
```

> 💡 Параметр `?t=$(date +%s)` добавляет timestamp для обхода кэша CDN

> ℹ️ **Имена файлов:** в репо файл называется `lazarus-backup`, на сервере устанавливается как `/opt/lazarus-backup/lazarus-backup`, команда пользователя — `lazarus` (symlink). При обновлении старых установок (`/opt/lazarus-backup/lazarus`) — `install_script` автоматически мигрирует на новое имя.

---

## ✨ Возможности

### Резервное копирование
- **Smart Scan** — автоматически находит бота в Docker (поддержка `rwp_shop`, `telegram-shop`, `shopbot`)
- **4 типа бэкапов** — Full (БД + файлы), DB Only, Files Only, **Incremental** (только изменённые файлы + DB)
- **AES-256-CBC + HMAC-SHA256** — encrypt-then-MAC envelope (v2), защита от targeted tampering, wrong-password detect ДО decrypt
- **gzip / zstd** компрессия — gzip (default, везде), zstd (opt-in, ~3× меньше + ~2× быстрее на SQL дампах)
- **Manifest tracking** — каждый full backup включает `manifest.txt` (path + size + mtime) для incremental detection
- **Версионирование** — каждый бэкап содержит версию бота на момент создания
- **Умная фильтрация** — исключение больших файлов и папок (logs, node_modules, .git)
- **v1→v2 миграция** — `lazarus migrate-v2` для конверсии старых архивов

### Хранение и доставка
- **Telegram** — отправка файлов и уведомлений с premium emoji + retry × 3 для transient errors
- **FTP / FTPS / WebDAV / Rclone** — облачные хранилища с retry и пошаговой настройкой
- **S3-совместимые** — AWS, MinIO, RustFS, Yandex Cloud, Selectel, **Cloudflare R2** (region=auto), **Backblaze B2**, custom
- **Integrity verify** — `head-object` size+ETag после S3 upload, multipart orphan cleanup при fail
- **Auto S3-fallback** — если backup >50 MB и remote storage настроен, в TG идёт INFO-summary вместо ERROR
- **Умная ротация** — по времени (дни) или количеству файлов

### Заметные алерты в Telegram
- **Severity bands** — CRITICAL 🔴 / ERROR ❌ / WARN ⚠️ / INFO ℹ️
- **Hashtags на первой строке** — `#alert #critical` / `#warning` / `#info` для quick-scan
- **Disk monitoring** — TG alert при заполнении диска (WARN 90% / CRITICAL 95%, конфигурируемо)
- **Bot update notification** — INFO alert при обнаружении новой версии бота

### Автоматизация
- **Cron интеграция** — настройка расписания из меню
- **Блокировка параллельного запуска** — предотвращение конфликтов при запуске из cron
- **Авто-обновление** — проверка и установка новых версий скрипта
- **Timeout-обёртки** — hard-limit на pg_dump/tar/encrypt/restore (60 мин default, configurable)
- **Logrotate** — system-level через `/etc/logrotate.d/lazarus` (weekly, rotate 8, compress)

### Управление ботом
- **Восстановление** — Full / DB / Files из любого бэкапа
- **Date filter** — поиск backup'ов по дате (`25.12` / `25.12.2026` / ISO) в restore меню
- **Timer-confirm** — для destructive операций (`RESTORE`/`DELETE`/`DROP`) auto-cancel через 60 сек
- **Обновление бота** — установка новой версии из tar-файла с автобэкапом
- **Health-check** — проверка контейнеров перед операциями

### Диагностика
- **`lazarus diag`** — полный snapshot системы (versions, containers, backups, disk, cron, settings, errors)
- **`lazarus verify`** — integrity check всех архивов (gzip+zstd) с TG alert при corruption
- **`lazarus report [weekly|daily|month]`** — статистика backup-активности с success rate
- **`lazarus emoji probe <id> | scan`** — diagnostics Premium custom emoji
- **Debug режим** — полное логирование всех операций (`--debug`)
- **Dry-run** — предпросмотр действий без выполнения (`--dry-run`)

---

## 📋 Требования

- Linux (Debian/Ubuntu/CentOS), bash 5+, root права
- Docker Compose v2 (`docker compose`, не `docker-compose`)
- **Обязательно:** tar (≥1.31), gzip, curl/wget, openssl
- **Опционально:**
  - `zstd` (для `COMPRESSION=zstd` — `apt install zstd`)
  - `aws` CLI v1/v2 (для S3/R2/B2 хранилищ)
  - `rclone` (для Rclone-совместимых хранилищ)

---

## 🖥️ Интерфейс

> 📸 Полная галерея скриншотов: [screenshots/README.md](screenshots/README.md)

### Главное меню
<p align="center">
  <img src="assets/main_menu.svg?v=1" alt="LAZARUS main menu" width="600">
</p>

---

## ⚙️ Конфигурация

Файл конфигурации: `/opt/lazarus-backup/config.env` (chmod 600)

### Telegram (опционально)

> 💡 **Настройки Telegram опциональны.** Если не настроены, скрипт покажет уведомление в меню, но будет работать без отправки уведомлений.

| Параметр | Описание | Пример |
|----------|----------|--------|
| `BOT_TOKEN` | Токен Telegram бота | `123456:ABC-DEF1234...` |
| `CHAT_ID` | ID чата для уведомлений | `-1001234567890` |
| `TG_MESSAGE_THREAD_ID` | ID топика (для групп с темами) | `12345` или пусто |
| `SEND_TO_TELEGRAM` | Уведомления в TG | `true` / `false` |
| `TG_SEND_FILE` | Отправлять архив в TG | `true` / `false` |

### Бот и Docker

| Параметр | Описание | Пример |
|----------|----------|--------|
| `BOT_PATH` | Путь к docker-compose бота | `/opt/private-remnawave-telegram-shop-bot` |
| `BOT_CONTAINER_NAME` | Имя контейнера бота | `rwp_shop` |
| `DB_CONTAINER_NAME` | Имя контейнера БД | `rwp_shop_db` |
| `DB_USER` | Пользователь PostgreSQL | `postgres` |
| `IGNORE_MISMATCH` | Игнорировать несоответствие контейнера | `true` / `false` |

> 💡 Скрипт автоматически читает `POSTGRES_USER` и `POSTGRES_DB` из `.env` файла бота

### Ротация бэкапов

| Параметр | Описание | Пример |
|----------|----------|--------|
| `DELETE_MODE` | Режим удаления | `time` (по дням) / `count` (по количеству) |
| `RETENTION_DAYS` | Хранить N дней (если mode=time) | `7` |
| `MAX_BACKUPS_COUNT` | Макс. количество (если mode=count) | `100` |
| `MAX_BACKUP_SIZE_MB` | Лимит общего размера бэкапов в MB | `0` (без лимита) |

### Расписание (cron формат)

| Параметр | Описание | Пример |
|----------|----------|--------|
| `SCHEDULE_FULL` | Расписание полного бэкапа | `0 4 * * *` (ежедневно 04:00) |
| `SCHEDULE_DB` | Расписание бэкапа БД | `*/15 * * * *` (каждые 15 мин) |
| `SCHEDULE_FILES` | Расписание бэкапа файлов | пусто (отключено) |

### Удалённое хранилище

| Параметр | Описание | Пример |
|----------|----------|--------|
| `REMOTE_STORAGE_TYPE` | Тип хранилища | `off` / `ftp` / `ftps` / `webdav` / `rclone` / `s3` |
| `REMOTE_STORAGE_URL` | URL сервера (FTP/WebDAV/Rclone) | `ftp://backup.server.com/backups/` |
| `REMOTE_STORAGE_USER` | Логин (FTP/WebDAV) | `backup_user` |
| `REMOTE_STORAGE_PASS` | Пароль (FTP/WebDAV) | `secret123` |
| `SEND_TO_REMOTE` | Отправлять на удалённый сервер | `true` / `false` |

#### S3-совместимые провайдеры (`REMOTE_STORAGE_TYPE=s3`)

Поддержка через `aws-cli`: **AWS S3, MinIO, RustFS, Yandex Cloud, Selectel, Cloudflare R2, Backblaze B2** + любой custom endpoint. Wizard настройки в `lazarus` → Удалённое хранилище → S3.

| Параметр | Описание | Пример |
|----------|----------|--------|
| `S3_ENDPOINT` | URL endpoint | `https://<account-id>.r2.cloudflarestorage.com` (R2) |
| `S3_BUCKET` | Имя bucket | `lazarus-backups` |
| `S3_PATH` | Префикс внутри bucket | `prod/server1/` |
| `S3_ACCESS_KEY` | Access Key ID | `AKIA...` |
| `S3_SECRET_KEY` | Secret Access Key | — |
| `S3_REGION` | Регион (для R2 **обязательно** `auto`) | `us-east-1` / `auto` |

После upload — автоматический `head-object` verify (size + ETag для не-multipart). При сбое — abort висящих multipart parts (защита от billing waste у AWS).

### Шифрование, компрессия и фильтрация

| Параметр | Описание | Пример |
|----------|----------|--------|
| `BACKUP_PASSWORD` | Пароль AES-256 шифрования | `MySecretPass123` или пусто |
| `BACKUP_PASSWORD_FILE` | Файл с паролем шифрования (chmod 600) | `/opt/lazarus-backup/.password` |
| `COMPRESSION` | Алгоритм сжатия | `gzip` (default) / `zstd` |
| `MAX_FILE_SIZE_MB` | Макс. размер файла в архиве (MB) | `1` (пропуск больших) |
| `EXCLUDE_DIRS` | Исключить папки (`,`/`;` для путей с пробелами) | `node_modules, my data/cache, .git` |

> ⚠️ Пароль сохраняется в отдельном файле `BACKUP_PASSWORD_FILE` для безопасности и корректной работы спецсимволов.

#### zstd vs gzip

| Метрика | gzip | zstd |
|---|---|---|
| Размер 35 MB БД-дампа | 36 MB | **12 MB** (~3× меньше) |
| Время создания | 17-22 сек | **9 сек** (~2× быстрее) |
| Зависимость | везде | `apt install zstd` / `dnf install zstd` |
| Multi-thread | нет | да |

Переключение: меню → Настройки → 26 (Компрессия) → auto-install через apt/dnf если нужен. Старые `.tar.gz.enc` продолжают восстанавливаться независимо от текущего COMPRESSION (per-file format detection по magic bytes).

### Timeouts (защита от вечно висящего cron)

| Параметр | Default | Описание |
|----------|---------|----------|
| `PG_DUMP_TIMEOUT_SEC` | `3600` (60 мин) | Hard-limit на pg_dump + safety snapshot |
| `TAR_TIMEOUT_SEC` | `3600` | Hard-limit на tar create |
| `ENCRYPT_TIMEOUT_SEC` | `1800` (30 мин) | Hard-limit на openssl encrypt |
| `RESTORE_TIMEOUT_SEC` | `3600` | Hard-limit на restore (zcat\|psql) |

`0` = отключить таймер (для очень больших БД >10 GB). При превышении — SIGTERM, через 30 сек SIGKILL.

### Disk monitoring

| Параметр | Default | Описание |
|----------|---------|----------|
| `DISK_WARN_PERCENT` | `90` | TG WARN alert + backup продолжается |
| `DISK_CRITICAL_PERCENT` | `95` | TG CRITICAL alert + backup ОТМЕНЁН |

#### v2 envelope (HMAC encrypt-then-MAC)

С v5.1.0 новые шифрованные backup'ы используют **v2 envelope**: `LAZ2` magic + AES-256-CBC ciphertext + HMAC-SHA256. Это даёт:

- **Защита от targeted ciphertext-подмены** — атакующий с write-доступом к `.enc` файлу не может незаметно подменить байты (HMAC поймает).
- **Wrong password detect ДО decrypt** — MAC проверяется первым, openssl не вызывается с неправильным ключом (защита от padding-oracle gadgets).
- **Обратная совместимость** — старые v1 backup'ы (`Salted__`) расшифровываются как раньше с WARN.

**Миграция старых backup'ов:**

```bash
lazarus migrate-v2               # interactive prompt
lazarus --yes migrate-v2         # автоматически (для cron)
```

Конверсия атомарна: `decrypt v1 → encrypt v2 → verify → atomic rename`. Оригинал удаляется только после успешной верификации v2.

---

## 💻 CLI команды

### Основные команды

```bash
lazarus                       # Интерактивное меню
lazarus restore               # Меню восстановления (с date filter)
lazarus cleanup               # Очистка старых бэкапов
lazarus skipped               # Просмотр пропущенных файлов последнего бэкапа
lazarus migrate-v2            # Конверсия v1 → v2 envelope (HMAC)
lazarus --yes migrate-v2      # Автоматическая миграция (для cron)
lazarus verify                # Integrity check всех архивов (gzip+zstd, MAC)
lazarus report weekly         # TG-отчёт за неделю (counts/size/errors/success rate)
lazarus report daily|month    # Отчёт за сутки / месяц
lazarus diag                  # Полный snapshot системы (для troubleshooting)
lazarus diag > diag.txt       # Сохранить отчёт для шаринга
lazarus emoji probe <id>      # Проверить Premium custom emoji ID
lazarus emoji scan            # Извлечь ID Premium emoji из последних TG сообщений
lazarus check_update          # Проверка обновлений скрипта
lazarus s3 test               # Проверить подключение к S3
lazarus s3 list               # Список файлов в S3 bucket
lazarus s3 upload <file>      # Загрузить файл в S3
```

> ⚠️ **ВАЖНО (Restore):** восстановление требует подтверждения коротким словом
> `RESTORE` для restore-операции, `DELETE` для удаления volume, `DROP` для DROP SCHEMA.
> При отсутствии ввода — auto-cancel через 60 секунд.
> Для неинтерактивного режима нужно **оба** флага: `--yes --i-know-what-i-am-doing`.
> По умолчанию `.env` сохраняется (не перезаписывается).
> Удаление volume БД не выполняется по умолчанию — используйте `--restore-drop-volume`.
> Очистка схемы БД (`DROP SCHEMA`) требует `--restore-drop-schema`.

### 🆕 Резервное копирование (v4.30.0+)

```bash
lazarus backup create    # Полный бэкап (БД + файлы + manifest)
lazarus backup db        # Только база данных
lazarus backup files     # Только файлы
lazarus backup inc       # Incremental (changed files + DB) — относительно последнего full
lazarus backup list      # Список бэкапов

# Короткие флаги
lazarus -B -c            # = lazarus backup create
lazarus -B -d            # = lazarus backup db
lazarus -B -f            # = lazarus backup files
lazarus -B -i            # = lazarus backup inc

# Legacy команды (совместимость)
lazarus backup_full      # = lazarus backup create
lazarus backup_db        # = lazarus backup db
lazarus backup_files     # = lazarus backup files
```

### 🆕 Управление ботом (v4.30.0+)

```bash
lazarus upgrade          # Авто-обновление бота (non-interactive)
lazarus bot up           # Запустить контейнеры бота
lazarus bot down         # Остановить контейнеры бота  
lazarus bot status       # Статус контейнеров
lazarus bot upgrade      # Авто-обновление бота

# Короткие флаги
lazarus -b -u            # = lazarus bot upgrade
lazarus -b -s            # = lazarus bot status
```

### Глобальные флаги

| Флаг | Описание |
|------|----------|
| `--yes`, `-y` | Автоподтверждение (для cron) |
| `--dry-run`, `-n` | Предпросмотр без выполнения |
| `--debug`, `-d` | Режим отладки (подробное логирование) |
| `--report-tg` | Отправить отчёт в Telegram |
| `--i-know-what-i-am-doing` | Разрешить деструктивные операции (non-interactive) |
| `--restore-include-env` | Восстановить .env из бэкапа (по умолчанию сохраняется) |
| `--restore-drop-volume` | Удалить Docker volume БД при восстановлении |
| `--restore-drop-schema` | Выполнить DROP SCHEMA перед импортом БД |

### Примеры использования

```bash
# Автоматический бэкап из cron
lazarus --yes backup_full

# Предпросмотр очистки
lazarus --dry-run cleanup

# Отладка с полным выводом
lazarus --debug backup_db

# Очистка с отчётом в Telegram
lazarus --yes --report-tg cleanup

# Еженедельный verify integrity (cron)
0 4 * * 0 /usr/local/bin/lazarus --report-tg verify >> /var/log/lazarus_backup.log 2>&1

# Еженедельный отчёт активности (cron)
0 5 * * 0 /usr/local/bin/lazarus report weekly >> /var/log/lazarus_backup.log 2>&1

# Diagnostics для шаринга при проблемах
lazarus diag > /tmp/diag.txt && cat /tmp/diag.txt
```

---

## ☁️ Удалённые хранилища

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

### Rclone (требует установки rclone)
```
gdrive:backups
s3:bucket/backups
dropbox:backup-folder
```

---

## 🔄 Обновление бота

LAZARUS включает функцию обновления Remnawave Telegram Shop Bot:

### Умное обновление (v4.29.0+)
- **Проверка Docker images** — если образ уже загружен в Docker, предлагает обновиться сразу без поиска tar-файлов
- **Проверка требований** — для версий 3.25.5+ показывает статус LICENSE_KEY и machine-id volume
- **Предупреждения** — красные уведомления если LICENSE_KEY или machine-id отсутствуют

### CLI команды обновления (v4.30.0+)
```bash
lazarus upgrade          # Авто-обновление бота без интерактивного меню
lazarus bot upgrade      # То же самое
lazarus -b -u            # Короткая форма
```

### Обновление скрипта
Скрипт использует **jsDelivr CDN** для проверки обновлений (быстрее чем raw.githubusercontent.com).
```bash
lazarus check_update     # Проверить и обновить скрипт
```

### Процесс обновления
1. Проверка загруженных образов в Docker
2. Поиск tar-файлов в `/opt/`, `/root/`, `/home/`, `/tmp/`, папке бота
3. Отображение доступных версий с подсветкой новых
4. Автоматический бэкап перед обновлением (Full + DB)
5. Загрузка образа (если не загружен) и обновление `compose.yaml`
6. Проверка и добавление LICENSE_KEY / machine-id volume
7. Health-check контейнеров после обновления
8. Предложение удалить установочные tar-файлы

📖 **Полная документация:** [bot-update/README.md](bot-update/README.md)

**Поддерживаемые форматы образов:**
- `rwp_shop_X.Y.Z.tar` (рекомендуемый)
- `rwp_shop-X.Y.Z-amd64.tar` 
- `private-remnawave-telegram-shop-bot-X.Y.Z.tar`

---

## 🐛 Debug режим

При запуске с `--debug` выводится полная информация:

```bash
lazarus --debug backup_full
```

**Что отображается:**
- Системная информация (версия bash, пользователь, hostname)
- Конфигурация (пути, контейнеры, настройки)
- Настройки Telegram и удалённого хранилища
- Ход выполнения каждой операции с метками времени
- HTTP-коды ответов API

**Категории логов:** `BACKUP`, `LOCK`, `DISK`, `HEALTH`, `DB`, `TAR`, `ENC`, `VERIFY`, `UPLOAD`, `TG`, `REMOTE`, `SCAN`, `RESTORE`, `MIGRATE`

---

## 📁 Структура файлов

```
/opt/lazarus-backup/
├── config.env              # Конфигурация (chmod 600)
├── .password               # Пароль шифрования (chmod 600, опционально)
├── lazarus-backup          # Основной скрипт (имя совпадает с именем в репо)
├── .last_skipped.txt       # Отчёт о пропущенных файлах последнего бэкапа
├── .last_skipped.meta      # Метаданные отчёта (archive, count, timestamp)
└── backup/                  # Папка с архивами
    ├── lazarus_full_2025-01-01_04_00_00__v6.4.1.27.tar.gz       # Версия в имени
    ├── lazarus_db_2025-01-01_12_00_00__v6.4.1.27.tar.gz
    └── lazarus_db_2025-01-01_12_00_00__v6.4.1.27.tar.gz.enc     # Зашифрованный

/usr/local/bin/lazarus      # Symlink на скрипт
/var/log/lazarus_backup.log # Лог-файл (ротация при >10MB)
/var/run/lazarus_backup.lock # Lock-файл (предотвращение параллельного запуска)
```

### Формат имён бэкапов
```
lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS__vX.Y.Z.tar.gz       # Обычный
lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS__vX.Y.Z.tar.gz.enc   # Зашифрованный
```
Версия бота (`__vX.Y.Z`) встроена в имя файла напрямую — никаких `.version` файлов-спутников.

---

## 🗑️ Удаление скрипта

Для полного удаления LAZARUS используйте пункт меню `666`:

```bash
lazarus
# Выбрать: 666. Удалить скрипт (Uninstall)
```

Будут удалены:
- `/opt/lazarus-backup/` (скрипт и конфигурация)
- `/usr/local/bin/lazarus` (symlink)
- Cron-задачи LAZARUS

> ⚠️ Папка с бэкапами (`/opt/lazarus-backup/backup/`) НЕ удаляется автоматически

---

## 🙏 Благодарности

Основано на: https://github.com/distillium/remnawave-backup-restore

---

## 📄 Лицензия

MIT License — см. [LICENSE](LICENSE)

---

<div align="center">

**Developed with ❤️ by [UnderGut](https://github.com/UnderGut)**

</div>
