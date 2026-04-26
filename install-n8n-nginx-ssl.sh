#!/usr/bin/env bash
set -Eeuo pipefail

# n8n + PostgreSQL + Docker Compose + Nginx + Let's Encrypt installer
# Target: Ubuntu 22.04/24.04 VPS, run as root.

STACK_DIR="/root/n8nstack"
DOMAIN=""
EMAIL=""
TIMEZONE="Europe/Moscow"
N8N_USER="admin"
POSTGRES_DB="n8ndb"
POSTGRES_USER="n8nuser"
N8N_VERSION="latest"
FORCE_ENV=0
SKIP_DNS_CHECK=0
SKIP_DOCKER_INSTALL=0

usage() {
  cat <<USAGE
Usage:
  sudo bash install-n8n-nginx-ssl.sh --domain example.com --email you@example.com [options]

Required:
  --domain DOMAIN             Domain or subdomain for n8n, for example n8n.example.com
  --email EMAIL               Email for Let's Encrypt notifications

Options:
  --timezone TIMEZONE         Timezone, default: Europe/Moscow
  --stack-dir PATH            Install directory, default: /root/n8nstack
  --n8n-user USER             HTTP Basic Auth user, default: admin
  --postgres-db NAME          PostgreSQL database name, default: n8ndb
  --postgres-user USER        PostgreSQL username, default: n8nuser
  --n8n-version VERSION       n8n Docker image tag, default: latest
  --force-env                 Recreate .env and regenerate secrets. WARNING: don't use on existing n8n with data.
  --skip-dns-check            Skip DNS A/AAAA validation before Certbot
  --skip-docker-install       Don't install/reinstall Docker packages
  -h, --help                  Show this help

Example:
  sudo bash install-n8n-nginx-ssl.sh \
    --domain honorwizz.ru \
    --email admin@example.com \
    --timezone Europe/Moscow
USAGE
}

log() { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --timezone) TIMEZONE="${2:-}"; shift 2 ;;
    --stack-dir) STACK_DIR="${2:-}"; shift 2 ;;
    --n8n-user) N8N_USER="${2:-}"; shift 2 ;;
    --postgres-db) POSTGRES_DB="${2:-}"; shift 2 ;;
    --postgres-user) POSTGRES_USER="${2:-}"; shift 2 ;;
    --n8n-version) N8N_VERSION="${2:-}"; shift 2 ;;
    --force-env) FORCE_ENV=1; shift ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    --skip-docker-install) SKIP_DOCKER_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
 done

[[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash $0 ..."
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ -n "$EMAIL" ]] || die "--email is required"
[[ "$DOMAIN" != http://* && "$DOMAIN" != https://* ]] || die "Use domain without protocol, for example n8n.example.com"

if ! grep -qiE 'ubuntu|debian' /etc/os-release; then
  die "This script supports Ubuntu/Debian-like systems only. Detected: $(cat /etc/os-release | tr '\n' ' ')"
fi

export DEBIAN_FRONTEND=noninteractive

log "Installing base packages"
apt-get update
apt-get install -y ca-certificates curl gnupg openssl dnsutils nginx certbot cron
systemctl enable --now cron
systemctl enable --now nginx || true

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  log "UFW is active: allowing Nginx Full"
  ufw allow OpenSSH || true
  ufw allow 'Nginx Full' || true
fi

install_docker_official() {
  log "Installing Docker Engine and Docker Compose plugin from Docker official repository"

  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true

  . /etc/os-release
  local docker_os="${ID:-}"
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [[ "$docker_os" == "ubuntu" || "$docker_os" == "debian" ]] || die "Docker official apt repository supports Ubuntu/Debian here. Detected ID=${docker_os}"
  [[ -n "$codename" ]] || die "Cannot detect Ubuntu/Debian codename"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${docker_os}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.list <<DOCKER_REPO
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_os} ${codename} stable
DOCKER_REPO

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now containerd || true
  systemctl reset-failed docker || true
  if ! systemctl enable --now docker; then
    warn "Docker did not start on the first try. Restarting containerd and Docker."
    systemctl restart containerd || true
    systemctl reset-failed docker || true
    systemctl restart docker || true
  fi

  systemctl is-active --quiet docker || die "Docker service is not running. Check: journalctl -xeu docker.service --no-pager -n 120"
  docker compose version >/dev/null || die "docker compose is not available after installation"
}

if [[ "$SKIP_DOCKER_INSTALL" -eq 0 ]]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    log "Docker and Docker Compose are already installed and running"
  else
    install_docker_official
  fi
else
  log "Skipping Docker installation as requested"
  command -v docker >/dev/null 2>&1 || die "Docker command not found"
  docker compose version >/dev/null || die "docker compose command not found"
  systemctl is-active --quiet docker || systemctl start docker || die "Docker service is not running"
fi

log "Checking DNS for $DOMAIN"
if [[ "$SKIP_DNS_CHECK" -eq 0 ]]; then
  SERVER_IPV4="$(curl -fsS4 --max-time 10 https://ifconfig.me || true)"
  DNS_A="$(dig +short "$DOMAIN" A @1.1.1.1 | grep -E '^[0-9]+\.' || true)"

  [[ -n "$DNS_A" ]] || die "No A record found for $DOMAIN. Add DNS A record pointing to this server IP: ${SERVER_IPV4:-unknown}"

  if [[ -n "$SERVER_IPV4" ]] && ! grep -qx "$SERVER_IPV4" <<<"$DNS_A"; then
    die "DNS A record for $DOMAIN does not point to this server.
Server IPv4: $SERVER_IPV4
DNS A records:
$DNS_A"
  fi

  SERVER_IPV6="$(curl -fsS6 --max-time 5 https://ifconfig.me || true)"
  DNS_AAAA="$(dig +short "$DOMAIN" AAAA @1.1.1.1 | grep ':' || true)"
  if [[ -n "$DNS_AAAA" ]]; then
    if [[ -z "$SERVER_IPV6" ]]; then
      die "AAAA record exists for $DOMAIN, but this server has no reachable IPv6. Remove/fix AAAA or run with --skip-dns-check if you know what you're doing.
DNS AAAA records:
$DNS_AAAA"
    fi
    if ! grep -qx "$SERVER_IPV6" <<<"$DNS_AAAA"; then
      die "DNS AAAA record for $DOMAIN does not point to this server.
Server IPv6: $SERVER_IPV6
DNS AAAA records:
$DNS_AAAA"
    fi
  fi

  log "DNS check passed"
else
  warn "DNS check skipped"
fi

log "Creating stack directory: $STACK_DIR"
mkdir -p "$STACK_DIR"
cd "$STACK_DIR"

if [[ -f .env && "$FORCE_ENV" -eq 0 ]]; then
  warn "Existing .env found. Reusing it and NOT regenerating secrets."
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  if [[ -f .env && "$FORCE_ENV" -eq 1 ]]; then
    warn "--force-env used: backing up existing .env and regenerating secrets"
    cp .env ".env.backup.$(date +%Y%m%d%H%M%S)"
  fi

  N8N_BASIC_AUTH_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
  POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
  N8N_ENCRYPTION_KEY="$(openssl rand -hex 32 | tr -d '\n')"

  cat > .env <<ENV
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
TIMEZONE=${TIMEZONE}
N8N_BASIC_AUTH_USER=${N8N_USER}
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
N8N_VERSION=${N8N_VERSION}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
ENV
  chmod 600 .env
fi

# Load .env after creating/reusing it.
set -a
# shellcheck disable=SC1091
source .env
set +a

: "${DOMAIN:?DOMAIN is missing in .env}"
: "${EMAIL:?EMAIL is missing in .env}"
: "${TIMEZONE:?TIMEZONE is missing in .env}"
: "${N8N_BASIC_AUTH_USER:?N8N_BASIC_AUTH_USER is missing in .env}"
: "${N8N_BASIC_AUTH_PASSWORD:?N8N_BASIC_AUTH_PASSWORD is missing in .env}"
: "${POSTGRES_DB:?POSTGRES_DB is missing in .env}"
: "${POSTGRES_USER:?POSTGRES_USER is missing in .env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is missing in .env}"
: "${N8N_VERSION:?N8N_VERSION is missing in .env}"
: "${N8N_ENCRYPTION_KEY:?N8N_ENCRYPTION_KEY is missing in .env}"

log "Writing docker-compose.yml"
cat > docker-compose.yml <<'YAML'
name: n8nstack

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TIMEZONE}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12

  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}

      N8N_HOST: ${DOMAIN}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${DOMAIN}/
      WEBHOOK_URL: https://${DOMAIN}/
      N8N_PROXY_HOPS: 1
      GENERIC_TIMEZONE: ${TIMEZONE}
      TZ: ${TIMEZONE}

      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: ${N8N_BASIC_AUTH_USER}
      N8N_BASIC_AUTH_PASSWORD: ${N8N_BASIC_AUTH_PASSWORD}

      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PERSONALIZATION_ENABLED: "false"
      N8N_HIRING_BANNER_ENABLED: "false"
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  postgres_data:
  n8n_data:
YAML

log "Validating Docker Compose configuration"
docker compose config >/dev/null

log "Starting n8n stack"
docker compose pull
docker compose up -d

docker compose ps

log "Preparing temporary Nginx config for Let's Encrypt"
mkdir -p /var/www/letsencrypt
chown -R www-data:www-data /var/www/letsencrypt

cat > /etc/nginx/sites-available/n8n_acme.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        access_log off;
        allow all;
    }

    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/n8n_acme.conf /etc/nginx/sites-enabled/n8n_acme.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx || systemctl restart nginx

log "Requesting Let's Encrypt certificate for $DOMAIN"
certbot certonly --webroot -w /var/www/letsencrypt \
  -d "$DOMAIN" -m "$EMAIL" \
  --agree-tos --no-eff-email --rsa-key-size 4096 \
  --non-interactive --keep-until-expiring

log "Writing final Nginx reverse proxy config"
cat > /etc/nginx/sites-available/n8n.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:5678;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;

        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/n8n.conf
rm -f /etc/nginx/sites-enabled/n8n_acme.conf
rm -f /etc/nginx/sites-enabled/default

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx || true
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

nginx -t
systemctl reload nginx

log "Final health checks"
sleep 5
docker compose ps
if curl -fsSI "http://127.0.0.1:5678" >/dev/null 2>&1; then
  log "n8n is responding locally on 127.0.0.1:5678"
else
  warn "n8n did not respond locally yet. Check logs: cd $STACK_DIR && docker compose logs -f n8n"
fi

cat <<DONE

============================================================
Done.

Open:
  https://${DOMAIN}

HTTP Basic Auth user:
  ${N8N_BASIC_AUTH_USER}

To view the generated HTTP Basic Auth password:
  grep '^N8N_BASIC_AUTH_PASSWORD=' ${STACK_DIR}/.env

Important files:
  ${STACK_DIR}/.env
  ${STACK_DIR}/docker-compose.yml
  /etc/nginx/sites-available/n8n.conf

Useful commands:
  cd ${STACK_DIR} && docker compose ps
  cd ${STACK_DIR} && docker compose logs -f n8n
  cd ${STACK_DIR} && docker compose pull && docker compose up -d

Do not lose N8N_ENCRYPTION_KEY from ${STACK_DIR}/.env.
============================================================
DONE
