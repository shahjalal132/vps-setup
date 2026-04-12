#!/bin/bash
# Multi-site smoke-test deployer: Nginx + PHP-FPM vhost for Laravel (document root: public/)
# or WordPress (document root: site root). Directory under /var/www is derived from the FQDN.
# Run as root: sudo bash deploy.sh

set -euo pipefail

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Header ---
clear
echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}     MULTI-SITE SMOKE TEST DEPLOY (HTTP ONLY)       ${NC}"
echo -e "${CYAN}====================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo)${NC}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Derive a stable directory name from FQDN: lowercase, non-alphanumeric -> single underscore
sanitize_domain_to_dir() {
  local s
  s=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  s=$(echo "$s" | sed -e 's/[^a-z0-9]\+/_/g' -e 's/^_//' -e 's/_$//')
  echo "$s"
}

validate_domain() {
  local d=$1
  if [[ -z "$d" ]]; then
    return 1
  fi
  if [[ "$d" =~ [[:space:]] ]]; then
    return 1
  fi
  # Rough hostname: labels with dots, no leading/trailing dots
  if [[ ! "$d" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    return 1
  fi
  return 0
}

pkg_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

ensure_apt_base_tools() {
  local need=0
  for p in curl wget ca-certificates software-properties-common lsb-release apt-transport-https git unzip; do
    pkg_is_installed "$p" || need=1
  done
  if [[ "$need" -eq 1 ]]; then
    echo -e "\n${CYAN}Installing base apt tools (curl, wget, ...)...${NC}"
    apt-get update -qq
    apt-get install -y curl wget git unzip software-properties-common ca-certificates lsb-release apt-transport-https
  else
    echo -e "\n${GREEN}Base apt tools already present. Skipping...${NC}"
  fi
}

ensure_nginx() {
  if ! command -v nginx &>/dev/null; then
    echo -e "\n${CYAN}Installing Nginx...${NC}"
    apt-get update -qq
    apt-get install -y nginx
    systemctl enable nginx
  else
    echo -e "\n${GREEN}Nginx already installed. Skipping...${NC}"
  fi
}

php_fpm_sock_for_version() {
  local ver=$1
  echo "/var/run/php/php${ver}-fpm.sock"
}

need_php_stack() {
  if ! command -v php &>/dev/null; then
    return 0
  fi
  local ver
  ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
  local sock
  sock=$(php_fpm_sock_for_version "$ver")
  if [[ ! -S "$sock" ]]; then
    return 0
  fi
  return 1
}

ensure_php_stack() {
  if need_php_stack; then
    echo -e "\n${CYAN}Installing PHP-FPM and extensions (Ondrej PPA)...${NC}"
    apt-get update -qq
    if ! add-apt-repository ppa:ondrej/php -y; then
      echo -e "${RED}Failed to add ondrej/php PPA.${NC}"
      exit 1
    fi
    apt-get update -qq
    apt-get install -y \
      php-cli php-fpm \
      php-mysql php-pgsql php-sqlite3 \
      php-mbstring php-xml php-curl php-zip php-gd \
      php-bcmath php-ctype php-json php-fileinfo php-tokenizer \
      php-redis php-opcache php-intl php-exif php-sockets php-readline
  else
    echo -e "\n${GREEN}PHP-FPM already available. Skipping PHP install...${NC}"
  fi

  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
  PHP_FPM_SOCK=$(php_fpm_sock_for_version "$PHP_VERSION")

  if ! systemctl enable "$PHP_FPM_SERVICE" 2>/dev/null; then
    echo -e "${YELLOW}Warning: ${PHP_FPM_SERVICE} not found. Check PHP-FPM installation.${NC}"
  fi
  systemctl start "$PHP_FPM_SERVICE" 2>/dev/null || true
}

ensure_composer() {
  if ! command -v composer &>/dev/null; then
    echo -e "\n${CYAN}Installing Composer...${NC}"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    if ! php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; then
      echo -e "${RED}Composer installation failed.${NC}"
      rm -f /tmp/composer-setup.php
      exit 1
    fi
    rm -f /tmp/composer-setup.php
    echo -e "${GREEN}Composer installed at /usr/local/bin/composer${NC}"
  else
    echo -e "\n${GREEN}Composer already installed. Skipping...${NC}"
  fi
}

write_smoke_index() {
  local path=$1
  local domain=$2
  cat <<EOF >"$path"
<?php
echo "<h1>Smoke test: $domain</h1>";
echo "PHP Version: " . phpversion() . "<br>";
echo "Time: " . date('Y-m-d H:i:s');
EOF
}

# --- User input ---
exec 3< /dev/tty
echo -e "\n${YELLOW}Configuration${NC}"
read -u 3 -p "Enter domain (e.g. staging.example.com): " DOMAIN_NAME
while true; do
  read -u 3 -p "Project type — 1) Laravel  2) WordPress: " PROJECT_TYPE
  if [[ "$PROJECT_TYPE" == "1" || "$PROJECT_TYPE" == "2" ]]; then
    break
  fi
  echo -e "${RED}Enter 1 or 2.${NC}"
done
exec 3<&-

if ! validate_domain "$DOMAIN_NAME"; then
  echo -e "${RED}Error: invalid or empty domain.${NC}"
  exit 1
fi

DIR_NAME=$(sanitize_domain_to_dir "$DOMAIN_NAME")
if [[ -z "$DIR_NAME" ]]; then
  echo -e "${RED}Error: could not derive directory name from domain.${NC}"
  exit 1
fi

WEB_ROOT="/var/www/${DIR_NAME}"

# --- Dependencies (minimal for HTTP + PHP smoke) ---
ensure_apt_base_tools
ensure_nginx
ensure_php_stack
ensure_composer

# --- Site files ---
echo -e "\n${CYAN}Preparing site files under ${WEB_ROOT}...${NC}"

if [[ -d "$WEB_ROOT" ]]; then
  echo -e "${YELLOW}Directory already exists: ${WEB_ROOT}${NC}"
  echo -e "${YELLOW}Existing files will not be overwritten; missing smoke index.php may be created.${NC}"
fi

if [[ "$PROJECT_TYPE" == "1" ]]; then
  # Laravel: document root = .../public
  mkdir -p "${WEB_ROOT}/public"
  if [[ ! -f "${WEB_ROOT}/public/index.php" ]]; then
    write_smoke_index "${WEB_ROOT}/public/index.php" "$DOMAIN_NAME"
    echo -e "${GREEN}Created ${WEB_ROOT}/public/index.php${NC}"
  else
    echo -e "${GREEN}Keeping existing ${WEB_ROOT}/public/index.php${NC}"
  fi
else
  # WordPress: document root = site root; index.php at root
  mkdir -p "$WEB_ROOT"
  if [[ ! -f "${WEB_ROOT}/index.php" ]]; then
    write_smoke_index "${WEB_ROOT}/index.php" "$DOMAIN_NAME"
    echo -e "${GREEN}Created ${WEB_ROOT}/index.php${NC}"
  else
    echo -e "${GREEN}Keeping existing ${WEB_ROOT}/index.php${NC}"
  fi
fi

chown -R www-data:www-data "$WEB_ROOT"
chmod -R 775 "$WEB_ROOT"

# --- Nginx ---
# Config file name uses DIR_NAME (filesystem-safe); server_name is the FQDN only
rm -f /etc/nginx/sites-enabled/sites-available
rm -f /etc/nginx/sites-enabled/default

NGINX_CONF="/etc/nginx/sites-available/${DIR_NAME}.conf"

if [[ "$PROJECT_TYPE" == "1" ]]; then
  cat <<EOF >"$NGINX_CONF"
# Smoke / Laravel-style vhost (deploy.sh)
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    root ${WEB_ROOT}/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php index.html;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
else
  cat <<EOF >"$NGINX_CONF"
# Smoke / WordPress-style vhost (deploy.sh)
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    root ${WEB_ROOT};

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php index.html;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    location ~ \.php\$ {
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
fi

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

echo -e "\n${YELLOW}Checking Nginx syntax...${NC}"
if nginx -t; then
  systemctl reload nginx
  echo -e "${GREEN}Nginx reloaded successfully.${NC}"
else
  echo -e "${RED}Nginx syntax check failed. Check your config at $NGINX_CONF${NC}"
  exit 1
fi

# --- Summary ---
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}      SMOKE SITE READY                               ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${YELLOW}URL:${NC}  http://${DOMAIN_NAME}"
echo -e "${YELLOW}Path:${NC} ${WEB_ROOT}"
echo -e "${YELLOW}Type:${NC} $([[ "$PROJECT_TYPE" == "1" ]] && echo Laravel || echo WordPress)"
echo -e "${YELLOW}Nginx:${NC} ${NGINX_CONF}"
echo -e "${CYAN}HTTPS: use Certbot after DNS points here (see README.md).${NC}"
echo -e "${GREEN}====================================================${NC}\n"
