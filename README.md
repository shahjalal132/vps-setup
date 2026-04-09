# Laravel VPS Auto-Setup Script

This script provides a seamless, one-liner solution to transform a fresh **Ubuntu VPS** into a production-ready environment for **Laravel** applications. It automates the installation of the entire LEMP stack, security headers, and SSL certificates.

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
- **Security:** Certbot (Let's Encrypt SSL) with automatic HTTP to HTTPS redirection
- **Utility:** Zip, Unzip, Git, Curl

## 📋 Prerequisites
Before running the script, ensure:
1. You are using a fresh **Ubuntu** (20.04, 22.04, or 24.04) VPS.
2. Your **Domain Name** (e.g., `domain.example.com`) is already pointing to your VPS IP address (A Record).

## ⚙️ How it works
1. **Interactive Prompt:** The script will ask for your desired **directory name**, **domain name**, and **email address**.
2. **Automated Install:** It installs the full stack without further input.
3. **Directory Logic:** It creates your project folder at `/var/www/your_directory_name`.
4. **Nginx & SSL:** It creates a virtual host, requests an SSL certificate from Let's Encrypt, and configures a clean SSL redirect.
5. **Smoke Test:** It creates a `public/index.php` file so you can visit your domain immediately to verify the setup is working.

## ✅ Post-Installation Steps
Once the script finishes:
1. **Secure MySQL:** Run `sudo mysql_secure_installation` to set your database root password.
2. **Deploy App:** Clone your Laravel repository into the directory created by the script.
3. **Queue Workers:** Start your Laravel workers using PM2:
   ```bash
   pm2 start "php artisan queue:work --tries=3" --name example-worker
   ```

## 📄 License
This project is open-source and available under the [MIT License](LICENSE).

---
*Maintained by [Muhammad Shahjalal](https://github.com/shahjalal132)*