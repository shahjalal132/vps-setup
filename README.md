# Laravel VPS Auto-Setup Script

This script provides a seamless, one-liner solution to transform a fresh **Ubuntu VPS** into a production-ready environment for **Laravel** applications. It automates the installation of the LEMP stack and an HTTP-only Nginx site; **HTTPS (Let's Encrypt) is configured after installation** (see [Post-Installation Steps](#post-installation-steps)).

## 🚀 The One-Liner Setup

Run this command on your fresh VPS as a **root** user:

```bash
curl -sSL https://raw.githubusercontent.com/shahjalal132/vps-setup/main/setup.sh | sudo bash
```

`setup.sh` is **independent**: it does not call other scripts in this repo. For a **non-interactive** install of the same stack (plus WordPress-oriented PHP extensions, Certbot, and WP-CLI) without creating a vhost, run **`installation.sh`** separately:

```bash
curl -sSL https://raw.githubusercontent.com/shahjalal132/vps-setup/main/installation.sh | sudo bash
```

### Multi-site smoke test (`smoke-test.sh`)

Use **`smoke-test.sh`** when you already have the stack (or ran `installation.sh`) and want an extra **HTTP-only** Nginx vhost plus a minimal `index.php` under `/var/www/…`. The script asks for a **domain** and **project type** (Laravel uses `public/` as document root; WordPress uses the site root). The directory name is derived from the FQDN (sanitized). Run as **root**:

```bash
curl -sSL https://raw.githubusercontent.com/shahjalal132/vps-setup/main/smoke-test.sh | sudo bash
```

Or from a clone: `sudo bash smoke-test.sh`.

---

## 🛠 What this script installs
The script installs and configures a modern, high-performance stack optimized for Laravel:

- **Web Server:** Nginx (with Laravel-optimized virtual host config)
- **PHP:** 8.3 (CLI + FPM) with all required extensions (`bcmath`, `xml`, `mbstring`, `redis`, etc.)
- **Composer:** Installed to `/usr/local/bin/composer` (official installer)
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
3. **Laravel permissions (`permissions.sh` via `curl`):** After the app code is in place, fix ownership and modes on `storage/` and `bootstrap/cache/` (required for caches, sessions, uploads, and views). The usual way is to download and run the script with **`curl`** on the server (needs `curl` installed—`setup.sh` / `installation.sh` already install it):

   ```bash
   curl -sSL https://raw.githubusercontent.com/shahjalal132/vps-setup/main/permissions.sh | sudo bash
   ```

   Same one-liner with explicit flags: `-s` (silent progress), `-S` (show errors), `-L` (follow redirects).

   Or from a clone of this repo:

   ```bash
   sudo bash permissions.sh
   ```

   `permissions.sh` is **independent** of `setup.sh` and `installation.sh`; use it whenever the Laravel tree exists under `/var/www/<name>`.

   You will be asked for the **project directory name** only (the same segment you used with `setup.sh`, e.g. `example` for `/var/www/example`). The script sets `www-data:www-data` on `storage` and `bootstrap/cache` and `ug+rwx` on those paths so PHP-FPM can write logs, sessions, and compiled views.

4. **Queue Workers:** Start your Laravel workers using PM2.

   **One-off command** (from your Laravel project root, e.g. `/var/www/example`):

   ```bash
   cd /var/www/example
   pm2 start "php artisan queue:work --tries=3" --name example-worker
   ```

   **Recommended: `ecosystem.config.cjs`** — keeps arguments, process count, and restarts in one file. Place it in your **Laravel app root** (same directory as `artisan`) and set `cwd` to that path:

   ```javascript
   // ecosystem.config.cjs
   module.exports = {
     apps: [{
       name: 'sber-ai-worker',
       script: 'php',
       args: 'artisan queue:work --tries=3 --sleep=3 --timeout=60',
       cwd: '/var/www/your-laravel-app',
       instances: 5,
       exec_mode: 'fork',
       autorestart: true,
       watch: false,
       max_memory_restart: '512M',
       env: {
         NODE_ENV: 'production',
       },
       time: true,
     }]
   };
   ```

   **What each part does**

   | Field | Meaning |
   | ----- | -------- |
   | `module.exports` | CommonJS export object PM2 reads when you run `pm2 start ecosystem.config.cjs`. |
   | `apps` | List of processes to manage; you can define multiple workers or sites in one file. |
   | `name` | Label in `pm2 list`, logs, and `pm2 restart sber-ai-worker`. Choose something unique per project. |
   | `script` | Executable PM2 runs first. Here it is `php`; combined with `args`, this is equivalent to `php artisan queue:work …`. |
   | `args` | Arguments passed to `script`. Laravel’s worker is `artisan queue:work` plus queue options (`--tries`, `--sleep`, `--timeout`, etc.). |
   | `cwd` | **Working directory** for the process so `artisan`, `.env`, and `vendor/` resolve correctly. Must be the Laravel root (where `artisan` lives). |
   | `instances` | How many separate worker processes PM2 starts. With `exec_mode: 'fork'`, each instance is its own OS process pulling jobs in parallel. |
   | `exec_mode` | `'fork'` runs one Node-style “app” per instance as a forked process (right for multiple PHP workers). (`cluster` is geared toward Node HTTP servers.) |
   | `autorestart` | If the worker exits or crashes, PM2 starts it again. |
   | `watch` | If `true`, PM2 would restart when files change—usually **off** in production so deploys control restarts. |
   | `max_memory_restart` | Restart the process if RSS exceeds this limit (here `512M`), which limits runaway memory growth. |
   | `env` | Environment variables for the process. `NODE_ENV` is conventional for Node tooling; PHP/Laravel ignore it unless your code or wrappers read it. Add Laravel-related vars here if needed (e.g. `APP_ENV`). |
   | `time` | When `true`, PM2 prefixes log lines with timestamps for easier debugging. |

   **PM2 commands** (run from anywhere; config path can be absolute):

   ```bash
   pm2 start /var/www/your-laravel-app/ecosystem.config.cjs
   pm2 status
   pm2 logs sber-ai-worker
   pm2 restart sber-ai-worker
   pm2 stop sber-ai-worker
   pm2 delete sber-ai-worker
   pm2 save
   sudo env PATH=$PATH pm2 startup systemd -u www-data --hp /var/www
   ```

   Use `pm2 save` after a layout you want to survive reboot; `pm2 startup` registers a systemd unit (user and home path depend on who should run the workers—often `www-data` or your deploy user).

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