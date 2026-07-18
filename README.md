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
[![Version](https://img.shields.io/badge/version-6.0.0-green?style=flat-square)](https://github.com/UnderGut/LAZARUS-Backup-Manager/releases)
[![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

**LAZARUS** — система резервного копирования для **Remnawave Panel** и **[Remnawave Telegram Shop Bot](https://remnawave-telegram-shop-bot-doc.vercel.app/ru/private/overview/)**: панель, бот, infra-billing и база знаний ИИ-саппорта — одним инструментом. Всё находится **само** (по образам и docker-меткам, имена контейнеров и пути не важны), деструктивные операции защищены от потери данных, есть **перенос панели на новый сервер** и два режима меню — **Простой** (для новичков: 4 пункта + пошаговый мастер) и **Расширенный** (полный контроль).

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

> 💡 Скрипт установится как `/opt/lazarus-backup/lazarus-backup` и создаст symlink `/usr/local/bin/lazarus` (команда `lazarus`). Конфиг можно **не заполнять** — при первом запуске мастер спросит только необходимое, а всё остальное найдётся автоматически. Проверить, что нашлось: `lazarus stacks`.

---

## 🆕 Что нового в 6.0

- **Панель — основная цель.** LAZARUS бэкапит **Remnawave Panel** (каталог + БД + роли кластера), а не только бота. Бот стал опциональной вторичной целью.
- **Авто-обнаружение стеков.** Панель, бот и infra-billing находятся по Docker-образам и compose-меткам — **имена контейнеров и пути указывать не нужно**. `lazarus stacks` показывает, что нашлось.
- **Перенос панели на другой сервер** — `lazarus migrate panel`: тянет панель со старого сервера по SSH (read-only), разворачивает на новом, выдаёт чеклист переключения. SSH-ключ **не обязателен** — можно ввести root-пароль или вставить ключ прямо в мастер.
- **Сайдкары** — infra-billing, база знаний ИИ-саппорта (pgvector) и произвольные пути вне каталога панели (напр. `certwarden`) входят в бэкап автоматически, каждый со своей точкой отката при restore.
- **Два режима меню** — Простой (4 пункта) и Расширенный, с единой дизайн-системой (инвариант «0 = Назад», деструктив всегда на «9», статусы `✓`/`— выкл`).
- ⚠️ **Обновление бота удалено.** LAZARUS занимается только бэкапом/восстановлением/переносом. Обновляйте бота его собственными средствами.

---

## ✨ Возможности

### 🛡️ Защита от потери данных
Скрипт спроектирован так, чтобы **не терять данные** даже при сбоях:
- **Restore с точкой отката** — перед уничтожением БД снимается snapshot ЖИВОЙ БД (с контент-проверкой). Деструктив выполняется только при валидном snapshot; при провале импорта — авто-откат + подъём контейнеров. Любой ранний отказ гарда поднимает стек обратно (панель/бот не остаются offline).
- **Verify до удаления** — каждый архив (full и incremental) проверяется (для `.enc` — полным decrypt round-trip) ПЕРЕД удалением plaintext и репортом об успехе.
- **Шифрование обязательно** — если задан пароль и шифрование провалилось, незашифрованный архив НЕ отправляется (cron — abort; интерактив — явное подтверждение). Промежуточные plaintext-дампы (в т.ч. при удалённом бэкапе) затираются `shred` при выходе/прерывании.
- **Ротация не обнуляет** — size-rotation никогда не удаляет новейший бэкап и каскадно чистит orphan-инкременты.
- **Upload с verify** — S3/FTP/WebDAV/rclone сверяют размер на remote ПЕРЕД тем, как `delete-local` удалит локальную копию; при несверенном размере локаль не трогается.
- **Идентификация по роли, не по имени** — контейнеры определяются по образу/метке/`DATABASE_URL`, деструктив над «чужим» стеком отклоняется fail-closed.
- **Сериализация под flock** — параллельные бэкапы (cron + ручной) не портят друг друга.

### 💾 Резервное копирование
- **Авто-обнаружение** — панель, бот, infra-billing и БД знаний находятся сами (образы + docker-метки), имена не важны.
- **4 типа бэкапов** — Full (БД + файлы), Только БД, Только файлы, **Incremental** (изменённые файлы + свежий дамп БД относительно последнего full).
- **Сайдкары** — роли кластера (`globals`), infra-billing (`billing_*.sql`), база знаний ИИ-саппорта (`kb_*.sql`, pgvector), доп. пути вне каталога панели (`extra_*.tar`, напр. `certwarden`).
- **AES-256-CBC + HMAC-SHA256** — envelope encrypt-then-MAC (v2), обнаружение неверного пароля и подмены байтов ДО расшифровки.
- **gzip / zstd** — gzip (везде), zstd (opt-in, меньше и быстрее на SQL-дампах). Старые архивы восстанавливаются независимо от текущего формата (детект по magic bytes).
- **Версия в имени файла** — если на сервере есть бот, в имя добавляется его версия (`__vX.Y.Z`); на сервере только с панелью суффикс опускается.
- **v1→v2 миграция** — `lazarus migrate-v2` для конверсии старых архивов.

### 🖥️ Цели бэкапа
- **panel** — Remnawave Panel (рекомендуется): каталог `/opt/remnawave` (`.env`, compose, сертификаты, nginx) + БД + роли кластера.
- **bot** — Telegram shop-бот `rwp_shop` (+ сайдкар базы знаний).
- **обе цели** — панель и бот на одном сервере, одним прогоном (архивы разведены неймспейсами `lazarus_panel_*` / `lazarus_*`).
- **удалённая цель по SSH** — бэкап панели/бота с ДРУГОГО сервера (pull по SSH).

### 🔀 Перенос панели на новый сервер
`lazarus migrate panel` — переносит Remnawave Panel со старого сервера на этот (запускать на **новом**):
- источник читается по SSH **read-only** — старая панель продолжает работать до вашего решения переключиться;
- тянет каталог панели + дамп БД + роли (globals) + infra-billing;
- SSH-ключ **не обязателен** — мастер спросит хост и позволит ввести root-пароль (поставит `sshpass`), либо принять путь к ключу, либо **вставить ключ прямо в терминал**;
- поддержаны обе раскладки установки: официальная (docs.rw) и eGames (панель+нода на одном сервере);
- после переноса — чеклист переключения (DNS, ноды, сертификаты, вебхуки) с фазами «Проверить → Переключить → Завершить».

### ☁️ Хранение и доставка
- **Telegram** — файлы и уведомления с premium emoji + retry × 3.
- **S3-совместимые** — AWS, MinIO, RustFS, Yandex Cloud, Selectel, **Cloudflare R2** (`region=auto`), **Backblaze B2**, custom endpoint. После upload — `head-object` verify (size + ETag), очистка висящих multipart при сбое.
- **FTP / FTPS / WebDAV / Rclone** — с retry и пошаговой настройкой; post-upload verify размера.
- **Ротация** — по времени (дни) или количеству; отдельная ротация на S3 (`S3_RETENTION_DAYS`, трогает только свои архивы).

### 🔔 Алерты в Telegram
- **Severity bands** — CRITICAL 🔴 / ERROR ❌ / WARN ⚠️ / INFO ℹ️, хэштеги на первой строке для быстрого поиска.
- **Мониторинг диска** — TG-alert при заполнении (WARN 90% / CRITICAL 95%, настраивается; на CRITICAL бэкап отменяется).

### ⚙️ Автоматизация
- **Cron из меню** — расписание Full / Только БД / Только файлы, включая «каждые N минут».
- **flock** — защита от параллельного запуска (cron + ручной).
- **Таймаут-обёртки** — hard-limit на pg_dump / tar / encrypt / restore (60 мин по умолчанию, настраивается; `0` = без лимита).
- **Logrotate** — `/etc/logrotate.d/lazarus` (weekly, rotate 8, compress).
- **Самообновление** — `lazarus update` (обновляет сам скрипт LAZARUS).

### 🩺 Диагностика
- **`lazarus stacks`** — обнаруженные стеки сервера (панель / infra-billing / бот) + расхождения конфиг↔реальность.
- **`lazarus diag`** — полный snapshot системы для troubleshooting.
- **`lazarus verify`** — integrity-check всех архивов (gzip + zstd + MAC) с TG-alert при повреждении.
- **`lazarus report [weekly|daily|month]`** — статистика backup-активности.
- **Debug** (`--debug`) и **Dry-run** (`--dry-run`).

---

## 📋 Требования

- Linux (Debian/Ubuntu/CentOS), bash 5+, root.
- Docker Compose v2 (`docker compose`, не `docker-compose`).
- **Обязательно:** tar (≥1.31), gzip, curl/wget, openssl.
- **Опционально:** `zstd` (для `COMPRESSION=zstd`), `aws` CLI v1/v2 (для S3/R2/B2), `rclone` (для Rclone-хранилищ), `sshpass` (для переноса панели по паролю — мастер предложит поставить).

---

## 🖥️ Интерфейс

> 📸 Галерея скриншотов: [screenshots/README.md](screenshots/README.md)

Два режима меню (переключаются пунктом **99**):

- **Простой режим** — 4 пункта (Сделать бэкап · Восстановить · Настроить · Перенести панель) + пошаговый мастер настройки. Для тех, кто впервые видит терминал.
- **Расширенный режим** — дашборд (что бэкапим · защита · последние бэкапы · авто-бэкап) + полный доступ ко всем настройкам, ротации, хранилищам, расписаниям.

Единая дизайн-система: **0 = Назад** всегда, деструктивные действия только на «9» (и только когда есть что отключать), статусы `✓ …` / `— выкл`.

---

## 💻 CLI команды

```bash
lazarus                       # интерактивное меню
lazarus stacks                # обнаруженные стеки: панель / infra-billing / бот

# Бэкап
lazarus backup create         # полный бэкап (БД + файлы)   ·  -B -c
lazarus backup db             # только БД                    ·  -B -d
lazarus backup files          # только файлы                 ·  -B -f
lazarus backup inc            # incremental (изменения + БД)
lazarus backup list           # список бэкапов               ·  -B -l
lazarus backup_full|backup_db|backup_files   # legacy-алиасы (для cron)

# Восстановление и обслуживание
lazarus restore               # меню восстановления (с фильтром по дате)
lazarus cleanup               # ротация старых бэкапов
lazarus skipped               # пропущенные файлы последнего бэкапа
lazarus verify                # integrity-check всех архивов (MAC + gzip/zstd)
lazarus migrate-v2            # конверсия старых v1-архивов в v2 (HMAC)
lazarus report weekly|daily|month   # TG-отчёт активности
lazarus diag                  # полный snapshot системы

# Перенос панели
lazarus migrate panel [--from user@host] [--port 22] [--key /path] [--path /opt/remnawave]

# Управление контейнерами бота
lazarus bot status            # статус + версия + healthcheck   ·  -b -s
lazarus bot up | down         # запустить / остановить контейнеры бота
lazarus bot logs [N]          # последние N строк логов          ·  -b -l

# S3 и обновление скрипта
lazarus s3 test | list | upload <file>   # проверка / список / загрузка   ·  -S
lazarus update                # обновить САМ скрипт LAZARUS

# Telegram Premium emoji
lazarus emoji probe <id> | scan
```

> ⚠️ **Restore** требует подтверждения словом: `RESTORE` (восстановление), `DELETE` (удаление volume), `DROP` (DROP SCHEMA). Без ввода — auto-cancel через 60 сек. Неинтерактивно нужны **оба** флага: `--yes --i-know-what-i-am-doing`. По умолчанию `.env` сохраняется, volume БД **не** удаляется, DROP SCHEMA **не** выполняется.

### Глобальные флаги

| Флаг | Описание |
|------|----------|
| `--yes`, `-y` | Автоподтверждение (для cron) |
| `--dry-run`, `-n` | Предпросмотр без выполнения |
| `--debug`, `-d` | Подробное логирование |
| `--report-tg` | Отправить отчёт в Telegram |
| `--i-know-what-i-am-doing` | Разрешить деструктив в non-interactive |
| `--restore-include-env` | Восстановить `.env` из бэкапа (по умолчанию сохраняется) |
| `--restore-drop-volume` | Удалить Docker volume БД при restore |
| `--restore-drop-schema` | Выполнить `DROP SCHEMA` перед импортом БД |

### Примеры

```bash
lazarus --yes backup db                 # cron-режим: бэкап БД
lazarus --debug backup create           # с подробным логом
lazarus --dry-run cleanup               # предпросмотр очистки

# Ежедневный full-бэкап (cron)
0 4 * * *  /usr/local/bin/lazarus --yes backup_full >> /var/log/lazarus_backup.log 2>&1
# Еженедельный verify (cron)
0 4 * * 0  /usr/local/bin/lazarus --report-tg verify >> /var/log/lazarus_backup.log 2>&1
```

---

## ⚙️ Конфигурация

Конфиг **можно не заполнять** — запустите `lazarus`, мастер и авто-обнаружение (`lazarus stacks`) настроят всё сами. Файл: `/opt/lazarus-backup/config.env` (chmod 600).

- **Шаблон с самым нужным:** [config.env.sample](config.env.sample)
- **Полный справочник всех ключей** (цели, панель, сайдкары, SSH-бэкап с другого сервера, S3, тайминги, ротация): **[CONFIG_REFERENCE.md](CONFIG_REFERENCE.md)**

Коротко о главном:

| Что | Ключ | По умолчанию |
|---|---|---|
| Что бэкапить | `BACKUP_TARGET` | `panel` (или `bot`) |
| Вторая цель (панель+бот на одном сервере) | `BACKUP_SECONDARY` | — |
| Telegram | `BOT_TOKEN`, `CHAT_ID` | — |
| Сколько хранить локально | `RETENTION_DAYS` | `7` |
| Сколько хранить на S3 | `S3_RETENTION_DAYS` | `0` (не удалять) |
| Компрессия | `COMPRESSION` | `gzip` (или `zstd`) |
| Пароль шифрования | файл `.password` (chmod 600) | — |

> 💡 Пути и имена контейнеров панели/бота/биллинга указывать **не нужно** — находятся автоматически и лечатся при расхождении. Заполняйте только для экзотических раскладок.

---

## ☁️ Удалённые хранилища

Настраиваются в меню: **Настройки → Удалённое хранилище** (пошаговый мастер).

```
S3 / R2 / B2   через aws-cli (R2 — region=auto)
WebDAV         https://webdav.yandex.ru/backups
FTP / FTPS     ftp://backup.example.com/backups
Rclone         gdrive:backups   (требует настроенный rclone)
```

---

## ♻️ Восстановление

`lazarus restore` (или меню → Восстановить). Порядок безопасного восстановления:

1. Снимается snapshot ЖИВОЙ БД (точка отката).
2. Останавливаются контейнеры (для db-only — только приложение, БД остаётся для импорта).
3. Файлы синхронизируются из архива; при конфликте версий (архив старше свежеустановленной панели) — явный выбор: только данные / сохранить текущую инфру / точная копия.
4. `DROP SCHEMA` + импорт БД; при провале — авто-откат из snapshot и подъём стека.
5. Опционально — импорт infra-billing и базы знаний (каждый со своей точкой отката).
6. Стек поднимается заново (свежий пул соединений).

Восстановление доступно только для **локальной** цели (удалённую SSH-цель восстанавливают на её сервере).

---

## 🔄 Обновление

```bash
lazarus update        # обновить сам скрипт LAZARUS (проверка + установка новой версии)
```

Если авто-проверка не срабатывает (кэш CDN) — обновите вручную:

```bash
curl -sSL "https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup" -o /opt/lazarus-backup/lazarus-backup && chmod +x /opt/lazarus-backup/lazarus-backup
```

> ⚠️ Обновление **бота** из LAZARUS удалено (начиная с 6.0) — обновляйте бота его собственными средствами. `lazarus update` обновляет только сам LAZARUS.

---

## 🐛 Debug

```bash
lazarus --debug backup create
```

Категории логов: `BACKUP`, `LOCK`, `DISK`, `HEALTH`, `DB`, `TAR`, `ENC`, `VERIFY`, `UPLOAD`, `TG`, `REMOTE`, `SCAN`, `RESTORE`, `MIGRATE`.

---

## 📁 Структура файлов

```
/opt/lazarus-backup/
├── config.env              # конфигурация (chmod 600)
├── .password               # пароль шифрования (chmod 600, опционально)
├── lazarus-backup          # основной скрипт
└── backup/                 # архивы
    ├── lazarus_panel_full_2026-01-01_04_00_00__vX.Y.Z.tar.gz     # панель, full
    ├── lazarus_full_2026-01-01_04_00_00__vX.Y.Z.tar.gz           # бот, full
    └── ..._db_..._..__vX.Y.Z.tar.gz.enc                          # зашифрованный

/usr/local/bin/lazarus       # symlink на скрипт
/var/log/lazarus_backup.log  # лог (ротация logrotate)
```

Формат имён (суффикс `__vX.Y.Z` — версия бота, если бот есть на сервере):
- full / db / files: `lazarus[_panel]_{full|db|files}_YYYY-MM-DD_HH_MM_SS__vX.Y.Z.tar.{gz|zst}[.enc]`
- incremental: `lazarus[_panel]_inc_<ts>__base_<full_ts>__vX.Y.Z.tar.{gz|zst}[.enc]` (ссылается на базовый full через `__base_`)

Панельные бэкапы имеют префикс `lazarus_panel_`, бот — `lazarus_`.

---

## 🗑️ Удаление

Пункт меню **666** (Расширенный режим) удаляет `/opt/lazarus-backup/`, symlink и cron-задачи LAZARUS.

> ⚠️ Папка с бэкапами (`/opt/lazarus-backup/backup/`) не удаляется автоматически.

---

## 🙏 Благодарности

Основано на: https://github.com/distillium/remnawave-backup-restore

## 📄 Лицензия

MIT License — см. [LICENSE](LICENSE)

---

<div align="center">

**Developed with ❤️ by [UnderGut](https://github.com/UnderGut)**

</div>
