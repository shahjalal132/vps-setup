#!/bin/bash

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Header ---
clear
echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}       LARAVEL VPS AUTO-SETUP (HTTP ONLY)          ${NC}"
echo -e "${CYAN}====================================================${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Please run as root (use sudo)${NC}"
  exit 1
fi

# --- Capture User Inputs ---
exec 3< /dev/tty
echo -e "${YELLOW}Step 1: Configuration${NC}"
read -u 3 -p "Enter project directory name (e.g., example): " DIR_NAME
read -u 3 -p "Enter primary domain (e.g., domain.example.com): " DOMAIN_NAME
exec 3<&-

if [[ -z "$DIR_NAME" || -z "$DOMAIN_NAME" ]]; then
    echo -e "${RED}Error: Inputs cannot be empty.${NC}"
    exit 1
fi

# --- 1. System Update ---
echo -e "\n${CYAN}[1/8] Updating system packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y curl wget git unzip software-properties-common ca-certificates lsb-release apt-transport-https

# --- 2. Install latest PHP + Laravel extensions ---
echo -e "\n${CYAN}[2/8] Installing latest PHP and extensions...${NC}"
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y \
    php-cli php-fpm \
    php-mysql php-pgsql php-sqlite3 \
    php-mbstring php-xml php-curl php-zip php-gd \
    php-bcmath php-ctype php-json php-fileinfo php-tokenizer \
    php-redis php-opcache php-intl php-exif php-sockets php-readline

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
PHP_FPM_SOCK="/var/run/php/php${PHP_VERSION}-fpm.sock"

if ! systemctl enable "$PHP_FPM_SERVICE" 2>/dev/null; then
    echo -e "${YELLOW}Warning: ${PHP_FPM_SERVICE} not found. Check PHP-FPM installation.${NC}"
fi

# --- 3. Install Composer ---
if ! command -v composer &> /dev/null; then
    echo -e "\n${CYAN}[3/8] Installing Composer...${NC}"
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    if ! php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer; then
        echo -e "${RED}Composer installation failed.${NC}"
        rm -f /tmp/composer-setup.php
        exit 1
    fi
    rm -f /tmp/composer-setup.php
    echo -e "${GREEN}Composer installed at /usr/local/bin/composer${NC}"
else
    echo -e "\n${GREEN}[3/8] Composer already installed. Skipping...${NC}"
fi

# --- 4. Install Nginx ---
if ! command -v nginx &> /dev/null; then
    echo -e "\n${CYAN}[4/8] Installing Nginx...${NC}"
    apt install -y nginx
    systemctl enable nginx
else
    echo -e "\n${GREEN}[4/8] Nginx already installed. Skipping...${NC}"
fi

# --- 5. Install MySQL & Redis ---
echo -e "\n${CYAN}[5/8] Checking MySQL and Redis...${NC}"
[[ ! -f /usr/bin/mysql ]] && apt install -y mysql-server && systemctl enable mysql
[[ ! -f /usr/bin/redis-server ]] && apt install -y redis-server && systemctl enable redis-server

# --- 6. Install Node.js & PM2 ---
if ! command -v node &> /dev/null; then
    echo -e "\n${CYAN}[6/8] Installing Node.js & PM2...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
    npm install -g pm2
else
    echo -e "\n${GREEN}[6/8] Node.js already installed. Skipping...${NC}"
fi

# --- 7. Directory Setup ---
echo -e "\n${CYAN}[7/8] Setting up directory /var/www/$DIR_NAME...${NC}"
if [ ! -d "/var/www/$DIR_NAME" ]; then
    mkdir -p /var/www/"$DIR_NAME"/public
    chown -R www-data:www-data /var/www/"$DIR_NAME"
    chmod -R 775 /var/www/"$DIR_NAME"
    
    cat <<EOF > /var/www/"$DIR_NAME"/public/index.php
<?php
echo "<h1>Setup Successful for $DOMAIN_NAME</h1>";
echo "PHP Version: " . phpversion() . "<br>";
echo "Time: " . date('Y-m-d H:i:s');
EOF
else
    echo -e "${YELLOW}Directory exists. Skipping creation...${NC}"
fi

# --- 8. Nginx Config & Repair ---
echo -e "\n${CYAN}[8/8] Configuring Nginx...${NC}"

# CRITICAL: Fix previous broken symlink error
# This removes the "sites-available is a directory" error from previous runs
rm -f /etc/nginx/sites-enabled/sites-available
rm -f /etc/nginx/sites-enabled/default

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN_NAME"

cat <<EOF > "$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    root /var/www/$DIR_NAME/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php index.html;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    location ~ \.php$ {
        fastcgi_pass unix:$PHP_FPM_SOCK;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

# Ensure clean symlink
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

echo -e "${YELLOW}Checking Nginx Syntax...${NC}"
if nginx -t; then
    systemctl restart nginx
    echo -e "${GREEN}Nginx started successfully.${NC}"
else
    echo -e "${RED}Nginx syntax check failed. Check your config at $NGINX_CONF${NC}"
fi

# --- Final Summary ---
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}      DEPLOYMENT PREPARATION COMPLETE!             ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${YELLOW}URL: http://$DOMAIN_NAME${NC}"
echo -e "${YELLOW}Path: /var/www/$DIR_NAME${NC}"
echo -e "${CYAN}Read README.md for Post-Installation steps.${NC}"
echo -e "${GREEN}====================================================${NC}\n"
