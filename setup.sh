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
echo -e "${CYAN}       LARAVEL VPS AUTO-SETUP SCRIPT               ${NC}"
echo -e "${CYAN}====================================================${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Please run as root (use sudo)${NC}"
  exit
fi

# --- User Inputs ---
echo -e "${YELLOW}Step 1: Configuration${NC}"
read -p "Enter project directory name (e.g., sbec): " DIR_NAME
read -p "Enter primary domain (e.g., api.sbec.cymru): " DOMAIN_NAME
read -p "Enter email for SSL (e.g., admin@$DOMAIN_NAME): " EMAIL_ADDR

# --- 1. System Update ---
echo -e "\n${CYAN}[1/8] Updating system packages...${NC}"
apt update && apt upgrade -y
apt install -y curl wget git unzip software-properties-common ca-certificates lsb-release apt-transport-https

# --- 2. Install PHP 8.3 ---
echo -e "\n${CYAN}[2/8] Installing PHP 8.3 and extensions...${NC}"
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.3-fpm php8.3-mysql php8.3-xml php8.3-curl php8.3-mbstring php8.3-zip php8.3-bcmath php8.3-intl php8.3-readline php8.3-redis php8.3-gd php8.3-sqlite3
systemctl enable php8.3-fpm

# --- 3. Install Nginx ---
echo -e "\n${CYAN}[3/8] Installing Nginx...${NC}"
apt install -y nginx
systemctl enable nginx

# --- 4. Install MySQL & Redis ---
echo -e "\n${CYAN}[4/8] Installing MySQL and Redis...${NC}"
apt install -y mysql-server redis-server
systemctl enable mysql
systemctl enable redis-server

# --- 5. Install Node.js & PM2 ---
echo -e "\n${CYAN}[5/8] Installing Node.js (v20) and PM2...${NC}"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
npm install -g pm2

# --- 6. Directory Setup ---
echo -e "\n${CYAN}[6/8] Setting up directory /var/www/$DIR_NAME...${NC}"
mkdir -p /var/www/$DIR_NAME/public
chown -R www-data:www-data /var/www/$DIR_NAME
chmod -R 775 /var/www/$DIR_NAME

# Create dummy index.php for smoke test
cat <<EOF > /var/www/$DIR_NAME/public/index.php
<?php
echo "<h1>Setup Successful for $DOMAIN_NAME</h1>";
echo "PHP Version: " . phpversion() . "<br>";
echo "Time: " . date('Y-m-d H:i:s');
EOF

# --- 7. Nginx Config (Initial Port 80) ---
echo -e "\n${CYAN}[7/8] Configuring Nginx Virtual Host (HTTP)...${NC}"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN_NAME"

# We start with a standard HTTP config so Certbot can verify the domain
cat <<EOF > $NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    root /var/www/$DIR_NAME/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
}
EOF

# Enable site
ln -s $NGINX_CONF /etc/nginx/sites-enabled/ 2>/dev/null
nginx -t && systemctl restart nginx

# --- 8. SSL with Certbot & Final Hardening ---
echo -e "\n${CYAN}[8/8] Installing SSL Certbot & Hardening Config...${NC}"
apt install -y certbot python3-certbot-nginx

# Run Certbot (This adds the SSL certificates)
certbot --nginx -d $DOMAIN_NAME -d www.$DOMAIN_NAME --non-interactive --agree-tos -m $EMAIL_ADDR --redirect

# Overwrite with a Clean, Professional Laravel SSL Config
cat <<EOF > $NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    root /var/www/$DIR_NAME/public;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";

    index index.php index.html;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

# Final Syntax Check and Reload
echo -e "\n${YELLOW}Performing final Nginx syntax check...${NC}"
nginx -t
if [ $? -eq 0 ]; then
    systemctl reload nginx
    echo -e "${GREEN}Nginx reloaded successfully with SSL.${NC}"
else
    echo -e "${RED}Nginx syntax check failed. Please check the config file.${NC}"
fi

# --- Final Summary ---
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}      DEPLOYMENT PREPARATION COMPLETE!             ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "${YELLOW}Project Dir: ${NC} /var/www/$DIR_NAME"
echo -e "${YELLOW}URL:         ${NC} https://$DOMAIN_NAME"
echo -e "${YELLOW}PHP:         ${NC} 8.3"
echo -e "${YELLOW}Next Steps:  ${NC}"
echo -e "1. Run 'sudo mysql_secure_installation' to set DB password."
echo -e "2. Git clone your Laravel app into /var/www/$DIR_NAME"
echo -e "3. Point the .env to your database and set QUEUE_CONNECTION=redis."
echo -e "4. Use 'pm2 start \"php artisan queue:work\" --name worker' for queues."
echo -e "${GREEN}====================================================${NC}\n"