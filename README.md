# Laravel VPS Auto-Setup Script

This script provides a seamless, one-liner solution to transform a fresh **Ubuntu VPS** into a production-ready environment for **Laravel** applications. It automates the installation of the LEMP stack and an HTTP-only Nginx site; **HTTPS (Let's Encrypt) is configured after installation** (see [Post-Installation Steps](#post-installation-steps)).

## 🚀 The One-Liner Setup

Run this command on your fresh VPS as a **root** user:

```bash
curl -sSL https://raw.githubusercontent.com/shahjalal132/vps-setup/main/setup.sh | sudo bash
```

---

## 🛠 What this script installs
The script installs and configures a modern, high-performance stack optimized for Laravel:

- **Web Server:** Nginx (with Laravel-optimized virtual host config)
- **PHP:** 8.3 (FPM) with all required extensions (`bcmath`, `xml`, `mbstring`, `redis`, etc.)
- **Database:** MySQL Server
- **Caching/Queue:** Redis Server (High-performance queue driver)
- **Process Manager:** Node.js (v20) & PM2 (to keep your Laravel workers/Horizon alive)
- **HTTPS:** Not installed by the script—use Certbot after DNS works (steps below)
- **Utility:** Zip, Unzip, Git, Curl

## 📋 Prerequisites
Before running the script, ensure:
1. You are using a fresh **Ubuntu** (20.04, 22.04, or 24.04) VPS.
2. Your **Domain Name** (e.g., `domain.example.com`) is already pointing to your VPS IP address (A Record).

## ⚙️ How it works
1. **Interactive Prompt:** The script asks for your **directory name** and **primary domain**.
2. **Automated Install:** It installs the full stack without further input.
3. **Directory Logic:** It creates your project folder at `/var/www/your_directory_name`.
4. **Nginx (HTTP):** It writes a Laravel-style virtual host on port **80** at `/etc/nginx/sites-available/<domain>` and enables it.
5. **Smoke Test:** It creates a `public/index.php` file so you can visit your domain over HTTP to verify the setup before enabling HTTPS.

## ✅ Post-Installation Steps
Once the script finishes:
1. **Secure MySQL:** Run `sudo mysql_secure_installation` to set your database root password.
2. **Deploy App:** Clone your Laravel repository into the directory created by the script.
3. **Queue Workers:** Start your Laravel workers using PM2:
   ```bash
   pm2 start "php artisan queue:work --tries=3" --name example-worker
   ```

### HTTPS (Let's Encrypt) and Nginx

The script leaves Nginx on **port 80 only**. After your domain resolves to the VPS and the site loads in the browser, add TLS:

1. **Install Certbot** with the Nginx plugin:
   ```bash
   sudo apt update
   sudo apt install -y certbot python3-certbot-nginx
   ```

2. **Obtain and install a certificate** (use your real domain and email):
   ```bash
   sudo certbot --nginx -d yourdomain.example.com -d www.yourdomain.example.com --email you@example.com --agree-tos --non-interactive
   ```
   Drop `--non-interactive` if you prefer Certbot’s prompts. Certbot will edit the server block under `/etc/nginx/sites-available/<yourdomain>` to add `listen 443 ssl` and typically redirects HTTP to HTTPS.

3. **Validate Nginx after changes** (do this any time you edit the vhost by hand):
   ```bash
   sudo nginx -t && sudo systemctl reload nginx
   ```

4. **Renewal:** Certbot sets up automatic renewal. Check timers with `systemctl list-timers | grep certbot` and test with:
   ```bash
   sudo certbot renew --dry-run
   ```

**Nginx layout:** The script sets `root` to `/var/www/<directory>/public`, `server_name` to your domain and `www`, PHP to `php8.3-fpm`, and Laravel-style `try_files`. The live config file is `/etc/nginx/sites-available/<domain>` (enabled via `sites-enabled`). After Certbot, that file holds your TLS directives; keep the `location ~ \.php$` and `try_files` blocks intact when editing.

## 📄 License
This project is open-source and available under the [MIT License](LICENSE).

---
*Maintained by [Muhammad Shahjalal](https://github.com/shahjalal132)*