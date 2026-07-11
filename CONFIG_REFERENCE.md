# LAZARUS — полный справочник ключей config.env

Для быстрого старта этот файл не нужен: запустите `lazarus` — мастер и авто-обнаружение
(`lazarus stacks`) настроят всё сами. Ниже — справочник для тонкой настройки и автоматизации.
Отсутствующий в config.env ключ = значение по умолчанию. Скрипт сам дописывает недостающие
ключи при первом сохранении настроек.

## Telegram

| Ключ | Default | Описание |
|---|---|---|
| `BOT_TOKEN` | — | токен бота от @BotFather |
| `CHAT_ID` | — | chat ID / ID группы для уведомлений |
| `TG_MESSAGE_THREAD_ID` | — | ID топика в супергруппе (опц.) |
| `SEND_TO_TELEGRAM` | `true` | слать уведомления |
| `TG_SEND_FILE` | `true` | слать сам файл бэкапа в Telegram |

## Цель бэкапа

| Ключ | Default | Описание |
|---|---|---|
| `BACKUP_TARGET` | `panel` | `panel` (Remnawave, рекомендуется) или `bot` (rwp_shop) |
| `BACKUP_SECONDARY` | — | вторая цель тем же прогоном (панель+бот на одном сервере). Архивы разведены неймспейсами `lazarus_panel_*` / `lazarus_*` |

## Панель (BACKUP_TARGET=panel)

Все значения **находятся автоматически** (образ `remnawave/backend`, docker-labels,
`DATABASE_URL` приложения) и лечатся при расхождении. Заполнять — только для экзотики.

| Ключ | Default | Описание |
|---|---|---|
| `PANEL_PATH` | `/opt/remnawave` | каталог установки (бэкапится целиком: .env, compose, certs, nginx) |
| `PANEL_DB_CONTAINER` | `remnawave-db` | postgres-контейнер панели |
| `PANEL_DB_SERVICE` | `remnawave-db` | compose-сервис БД (volume-lookup при restore) |
| `PANEL_DB_NAME` | из `.env` панели | override имени БД |
| `PANEL_EXTRA_PATHS` | — | ЗАРЕЗЕРВИРОВАНО (пока не активно) |

### infra-billing (сайдкар панели)

| Ключ | Default | Описание |
|---|---|---|
| `PANEL_BILLING_DB_CONTAINER` | `infra-billing-db` | БД биллинга; пусто = авто-поиск в проекте панели. Имя/сервис должны содержать `billing` (identity-гард) |
| `PANEL_BILLING_BACKUP` | `auto` | `auto` = дампить если запущен · `true` = обязателен (иначе провал бэкапа) · `false` = выкл |

Финансовая БД дампится как `billing_*.sql.*` внутри panel-архивов; креды берутся из env
контейнера. Restore предлагает импорт интерактивно, со своей точкой отката.

## Бот (BACKUP_TARGET=bot)

Тоже находится автоматически (ключевые слова + любые не-панельные compose-проекты с БД —
кандидаты в интерактивном выборе).

| Ключ | Default | Описание |
|---|---|---|
| `BOT_PATH` | авто | каталог docker-compose бота |
| `BOT_CONTAINER_NAME` | авто | контейнер бота (напр. `rwp_shop`) |
| `DB_CONTAINER_NAME` | авто | контейнер postgres (напр. `rwp_shop_db`) |
| `DB_USER` | `postgres` | пользователь БД |
| `DB_NAME` | из `.env` бота | override, если в `.env` нет `POSTGRES_DB` |
| `IGNORE_MISMATCH` | `false` | игнорировать расхождения имён контейнеров |
| `BOT_RELEASE_URL_BASE` | `https://releases.example.com` | откуда `lazarus bot upgrade <V>` качает релиз (`${BASE}/<V>/rwp_shop_<V>.tar`) |

## Удалённая цель (SSH) — бэкап панели/бота на ДРУГОМ сервере

Дамп и tar выполняются на удалённом сервере и **стримятся** по SSH; сжатие и шифрование —
только на этом хосте (plaintext не пишется на удалённый диск). Архив идентичен локальному.
Нужен ключевой SSH (BatchMode) и docker на удалённой стороне. Remote-restore не автоматизирован.

| Ключ | Default | Описание |
|---|---|---|
| `PANEL_TRANSPORT` / `BOT_TRANSPORT` | `local` | `local` \| `ssh` |
| `PANEL_SSH_HOST` / `BOT_SSH_HOST` | — | хост или user@host |
| `PANEL_SSH_PORT` / `BOT_SSH_PORT` | `22` | порт |
| `PANEL_SSH_USER` / `BOT_SSH_USER` | `root` | пользователь |
| `PANEL_SSH_KEY` / `BOT_SSH_KEY` | — | путь к приватному ключу |

## Расписание и ротация

| Ключ | Default | Описание |
|---|---|---|
| `SCHEDULE_FULL` / `SCHEDULE_DB` / `SCHEDULE_FILES` | `Выкл` | человекочитаемое расписание (напр. `Ежедневно 04:00`) |
| `DELETE_MODE` | `time` | `time` (по дням) \| `count` (по количеству) |
| `RETENTION_DAYS` | `7` | дней хранения (mode=time) |
| `MAX_BACKUPS_COUNT` | `100` | максимум на категорию (mode=count) |
| `MAX_BACKUP_SIZE_MB` | `0` | лимит суммарного размера (0 = без лимита) |

## Файлы

| Ключ | Default | Описание |
|---|---|---|
| `EXCLUDE_DIRS` | — | исключения; разделитель `,` или `;` (поддерживает пробелы в путях) |
| `MAX_FILE_SIZE_MB` | `1` | пропускать файлы крупнее (для панели авто-снимается: 0) |
| `BACKUP_LOG_FILES` | `ask` | логи в архив: `ask` \| `true` \| `false` |

## Удалённое хранилище

| Ключ | Default | Описание |
|---|---|---|
| `REMOTE_STORAGE_TYPE` | `off` | `off` \| `ftp` \| `ftps` \| `webdav` \| `rclone` \| `s3` |
| `REMOTE_STORAGE_URL` / `_USER` / `_PASS` | — | для ftp/ftps/webdav |
| `SEND_TO_REMOTE` | `true` | включить выгрузку |
| `DELETE_LOCAL_AFTER_REMOTE_UPLOAD` | `false` | `false` \| `any` \| `all` \| `remote_only` — удалять локальную копию после доставки (ОСТОРОЖНО) |

### S3 (REMOTE_STORAGE_TYPE=s3) — AWS, MinIO, RustFS, Yandex, R2, B2

| Ключ | Default | Описание |
|---|---|---|
| `S3_ENDPOINT` | AWS | endpoint URL (R2: `https://<account>.r2.cloudflarestorage.com`) |
| `S3_BUCKET` / `S3_PATH` | — | бакет и префикс внутри |
| `S3_REGION` | `us-east-1` | регион (R2 хочет `auto`) |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | — | креды (грузятся в приватный 0600-файл, не в env) |
| `S3_RETENTION_DAYS` | `0` | дней хранить архивы на S3/R2 (0 = не удалять). Чистит ТОЛЬКО ключи `lazarus_*`/`lazarus_panel_*` внутри `S3_PATH`; новейший архив каждой цели не удаляется никогда. Запуск: после каждой успешной выгрузки, вручную — `lazarus s3 rotate [N]` |

Команды: `lazarus s3 test | list | upload`.

## Безопасность

| Ключ | Default | Описание |
|---|---|---|
| `BACKUP_PASSWORD_FILE` | `/opt/lazarus-backup/.password` | файл с паролем шифрования (chmod 600) |
| `BACKUP_PASSWORD` | — | deprecated, оставить пустым (мигрирует в файл сам) |

## Диск и таймауты

| Ключ | Default | Описание |
|---|---|---|
| `DISK_WARN_PERCENT` | `90` | ≥ → предупреждение в TG, бэкап продолжается |
| `DISK_CRITICAL_PERCENT` | `95` | ≥ → бэкап прерван, алерт |
| `PG_DUMP_TIMEOUT_SEC` | `3600` | лимит pg_dump (0 = без лимита, для БД >10GB) |
| `TAR_TIMEOUT_SEC` | `3600` | лимит tar |
| `ENCRYPT_TIMEOUT_SEC` | `1800` | лимит шифрования |
| `RESTORE_TIMEOUT_SEC` | `3600` | лимит restore |

## Сжатие

| Ключ | Default | Описание |
|---|---|---|
| `COMPRESSION` | `gzip` | `gzip` (везде есть) \| `zstd` (~2.5× быстрее, ~3× меньше; `apt install zstd`). Старые архивы читаются автоматически (формат по magic bytes) |
