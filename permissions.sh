#!/bin/bash

# Laravel app permissions under /var/www/<directory>.
# Run as root: sudo bash permissions.sh
# (Sudo will prompt for your user password when needed.)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}     LARAVEL PERMISSIONS (storage / bootstrap/cache)${NC}"
echo -e "${CYAN}====================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root: sudo bash $0${NC}"
  exit 1
fi

exec 3< /dev/tty
echo -e "${YELLOW}Configuration${NC}"
read -u 3 -p "Enter project directory name under /var/www (e.g., example): " DIR_NAME
exec 3<&-

if [[ -z "$DIR_NAME" ]]; then
  echo -e "${RED}Error: Directory name cannot be empty.${NC}"
  exit 1
fi

APP_ROOT="/var/www/${DIR_NAME}"

if [[ ! -d "$APP_ROOT" ]]; then
  echo -e "${RED}Error: $APP_ROOT does not exist.${NC}"
  exit 1
fi

if [[ ! -f "$APP_ROOT/artisan" ]]; then
  echo -e "${YELLOW}Warning: artisan not found — is this a Laravel app root? Continuing anyway.${NC}"
fi

echo -e "\n${CYAN}Applying ownership and permissions...${NC}"

# Ensure Laravel writable paths exist (standard tree)
install -d -m 775 -o www-data -g www-data \
  "$APP_ROOT/storage/framework/sessions" \
  "$APP_ROOT/storage/framework/views" \
  "$APP_ROOT/storage/framework/cache" \
  "$APP_ROOT/storage/logs" \
  "$APP_ROOT/bootstrap/cache"

# Web server must write here
chown -R www-data:www-data "$APP_ROOT/storage" "$APP_ROOT/bootstrap/cache"
chmod -R ug+rwx "$APP_ROOT/storage" "$APP_ROOT/bootstrap/cache"

# Allow CLI (deploy user) and PHP-FPM (www-data) to run artisan; optional hardening
if [[ -f "$APP_ROOT/artisan" ]]; then
  chmod ug+x "$APP_ROOT/artisan" 2>/dev/null || true
fi

echo -e "\n${GREEN}Done.${NC}"
echo -e "${YELLOW}Path:${NC} $APP_ROOT"
echo -e "${YELLOW}Set:${NC} storage/ and bootstrap/cache/ → www-data:www-data, ug+rwx"
echo -e "${CYAN}====================================================${NC}\n"
