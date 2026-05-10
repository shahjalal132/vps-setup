#!/bin/bash

# Web app permissions under /var/www/<directory>.
# Run as root: sudo bash permissions.sh
# Remote: curl -sSL https://raw.githubusercontent.com/shahjalal132/vps-setup/main/permissions.sh | sudo bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}     VPS PERMISSIONS (Laravel / WordPress)${NC}"
echo -e "${CYAN}====================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root: sudo bash $0${NC}"
  exit 1
fi

exec 3< /dev/tty
echo -e "\n${YELLOW}Project type${NC}"
echo "  1) Laravel"
echo "  2) WordPress"
read -u 3 -p "Enter choice [1-2]: " PROJECT_TYPE

echo -e "\n${YELLOW}Site path${NC}"
read -u 3 -p "Enter project directory name under /var/www (e.g., staging_pvamarkets_com): " DIR_NAME
exec 3<&-

if [[ -z "$DIR_NAME" ]]; then
  echo -e "${RED}Error: Directory name cannot be empty.${NC}"
  exit 1
fi

case "$PROJECT_TYPE" in
  1|laravel|Laravel) PROJECT_TYPE=1 ;;
  2|wordpress|WordPress) PROJECT_TYPE=2 ;;
  *)
    echo -e "${RED}Error: Invalid choice. Enter 1 for Laravel or 2 for WordPress.${NC}"
    exit 1
    ;;
esac

APP_ROOT="/var/www/${DIR_NAME}"

if [[ ! -d "$APP_ROOT" ]]; then
  echo -e "${RED}Error: $APP_ROOT does not exist.${NC}"
  exit 1
fi

apply_laravel_permissions() {
  if [[ ! -f "$APP_ROOT/artisan" ]]; then
    echo -e "${YELLOW}Warning: artisan not found — is this a Laravel app root? Continuing anyway.${NC}"
  fi

  echo -e "\n${CYAN}Applying Laravel ownership and permissions...${NC}"

  install -d -m 775 -o www-data -g www-data \
    "$APP_ROOT/storage/framework/sessions" \
    "$APP_ROOT/storage/framework/views" \
    "$APP_ROOT/storage/framework/cache" \
    "$APP_ROOT/storage/logs" \
    "$APP_ROOT/bootstrap/cache"

  chown -R www-data:www-data "$APP_ROOT/storage" "$APP_ROOT/bootstrap/cache"
  chmod -R ug+rwx "$APP_ROOT/storage" "$APP_ROOT/bootstrap/cache"

  if [[ -f "$APP_ROOT/artisan" ]]; then
    chmod ug+x "$APP_ROOT/artisan" 2>/dev/null || true
  fi

  echo -e "\n${GREEN}Done.${NC}"
  echo -e "${YELLOW}Path:${NC} $APP_ROOT"
  echo -e "${YELLOW}Set:${NC} storage/ and bootstrap/cache/ → www-data:www-data, ug+rwx"
}

apply_wordpress_permissions() {
  if [[ ! -f "$APP_ROOT/wp-config.php" ]]; then
    echo -e "${YELLOW}Warning: wp-config.php not found — is this a WordPress root? Continuing.${NC}"
  fi

  echo -e "\n${CYAN}Applying WordPress (Nginx) ownership and permissions...${NC}"

  chown -R www-data:www-data "$APP_ROOT"

  find "$APP_ROOT" -type d -exec chmod 755 {} \;
  find "$APP_ROOT" -type f -exec chmod 644 {} \;

  if [[ -f "$APP_ROOT/wp-config.php" ]]; then
    chmod 640 "$APP_ROOT/wp-config.php"
  fi
  if [[ -f "$APP_ROOT/.htaccess" ]]; then
    chmod 644 "$APP_ROOT/.htaccess"
  fi

  if [[ -d "$APP_ROOT/wp-content/uploads" ]]; then
    chmod -R 775 "$APP_ROOT/wp-content/uploads"
    find "$APP_ROOT/wp-content/uploads" -type d -exec chmod 2775 {} \;
  fi
  if [[ -d "$APP_ROOT/wp-content/cache" ]]; then
    chmod -R 775 "$APP_ROOT/wp-content/cache"
  fi
  if [[ -d "$APP_ROOT/wp-content/litespeed" ]]; then
    chmod -R 775 "$APP_ROOT/wp-content/litespeed"
  fi

  echo -e "\n${CYAN}Verifying www-data can read wp-config.php (if present)...${NC}"
  if [[ -f "$APP_ROOT/wp-config.php" ]]; then
    if sudo -u www-data cat "$APP_ROOT/wp-config.php" >/dev/null 2>&1; then
      echo -e "${GREEN}www-data can read wp-config.php (exit 0).${NC}"
    else
      echo -e "${RED}www-data could not read wp-config.php; check ownership.${NC}"
    fi
  fi

  echo -e "\n${GREEN}Done.${NC}"
  echo -e "${YELLOW}Path:${NC} $APP_ROOT"
  echo -e "${YELLOW}Set:${NC} www-data:www-data; dirs 755, files 644; wp-config 640; uploads (and cache/litespeed if present) 775 + setgid on upload dirs"
}

if [[ "$PROJECT_TYPE" == "1" ]]; then
  apply_laravel_permissions
else
  apply_wordpress_permissions
fi

echo -e "${CYAN}====================================================${NC}\n"
