#!/bin/bash
# Non-interactive VPS stack: system update, PHP (Laravel + WordPress), Nginx, MySQL, Redis,
# Composer, Node 20 + PM2, Certbot, WP-CLI. Skips what is already installed.
# Ubuntu (ppa:ondrej/php). Run as root: sudo bash installation.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo)${NC}"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}     VPS STACK INSTALLATION (non-interactive)       ${NC}"
echo -e "${CYAN}====================================================${NC}"

pkg_is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed"
}

ensure_apt_base_tools() {
  local need=0
  for p in curl wget ca-certificates software-properties-common lsb-release apt-transport-https git unzip; do
    pkg_is_installed "$p" || need=1
  done
  if [[ "$need" -eq 1 ]]; then
    echo -e "\n${CYAN}Installing base apt tools...${NC}"
    apt-get update -qq
    apt-get install -y curl wget git unzip software-properties-common ca-certificates lsb-release apt-transport-https
  else
    echo -e "\n${GREEN}Base apt tools already present. Skipping.${NC}"
  fi
}

ondrej_php_ppa_present() {
  local f
  for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE 'ppa:ondrej/php|ondrej.*php' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

ensure_ondrej_php_ppa() {
  if ondrej_php_ppa_present; then
    echo -e "\n${GREEN}Ondrej PHP PPA already configured. Skipping.${NC}"
    return 0
  fi
  echo -e "\n${CYAN}Adding Ondrej PHP PPA...${NC}"
  apt-get update -qq
  if ! add-apt-repository ppa:ondrej/php -y; then
    echo -e "${RED}Failed to add ppa:ondrej/php${NC}"
    exit 1
  fi
}

# Ondrej/sury: php-ctype, php-json, php-fileinfo, php-tokenizer, php-exif, php-sockets are
# virtual (provided by phpX.Y-common once php-cli is installed). php-opcache is virtual;
# install php${VER}-opcache after the default PHP version is known.
PHP_PKGS=(
  php-cli php-fpm
  php-mysql php-pgsql php-sqlite3
  php-mbstring php-xml php-curl php-zip php-gd
  php-bcmath php-redis php-intl php-readline
  php-imagick php-soap
)

ensure_php_packages() {
  local missing=()
  local p
  for p in "${PHP_PKGS[@]}"; do
    pkg_is_installed "$p" || missing+=("$p")
  done

  local PHP_VERSION=""
  if command -v php &>/dev/null; then
    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  fi

  local opcache_pkg=""
  if [[ -n "$PHP_VERSION" ]]; then
    opcache_pkg="php${PHP_VERSION}-opcache"
    pkg_is_installed "$opcache_pkg" || missing+=("$opcache_pkg")
  fi

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo -e "\n${GREEN}All PHP packages already installed. Skipping.${NC}"
  else
    echo -e "\n${CYAN}Installing PHP packages (${#missing[@]} missing)...${NC}"
    ensure_ondrej_php_ppa
    apt-get update -qq
    apt-get install -y "${missing[@]}"
  fi

  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  opcache_pkg="php${PHP_VERSION}-opcache"
  if ! pkg_is_installed "$opcache_pkg"; then
    echo -e "\n${CYAN}Installing ${opcache_pkg}...${NC}"
    ensure_ondrej_php_ppa
    apt-get update -qq
    apt-get install -y "$opcache_pkg"
  fi

  local PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
  if ! systemctl enable "$PHP_FPM_SERVICE" 2>/dev/null; then
    echo -e "${YELLOW}Warning: ${PHP_FPM_SERVICE} not found. Check PHP-FPM installation.${NC}"
  fi
  systemctl start "$PHP_FPM_SERVICE" 2>/dev/null || true
}

ensure_nginx() {
  if command -v nginx &>/dev/null; then
    echo -e "\n${GREEN}Nginx already installed. Skipping.${NC}"
    return 0
  fi
  echo -e "\n${CYAN}Installing Nginx...${NC}"
  apt-get update -qq
  apt-get install -y nginx
  systemctl enable nginx
}

ensure_mysql() {
  if [[ -f /usr/bin/mysql ]] || pkg_is_installed mysql-server; then
    echo -e "\n${GREEN}MySQL server already present. Skipping.${NC}"
    systemctl enable mysql 2>/dev/null || true
    return 0
  fi
  echo -e "\n${CYAN}Installing MySQL server...${NC}"
  apt-get update -qq
  apt-get install -y mysql-server
  systemctl enable mysql
}

ensure_redis() {
  if [[ -f /usr/bin/redis-server ]] || pkg_is_installed redis-server; then
    echo -e "\n${GREEN}Redis already present. Skipping.${NC}"
    systemctl enable redis-server 2>/dev/null || true
    return 0
  fi
  echo -e "\n${CYAN}Installing Redis...${NC}"
  apt-get update -qq
  apt-get install -y redis-server
  systemctl enable redis-server
}

ensure_composer() {
  if command -v composer &>/dev/null; then
    echo -e "\n${GREEN}Composer already installed. Skipping.${NC}"
    return 0
  fi
  echo -e "\n${CYAN}Installing Composer...${NC}"
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  if ! php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; then
    echo -e "${RED}Composer installation failed.${NC}"
    rm -f /tmp/composer-setup.php
    exit 1
  fi
  rm -f /tmp/composer-setup.php
  echo -e "${GREEN}Composer installed at /usr/local/bin/composer${NC}"
}

ensure_node_pm2() {
  if command -v node &>/dev/null; then
    echo -e "\n${GREEN}Node.js already installed.${NC}"
  else
    echo -e "\n${CYAN}Installing Node.js 20.x and npm...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  if command -v pm2 &>/dev/null; then
    echo -e "${GREEN}PM2 already installed. Skipping.${NC}"
  else
    echo -e "${CYAN}Installing PM2 globally...${NC}"
    npm install -g pm2
  fi
}

ensure_certbot() {
  local missing=0
  pkg_is_installed certbot || missing=1
  pkg_is_installed python3-certbot-nginx || missing=1
  if [[ "$missing" -eq 0 ]]; then
    echo -e "\n${GREEN}Certbot (nginx plugin) already installed. Skipping.${NC}"
    return 0
  fi
  echo -e "\n${CYAN}Installing Certbot and python3-certbot-nginx...${NC}"
  apt-get update -qq
  apt-get install -y certbot python3-certbot-nginx
}

ensure_wp_cli() {
  if command -v wp &>/dev/null; then
    echo -e "\n${GREEN}WP-CLI already installed. Skipping.${NC}"
    return 0
  fi
  echo -e "\n${CYAN}Installing WP-CLI...${NC}"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
  php /tmp/wp-cli.phar --info >/dev/null
  chmod +x /tmp/wp-cli.phar
  mv /tmp/wp-cli.phar /usr/local/bin/wp
  echo -e "${GREEN}WP-CLI installed at /usr/local/bin/wp${NC}"
}

# --- System update / upgrade (upgrade only; not dist-upgrade) ---
echo -e "\n${CYAN}[1] apt-get update && apt-get upgrade -y${NC}"
apt-get update -qq
apt-get upgrade -y

ensure_apt_base_tools
ensure_php_packages
ensure_nginx
ensure_mysql
ensure_redis
ensure_composer
ensure_node_pm2
ensure_certbot
ensure_wp_cli

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}     INSTALLATION COMPLETE                          ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${CYAN}Next: run setup.sh or deploy.sh for vhosts and sites.${NC}\n"
