<p align="center">
  <img src="main_menu.png" alt="LAZARUS main menu">
</p>

# LAZARUS Backup Manager

[![Bash](https://img.shields.io/badge/Language-Bash_5+-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![License](https://img.shields.io/github/license/UnderGut/LAZARUS-Backup-Manager?style=flat-square)](LICENSE)
[![Version](https://img.shields.io/badge/version-4.12.0-blue?style=flat-square)](https://github.com/UnderGut/LAZARUS-Backup-Manager/releases)
[![Docker](https://img.shields.io/badge/Docker-Compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white)](https://docs.docker.com/compose/)

**LAZARUS** — продвинутая система резервного копирования для **Remnawave Telegram Shop Bot** с поддержкой шифрования, облачных хранилищ и умной автоматизацией.

---

## Быстрый старт

Одна команда — установка и запуск:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup)
```

Или установить в систему:

```bash
curl -sSL https://raw.githubusercontent.com/UnderGut/LAZARUS-Backup-Manager/main/lazarus-backup -o /usr/local/bin/lazarus && chmod +x /usr/local/bin/lazarus && lazarus
```

---

## Возможности

- **Smart Scan** — автоматически находит бота в Docker
- **3 типа бэкапов** — Full (БД + файлы), DB Only, Files Only
- **AES-256 шифрование** — защита архивов паролем
- **Telegram** — отправка файлов и уведомлений (раздельно)
- **FTP / FTPS / WebDAV / Rclone** — облачные хранилища с retry
- **Cron автоматизация** — настройка расписания из меню
- **Умная ротация** — по времени или количеству
- **Восстановление** — Full / DB / Files из любого бэкапа

---

## Требования

- Linux (Debian/Ubuntu/CentOS)
- Bash 5+, root права
- Docker Compose v2
- tar, gzip, curl, openssl

---

## Главное меню

```
LAZARUS Backup Manager v4.12.0
Бот: 3.21.0 | Контейнер: Online

Бэкапы: 14 Full | 223 DB | 5 Files | 189M
Последний: 27.12 10:00 (2 часа назад)

Авто-бэкап:
 * Full:  Ежедневно 04:00
 * DB:    Каждые 15 мин
 * Files: Выкл

1. Ручной бекап
2. Настроить авто-бекап
3. Восстановить из бэкапа
4. Настройки
5. Удалить старые бэкапы
8. Проверить обновления
666. Удалить скрипт
0. Выход
```

---

## Настройки (config.env)

| Параметр | Описание |
|----------|----------|
| `BOT_TOKEN` | Токен Telegram бота |
| `CHAT_ID` | ID чата для уведомлений |
| `SEND_TO_TELEGRAM` | Уведомления в TG (true/false) |
| `TG_SEND_FILE` | Отправка файла в TG (true/false) |
| `REMOTE_STORAGE_TYPE` | off / ftp / webdav / rclone |
| `DELETE_MODE` | time (по дням) / count (по кол-ву) |
| `RETENTION_DAYS` | Хранить N дней |
| `BACKUP_PASSWORD` | Пароль шифрования |

Конфиг: `/opt/lazarus-backup/config.env`

---

## CLI команды

```bash
lazarus                  # Меню
lazarus backup_full      # Полный бэкап
lazarus backup_db        # Только БД
lazarus backup_files     # Только файлы
lazarus cleanup          # Очистка
lazarus restore          # Восстановление
```

### Флаги

| Флаг | Описание |
|------|----------|
| `--yes`, `-y` | Автоподтверждение |
| `--dry-run`, `-n` | Предпросмотр |
| `--debug`, `-d` | Режим отладки |
| `--report-tg` | Отчёт в Telegram |

---

## Удалённые хранилища

**FTP/FTPS:**
```
ftp://backup.example.com/backups
ftps://secure.example.com:990/folder
```

**WebDAV:**
```
https://webdav.yandex.ru/backups
https://cloud.example.com/remote.php/dav/files/user/
```

**Rclone:**
```
gdrive:backups
s3:bucket/backups
```

---

## Структура файлов

```
/opt/lazarus-backup/
├── config.env          # Конфигурация
├── backup/             # Архивы
/usr/local/bin/lazarus  # Скрипт
/var/log/lazarus_backup.log
```

---

## Благодарности

Основано на: https://github.com/distillium/remnawave-backup-restore

---

## Лицензия

MIT License — см. [LICENSE](LICENSE)

---

<div align="center">

**Developed with love by [UnderGut](https://github.com/UnderGut)**

</div>
