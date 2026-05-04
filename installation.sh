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

# Ondrej PPA only publishes for select Ubuntu releases; probing avoids broken apt on
# newer codenames (e.g. resolute) where Launchpad has no Release file yet.
get_distro_codename() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}

# Prints HTTP status only (200 = PPA has a Release; 404/403 = unsupported suite; 000 = probe failed).
ondrej_php_ppa_release_http_code() {
  local codename="$1"
  local url code
  if [[ -z "$codename" ]]; then
    echo "000"
    return
  fi
  url="https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/${codename}/Release"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 -I "$url" 2>/dev/null || echo 000)"
  echo "$code"
}

ondrej_php_ppa_release_available() {
  local codename="$1"
  [[ "$(ondrej_php_ppa_release_http_code "$codename")" == "200" ]]
}

# Remove only list/source files; does not run apt-get update.
remove_ondrej_php_ppa_source_files_only() {
  local f removed=0
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    if grep -qE 'ppa\.launchpadcontent\.net/ondrej/php|ppa:ondrej/php' "$f" 2>/dev/null; then
      echo -e "${YELLOW}Removing Ondrej PHP PPA apt source: ${f}${NC}"
      rm -f "$f"
      removed=1
    fi
  done
  shopt -u nullglob
  [[ "$removed" -eq 1 ]]
}

remove_ondrej_php_ppa_sources() {
  remove_ondrej_php_ppa_source_files_only || return 0
  apt-get update -qq
}

# Run before any apt-get update so a leftover broken Ondrej entry cannot abort the script.
fix_broken_ondrej_php_before_apt() {
  local codename code
  codename="$(get_distro_codename)"
  [[ -n "$codename" ]] || return 0
  ondrej_php_ppa_present || return 0
  code="$(ondrej_php_ppa_release_http_code "$codename")"
  if [[ "$code" == "404" || "$code" == "403" ]]; then
    echo -e "\n${YELLOW}Ondrej PHP PPA has no Release for '${codename}' (HTTP ${code}). Removing those apt sources so apt can update.${NC}"
    remove_ondrej_php_ppa_source_files_only || true
  fi
}

# If apt still fails (e.g. probe timed out but the PPA line is invalid), strip Ondrej PHP and retry once.
apt_get_update_with_ondrej_recovery() {
  local out ec
  set +e
  out="$(apt-get update -qq 2>&1)"
  ec=$?
  set -e
  if [[ "$ec" -eq 0 ]]; then
    return 0
  fi
  if grep -qiE 'ondrej/php|ppa\.launchpadcontent\.net/ondrej/php' <<<"$out"; then
    echo -e "${YELLOW}apt update failed due to Ondrej PHP PPA. Removing those sources and retrying apt update.${NC}"
    remove_ondrej_php_ppa_source_files_only || true
    apt-get update -qq
    return
  fi
  echo "$out" >&2
  return "$ec"
}

ondrej_php_ppa_present() {
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    if grep -qE 'ppa\.launchpadcontent\.net/ondrej/php|ppa:ondrej/php' "$f" 2>/dev/null; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

ensure_ondrej_php_ppa() {
  local codename code
  codename="$(get_distro_codename)"
  code="$(ondrej_php_ppa_release_http_code "$codename")"

  if [[ "$code" == "404" || "$code" == "403" ]]; then
    echo -e "\n${YELLOW}Ondrej PHP PPA has no Release for '${codename:-unknown}' (HTTP ${code}). Using distribution PHP packages instead.${NC}"
    if ondrej_php_ppa_present; then
      remove_ondrej_php_ppa_sources
    fi
    return 0
  fi

  if [[ "$code" != "200" ]]; then
    echo -e "\n${YELLOW}Could not verify Ondrej PHP PPA (HTTP ${code:-unknown}). Skipping PPA add; using distribution PHP if packages are missing.${NC}"
    return 0
  fi

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
# virtual (provided by phpX.Y-common once php-cli is installed). Ubuntu may ship OPcache
# inside php-cli/php-common with no separate phpX.Y-opcache package — handle that below.
PHP_PKGS=(
  php-cli php-fpm
  php-mysql php-pgsql php-sqlite3
  php-mbstring php-xml php-curl php-zip php-gd
  php-bcmath php-redis php-intl php-readline
  php-imagick php-soap
)

php_opcache_runtime_ok() {
  command -v php &>/dev/null || return 1
  php -r 'exit(extension_loaded("Zend OPcache") || extension_loaded("opcache") ? 0 : 1);' 2>/dev/null
}

# Installs a distro opcache package only if needed; never aborts the script on missing package names.
ensure_php_opcache_for_version() {
  local PHP_VERSION="$1"
  local opcache_pkg="php${PHP_VERSION}-opcache"

  if php_opcache_runtime_ok; then
    echo -e "\n${GREEN}PHP OPcache already available (no separate ${opcache_pkg} needed).${NC}"
    return 0
  fi
  if pkg_is_installed "$opcache_pkg"; then
    return 0
  fi

  echo -e "\n${CYAN}Ensuring PHP OPcache (${opcache_pkg} or php-opcache)...${NC}"
  ensure_ondrej_php_ppa
  apt-get update -qq

  set +e
  if apt-cache --quiet=0 show "$opcache_pkg" &>/dev/null; then
    apt-get install -y "$opcache_pkg"
  fi
  if ! php_opcache_runtime_ok && apt-cache --quiet=0 show php-opcache &>/dev/null; then
    apt-get install -y php-opcache
  fi
  set -e

  if php_opcache_runtime_ok; then
    return 0
  fi
  echo -e "${YELLOW}Warning: could not install a separate OPcache package; if PHP was built with OPcache, you are fine (check: php -v).${NC}"
  return 0
}

ensure_php_packages() {
  local missing=()
  local p
  for p in "${PHP_PKGS[@]}"; do
    pkg_is_installed "$p" || missing+=("$p")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo -e "\n${GREEN}All PHP packages already installed. Skipping.${NC}"
  else
    echo -e "\n${CYAN}Installing PHP packages (${#missing[@]} missing)...${NC}"
    ensure_ondrej_php_ppa
    apt-get update -qq
    apt-get install -y "${missing[@]}"
  fi

  local PHP_VERSION
  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [[ -n "$PHP_VERSION" ]] || PHP_VERSION=""

  if [[ -n "$PHP_VERSION" ]]; then
    ensure_php_opcache_for_version "$PHP_VERSION"
  fi

  if [[ -z "$PHP_VERSION" ]] && command -v php &>/dev/null; then
    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
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
echo -e "\n${CYAN}[0] Prune broken Ondrej PHP PPA (if any) so apt can run${NC}"
fix_broken_ondrej_php_before_apt

echo -e "\n${CYAN}[1] apt-get update && apt-get upgrade -y${NC}"
apt_get_update_with_ondrej_recovery
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
echo -e "${CYAN}Next: run setup.sh or smoke-test.sh for vhosts and sites.${NC}\n"
