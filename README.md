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
[![Version](https://img.shields.io/badge/version-4.37.0-green?style=flat-square)](https://github.com/UnderGut/LAZARUS-Backup-Manager/releases)
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

> 💡 Скрипт автоматически установится в `/opt/lazarus-backup/` и создаст symlink `/usr/local/bin/lazarus`

### 🔄 Принудительное обновление

Если автоматическая проверка обновлений не работает (кэширование CDN), обновите вручную:

```bash
# Обновить через jsDelivr CDN (быстрее)
curl -sSL "https://cdn.jsdelivr.net/gh/UnderGut/LAZARUS-Backup-Manager@main/lazarus-backup?t=$(date +%s)" -o /opt/lazarus-backup/lazarus && chmod +x /opt/lazarus-backup/lazarus

# Или через GitHub напрямую (надёжнее)
curl -sSL "https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup" -o /opt/lazarus-backup/lazarus && chmod +x /opt/lazarus-backup/lazarus
```

> 💡 Параметр `?t=$(date +%s)` добавляет timestamp для обхода кэша CDN

---

## ✨ Возможности

### Резервное копирование
- **Smart Scan** — автоматически находит бота в Docker (поддержка `rwp_shop`, `telegram-shop`, `shopbot`)
- **3 типа бэкапов** — Full (БД + файлы), DB Only, Files Only
- **AES-256 шифрование** — защита архивов паролем (PBKDF2, 100k итераций)
- **Версионирование** — каждый бэкап содержит версию бота на момент создания
- **Умная фильтрация** — исключение больших файлов и папок (logs, node_modules, .git)

### 🆕 Миграция с Bedolaga (BETA)
- **Автоматическая миграция** — полный перенос данных из Bedolaga в RWP-Shop в 10 шагов
- **Пользователи** — telegram_id, username, реферальные коды (~95% покрытие)
- **Подписки** — все активные подписки с датами и статусами (~90% покрытие)
- **Транзакции** — история платежей и промокоды (~85% покрытие)
- **Настройки** — токен бота, каналы, админы из .env
- **Сохранение несовместимых данных** — балансы, промокоды на баланс сохраняются в NOT_MIGRATED
- 📖 **[Полная документация миграции](migration/README.md)**

### Хранение и доставка
- **Telegram** — отправка файлов и уведомлений (раздельно настраивается)
- **FTP / FTPS / WebDAV / Rclone** — облачные хранилища с retry и пошаговой настройкой
- **Умная ротация** — по времени (дни) или количеству файлов

### Автоматизация
- **Cron интеграция** — настройка расписания из меню
- **Блокировка параллельного запуска** — предотвращение конфликтов при запуске из cron
- **Авто-обновление** — проверка и установка новых версий скрипта

### Управление ботом
- **Восстановление** — Full / DB / Files из любого бэкапа
- **Обновление бота** — установка новой версии из tar-файла с автобэкапом
- **Health-check** — проверка контейнеров перед операциями

### Отладка
- **Debug режим** — полное логирование всех операций (`--debug`)
- **Dry-run** — предпросмотр действий без выполнения (`--dry-run`)

---

## 📋 Требования

- Linux (Debian/Ubuntu/CentOS)
- Bash 5+, root права
- Docker Compose v2 (`docker compose`, не `docker-compose`)
- tar, gzip, curl/wget, openssl

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
| `REMOTE_STORAGE_TYPE` | Тип хранилища | `off` / `ftp` / `ftps` / `webdav` / `rclone` |
| `REMOTE_STORAGE_URL` | URL сервера с папкой | `ftp://backup.server.com/backups/` |
| `REMOTE_STORAGE_USER` | Логин | `backup_user` |
| `REMOTE_STORAGE_PASS` | Пароль | `secret123` |
| `SEND_TO_REMOTE` | Отправлять на удалённый сервер | `true` / `false` |

### Шифрование и фильтрация

| Параметр | Описание | Пример |
|----------|----------|--------|
| `BACKUP_PASSWORD` | Пароль AES-256 шифрования | `MySecretPass123` или пусто |
| `BACKUP_PASSWORD_FILE` | Файл с паролем шифрования (chmod 600) | `/opt/lazarus-backup/.password` |
| `MAX_FILE_SIZE_MB` | Макс. размер файла в архиве (MB) | `1` (пропуск больших) |
| `EXCLUDE_DIRS` | Исключить папки (через пробел) | `node_modules .git cache` |

> ⚠️ Пароль сохраняется в отдельном файле `BACKUP_PASSWORD_FILE` для безопасности и корректной работы спецсимволов.

---

## 💻 CLI команды

### Основные команды

```bash
lazarus                  # Интерактивное меню
lazarus restore          # Меню восстановления
lazarus migrate          # 🆕 Миграция с Bedolaga (BETA)
lazarus cleanup          # Очистка старых бэкапов
lazarus check_update     # Проверка обновлений скрипта
```

> ⚠️ **ВАЖНО (Restore):** восстановление теперь требует строгую проверку пути и подтверждение строкой
> `RESTORE_TO:/путь/к/боту`. Для неинтерактивного режима нужно **оба** флага:
> `--yes --i-know-what-i-am-doing`. По умолчанию `.env` сохраняется (не перезаписывается).
> Удаление volume БД не выполняется по умолчанию — используйте `--restore-drop-volume` при необходимости.
> Очистка схемы БД (`DROP SCHEMA`) требует `--restore-drop-schema` — без этого флага данные не удаляются, импорт выполняется поверх существующих таблиц.

### 🆕 Резервное копирование (v4.30.0+)

```bash
lazarus backup create    # Полный бэкап (БД + файлы)
lazarus backup db        # Только база данных
lazarus backup files     # Только файлы
lazarus backup list      # Список бэкапов

# Короткие флаги
lazarus -B -c            # = lazarus backup create
lazarus -B -d            # = lazarus backup db
lazarus -B -f            # = lazarus backup files

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

## 🔄 Миграция с Bedolaga (BETA)

> ⚠️ **Тестовая функция!** Используйте на свой страх и риск. Обязательно делайте бэкапы!

LAZARUS включает модуль миграции данных из Telegram-бота **Bedolaga** в **RWP-Shop**:

### Что мигрируется (~88% покрытие)

| Данные | Покрытие | Примечание |
|--------|:--------:|------------|
| 👤 Пользователи | ~95% | telegram_id, username, реф. коды |
| 📋 Подписки | ~90% | Все активные с датами |
| 💳 Транзакции | ~85% | История платежей |
| 🎟️ Промокоды | ~100% | Дни и скидки |
| 👥 Рефералы | ~80% | Связи referrer → referred |
| ⚙️ Настройки | ~85% | Токен, каналы, админы |

### Что НЕ мигрируется

- **Денежные балансы** — RWP-Shop не поддерживает (сохраняются в CSV)
- **Промокоды на баланс** — только дни/скидки (сохраняются в CSV)
- **Индивидуальные autopay** — в RWP-Shop глобальная настройка

### Быстрый старт

```bash
lazarus migrate
# или через меню: 5 → Миграция
```

📖 **Полная документация:** [migration/README.md](migration/README.md)

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
├── lazarus-backup          # Основной скрипт
└── backup/                  # Папка с архивами
    ├── lazarus_full_2025-01-01_04_00_00.tar.gz
    ├── lazarus_full_2025-01-01_04_00_00.tar.gz.version
    ├── lazarus_db_2025-01-01_12_00_00.tar.gz
    └── lazarus_db_2025-01-01_12_00_00.tar.gz.enc  # Зашифрованный

/opt/rwp-shop/MIGRATION/     # Рабочая папка миграции (создаётся в папке бота)
├── 20250101_120000/         # Сессия миграции
│   ├── export/              # Экспортированные данные
│   ├── import/              # Трансформированные данные
│   ├── NOT_MIGRATED/        # Несовместимые данные
│   └── migration_report.txt # Отчёт о миграции

/usr/local/bin/lazarus      # Symlink на скрипт
/var/log/lazarus_backup.log # Лог-файл (ротация при >10MB)
/var/run/lazarus_backup.lock # Lock-файл (предотвращение параллельного запуска)
```

### Формат имён бэкапов
```
lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS.tar.gz      # Обычный
lazarus_{full|db|files}_YYYY-MM-DD_HH_MM_SS.tar.gz.enc  # Зашифрованный
*.version                                                # Кэш версии бота
```

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
