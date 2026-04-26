# n8n self-hosted install: Docker Compose + PostgreSQL + Nginx + Let's Encrypt

Этот репозиторий содержит `install-n8n-nginx-ssl.sh` — bash-скрипт для установки self-hosted n8n на Ubuntu VPS.

Скрипт делает всё основное:

- устанавливает базовые пакеты: `nginx`, `certbot`, `cron`, `dnsutils`, `openssl`;
- устанавливает Docker Engine и Docker Compose plugin из официального Docker APT-репозитория;
- создаёт `/root/n8nstack/.env` с рандомными секретами;
- создаёт `docker-compose.yml` для n8n + PostgreSQL;
- запускает контейнеры;
- выпускает SSL-сертификат Let's Encrypt через Certbot webroot;
- настраивает Nginx как reverse proxy на `127.0.0.1:5678`;
- добавляет deploy hook для перезагрузки Nginx после автообновления сертификата.

## Требования

- Ubuntu 22.04 или Ubuntu 24.04.
- Root-доступ к серверу.
- Домен или поддомен, который указывает на IP сервера.
- Открытые порты `80` и `443`.

## DNS перед запуском

До запуска скрипта создай DNS-запись у регистратора домена.

Для основного домена:

```text
Type: A
Name: @
Value: IP_ТВОЕГО_СЕРВЕРА
TTL: 300
```

Для поддомена, например `n8n.example.com`:

```text
Type: A
Name: n8n
Value: IP_ТВОЕГО_СЕРВЕРА
TTL: 300
```

Проверить DNS можно так:

```bash
dig +short example.com A @1.1.1.1
dig +short example.com A @8.8.8.8
```

Команды должны вернуть IP твоего сервера.

Если у домена есть `AAAA`-запись, она тоже должна указывать на этот сервер. Если IPv6 на сервере нет, лучше удалить `AAAA`-запись, иначе Let's Encrypt может не выпустить сертификат.

## Быстрый старт

Скачай скрипт:

```bash
curl -fsSL -o install-n8n-nginx-ssl.sh https://example.com/install-n8n-nginx-ssl.sh
chmod +x install-n8n-nginx-ssl.sh
```

Запусти от root:

```bash
sudo bash install-n8n-nginx-ssl.sh \
  --domain example.com \
  --email you@example.com \
  --timezone Europe/Moscow
```

Для поддомена:

```bash
sudo bash install-n8n-nginx-ssl.sh \
  --domain n8n.example.com \
  --email you@example.com \
  --timezone Europe/Moscow
```

После завершения открой:

```text
https://example.com
```

или:

```text
https://n8n.example.com
```

## Параметры скрипта

```text
Required:
  --domain DOMAIN             Домен или поддомен для n8n
  --email EMAIL               Email для Let's Encrypt

Options:
  --timezone TIMEZONE         Часовой пояс, по умолчанию Europe/Moscow
  --stack-dir PATH            Папка установки, по умолчанию /root/n8nstack
  --n8n-user USER             Пользователь HTTP Basic Auth, по умолчанию admin
  --postgres-db NAME          Имя базы PostgreSQL, по умолчанию n8ndb
  --postgres-user USER        Пользователь PostgreSQL, по умолчанию n8nuser
  --n8n-version VERSION       Docker image tag n8n, по умолчанию latest
  --force-env                 Пересоздать .env и сгенерировать новые секреты
  --skip-dns-check            Пропустить проверку DNS перед Certbot
  --skip-docker-install       Не устанавливать Docker автоматически
  -h, --help                  Помощь
```

## Где лежат файлы

По умолчанию:

```text
/root/n8nstack/.env
/root/n8nstack/docker-compose.yml
/etc/nginx/sites-available/n8n.conf
/etc/letsencrypt/live/DOMAIN/fullchain.pem
/etc/letsencrypt/live/DOMAIN/privkey.pem
```

`.env` содержит пароли и ключ шифрования. Не коммить его в Git.

## Как посмотреть логин и пароль

HTTP Basic Auth пользователь:

```bash
grep '^N8N_BASIC_AUTH_USER=' /root/n8nstack/.env
```

HTTP Basic Auth пароль:

```bash
grep '^N8N_BASIC_AUTH_PASSWORD=' /root/n8nstack/.env
```

Важно: это дополнительный HTTP Basic Auth слой перед n8n. При первом входе сам n8n может попросить создать owner-аккаунт.

## Важное про `N8N_ENCRYPTION_KEY`

`N8N_ENCRYPTION_KEY` используется n8n для шифрования credentials.

Посмотреть ключ:

```bash
grep '^N8N_ENCRYPTION_KEY=' /root/n8nstack/.env
```

Не теряй и не меняй этот ключ после начала работы. Если его поменять, ранее сохранённые credentials в n8n могут перестать расшифровываться.

`--force-env` пересоздаёт `.env` и генерирует новый `N8N_ENCRYPTION_KEY`. Не используй `--force-env` на рабочем сервере с уже созданными workflows и credentials, если не понимаешь последствия.

## Полезные команды

Перейти в папку стека:

```bash
cd /root/n8nstack
```

Посмотреть контейнеры:

```bash
docker compose ps
```

Посмотреть логи n8n:

```bash
docker compose logs -f n8n
```

Посмотреть логи PostgreSQL:

```bash
docker compose logs -f postgres
```

Перезапустить стек:

```bash
docker compose restart
```

Остановить стек:

```bash
docker compose down
```

Запустить стек:

```bash
docker compose up -d
```

Обновить n8n:

```bash
cd /root/n8nstack
docker compose pull
docker compose up -d
```

Проверить Nginx:

```bash
nginx -t
systemctl status nginx --no-pager -l
```

Проверить сертификаты Certbot:

```bash
certbot certificates
```

Проверить автообновление сертификатов:

```bash
systemctl list-timers | grep certbot
```

## Troubleshooting

### `docker: unknown command: docker compose`

Значит установлен старый `docker-compose` v1 или не установлен Compose plugin.

Запусти скрипт без `--skip-docker-install`, он подключит официальный Docker APT-репозиторий и поставит `docker-compose-plugin`.

Проверка:

```bash
docker compose version
```

### `yaml: line 2, column 5: mapping values are not allowed in this context`

Обычно это значит, что в `docker-compose.yml` случайно попала строка команды вроде:

```text
cat > docker-compose.yml <<'YML'
```

Внутри файла её быть не должно.

Проверка файла:

```bash
cd /root/n8nstack
cat -n docker-compose.yml
docker compose config
```

### Certbot пишет `DNS problem: NXDOMAIN`

Домен не резолвится. Добавь DNS A-запись и подожди обновления DNS.

Проверка:

```bash
dig +short example.com A @1.1.1.1
dig +short example.com A @8.8.8.8
```

### Certbot просит ввести домен вручную

Скорее всего, команда была запущена с пустыми переменными.

Запускай Certbot явно:

```bash
certbot certonly --webroot -w /var/www/letsencrypt \
  -d "example.com" \
  -m "you@example.com" \
  --agree-tos --no-eff-email --rsa-key-size 4096
```

### `502 Bad Gateway`

Nginx работает, но n8n не отвечает на `127.0.0.1:5678`.

Проверь:

```bash
cd /root/n8nstack
docker compose ps
docker compose logs -f n8n
curl -I http://127.0.0.1:5678
```

### Docker service failed to start

Проверь статус и логи:

```bash
systemctl status docker.service --no-pager -l
journalctl -xeu docker.service --no-pager -n 120
```

Иногда помогает:

```bash
systemctl restart containerd
systemctl reset-failed docker
systemctl restart docker
```

## Безопасность

Минимум, который стоит сделать после установки:

- не публиковать `.env`;
- сохранить `N8N_ENCRYPTION_KEY` в надёжном месте;
- использовать отдельный поддомен для n8n;
- регулярно обновлять Docker images;
- использовать сильный пароль для HTTP Basic Auth;
- настроить backup PostgreSQL и volume `n8n_data`.

## Ссылки

- Docker Engine on Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- Docker Compose plugin: https://docs.docker.com/compose/install/linux/
- n8n Docker installation: https://docs.n8n.io/hosting/installation/docker/
- n8n environment variables: https://docs.n8n.io/hosting/configuration/environment-variables/
- n8n reverse proxy webhook URL: https://docs.n8n.io/hosting/configuration/configuration-examples/webhook-url/
- Certbot: https://certbot.eff.org/
