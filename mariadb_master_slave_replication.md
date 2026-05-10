# 🗄️ MariaDB Master–Slave Replication & High Availability

> **What this guide covers**  
> Migrating from **MySQL 8.0 → MariaDB** (safely), then building **master–slave replication** for WordPress (or any MariaDB app), plus optional **file sync** (`lsyncd`) and **dynamic URLs** in `wp-config.php`.

---

> [!CAUTION]
> **MySQL 8.0 ≠ drop-in MariaDB**  
> Since MySQL 8.0, MariaDB is **not** a direct replacement: data dictionary and auth differ. **Do not** install MariaDB over MySQL 8.0 in place — you risk corruption. Use the **dump-and-restore** flow below.

---

## 📦 Part 1: Migration (MySQL 8.0 → MariaDB)

### Phase 1: Safety backup

Run on **both** servers before anything destructive.

```bash
# Create a backup folder
mkdir -p ~/db_migration

# Dump all databases including users, routines, and triggers
sudo mysqldump --all-databases --routines --triggers --events -u root -p > ~/db_migration/full_backup.sql
```

> [!TIP]
> Confirm `full_backup.sql` exists and size **> 0** before you continue.

---

### Phase 2: Remove MySQL completely

Wipe packages so old configs do not fight MariaDB.

```bash
# 1. Stop MySQL service
sudo systemctl stop mysql

# 2. Purge MySQL packages
sudo apt purge mysql-server mysql-client mysql-common mysql-server-core-* mysql-client-core-* -y

# 3. Clean up dependencies
sudo apt autoremove -y
sudo apt autoclean

# 4. Archive old data directories (safety first)
sudo mv /var/lib/mysql /var/lib/mysql_old
sudo mv /etc/mysql /etc/mysql_old
```

---

### Phase 3: Install MariaDB

```bash
sudo apt update
sudo apt install mariadb-server mariadb-client -y

sudo systemctl start mariadb
sudo systemctl enable mariadb
```

---

### Phase 4: Secure and restore

| Step | Action |
|------|--------|
| 1 | Run `sudo mysql_secure_installation` |
| 2 | Restore: `sudo mysql -u root -p < ~/db_migration/full_backup.sql` |
| 3 | `sudo mysql -u root -p -e "FLUSH PRIVILEGES;"` |

---

### Phase 5: Collation errors (`utf8mb4_0900_ai_ci`) 🔧

Common when importing **MySQL 8.0** dumps into MariaDB.

#### Why it breaks

`utf8mb4_0900_ai_ci` is **MySQL 8.0–specific**. MariaDB does not implement that collation name the same way, so imports can fail.

#### Fix: normalize the dump

Before import, point collations at something MariaDB understands, e.g. `utf8mb4_unicode_ci`:

```bash
sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql
sed -i 's/utf8mb4_general_ci/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql
```

**Retry import:**

```bash
sudo mysql -u root -p < ~/db_migration/full_backup.sql
```

**If errors mention other `utf8mb4_0900_*` collations:**

```bash
sed -i 's/utf8mb4_0900_[^ ]*/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql
```

> [!TIP]
> **WordPress-friendly choice:** `utf8mb4_unicode_ci` — good emoji / multilingual support on MariaDB.

**Next dump from MySQL 8 → MariaDB** — optional flags to reduce surprises:

```bash
mysqldump --default-character-set=utf8mb4 --skip-set-charset --all-databases \
  --routines --triggers --events -u root -p > ~/db_migration/full_backup.sql
```

---

### Phase 6: Quick verification (WordPress)

- **Service:** `sudo systemctl status mariadb`
- **PHP:** `php-mysql` (e.g. PHP 8.3) works with MariaDB.
- **“Error establishing a database connection”** — reset the app user password (replace `wp_user` with your DB user):

```sql
ALTER USER 'wp_user'@'localhost' IDENTIFIED BY 'YourStrongPassword';
FLUSH PRIVILEGES;
```

---

## 🔄 Part 2: Master–slave replication (“mirror and switch”)

Production-oriented **asynchronous** replication: **master** takes writes; **slave** stays a hot copy.

With **optional** `lsyncd` + a **dynamic** `wp-config.php`, the standby can mirror files + DB. If the primary VPS dies, you can promote the slave quickly.

| Role | Typical use |
|------|----------------|
| **VPS 1 (master)** | Live site → e.g. `https://site1.example.com` |
| **VPS 2 (slave)** | Standby / failover → e.g. `https://site2.example.com` |

**Replication path (conceptual):**

`Master → binary log → slave I/O thread → relay log → slave SQL thread → local DB`

> [!NOTE]
> Examples use placeholder **hostnames**, **database name** `site1_wp`, and password **`YourStrongPassword`**. Replace with your real values. **Do not** commit real passwords to git.

**Config file (Ubuntu/Debian):** `/etc/mysql/mariadb.conf.d/50-server.cnf`

---

### Prerequisites ✅

- [ ] MariaDB migrated on **both** VPSs (dump/restore).
- [ ] Application database exists on both (example name: `site1_wp`).
- [ ] Slave can reach master on **TCP 3306**.
- [ ] MariaDB root (or admin) on both hosts.

**Firewall (master)** — allow only the slave’s IP:

```bash
sudo ufw allow from <SLAVE_VPS_IP> to any port 3306
```

Replace `<SLAVE_VPS_IP>` with your slave’s public (or VPN) address.

---

### 1️⃣ Master configuration (VPS 1)

#### Edit `50-server.cnf`

Under `[mysqld]`:

```ini
[mysqld]
bind-address            = 0.0.0.0
server-id               = 1
log_bin                 = /var/log/mysql/mariadb-bin.log
expire_logs_days        = 10
binlog_do_db            = site1_wp
```

| Directive | Purpose |
|-----------|---------|
| `bind-address` | Listen on all interfaces so the slave can connect. |
| `server-id` | Unique node ID (`1` on master). |
| `log_bin` | Binary log path for replication events. |
| `expire_logs_days` | Binlog retention (avoid filling disk). |
| `binlog_do_db` | Only replicate `site1_wp` (less noise). |

**Log directory:**

```bash
sudo mkdir -p /var/log/mysql
sudo chown mysql:adm /var/log/mysql
sudo chmod 2750 /var/log/mysql
```

#### Restart MariaDB

```bash
sudo systemctl restart mariadb
sudo systemctl status mariadb
```

**If restart fails:** `sudo journalctl -xeu mariadb.service`  
**If AppArmor blocks logs:**

```bash
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.mariadbd
sudo systemctl restart mariadb
```

#### Confirm binary logging

```bash
mysql -u root -p
```

```sql
SHOW MASTER STATUS;
```

Example shape (file/position will differ):

```
+-----------------------+----------+--------------+------------------+
| File                  | Position | Binlog_Do_DB | Binlog_Ignore_DB |
+-----------------------+----------+--------------+------------------+
| mariadb-bin.000001    |      650 | site1_wp     |                  |
+-----------------------+----------+--------------+------------------+
```

#### Replication user (master)

```sql
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'<SLAVE_VPS_IP>' IDENTIFIED BY 'YourStrongPassword';
FLUSH PRIVILEGES;
```

> [!TIP]
> Tight `GRANT … TO 'user'@'slave_ip'` beats `'user'@'%'` for exposure. Store `YourStrongPassword` in a secrets manager, not in the repo.

#### Optional: consistent snapshot

1. **Session A** — lock and read coordinates:

```sql
FLUSH TABLES WITH READ LOCK;
SHOW MASTER STATUS;
```

2. **Session B** — dump (you will be prompted for the root password):

```bash
sudo mysqldump -u root -p site1_wp > ~/site1_wp_master_snapshot.sql
```

3. **Session A:**

```sql
UNLOCK TABLES;
```

4. **Copy to slave** (replace user/host):

```bash
scp ~/site1_wp_master_snapshot.sql deploy@<SLAVE_VPS_IP>:~/
```

---

### 2️⃣ Slave configuration (VPS 2)

#### `50-server.cnf` on slave

```ini
[mysqld]
server-id               = 2
bind-address            = 0.0.0.0
log_bin                 = /var/log/mysql/mariadb-bin.log
expire_logs_days        = 10
binlog_do_db            = site1_wp
read_only               = 1
```

| Setting | Why |
|---------|-----|
| `server-id = 2` | Must differ from master. |
| `log_bin` | Useful if this node is **promoted** to master later. |
| `read_only = 1` | Blocks accidental writes from normal DB users. |

```bash
sudo mkdir -p /var/log/mysql
sudo chown mysql:adm /var/log/mysql
sudo chmod 2750 /var/log/mysql
sudo systemctl restart mariadb
```

#### Import snapshot

```bash
sudo mysql -u root -p site1_wp < ~/site1_wp_master_snapshot.sql
```

#### Point slave at master

Use the **exact** `MASTER_LOG_FILE` and `MASTER_LOG_POS` from `SHOW MASTER STATUS` on the master.

```bash
mysql -u root -p
```

```sql
CHANGE MASTER TO
  MASTER_HOST='<MASTER_VPS_IP>',
  MASTER_USER='replicator',
  MASTER_PASSWORD='YourStrongPassword',
  MASTER_LOG_FILE='mariadb-bin.000001',
  MASTER_LOG_POS=650;

START SLAVE;
```

#### Health check

```sql
SHOW SLAVE STATUS\G
```

Look for:

```
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

If `No`, read `Last_IO_Error` / `Last_SQL_Error`.

---

### 3️⃣ Troubleshooting replication

| Symptom | What to check |
|---------|----------------|
| `SHOW MASTER STATUS` empty | `log_bin`, permissions, restart MariaDB. |
| `Slave_IO_Running` stuck / `No` | Firewall, credentials, correct binlog file/pos; `telnet <MASTER_IP> 3306`; `mysql -u replicator -p -h <MASTER_IP>`. |
| `Slave_SQL_Running: No` | `Last_SQL_Error`; resolve drift or (carefully) `SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;` then `START SLAVE;`. |
| **Error 1236** | Binlog rotated away — increase retention, re-snapshot, `CHANGE MASTER TO` with new coords. |
| **1045** for `replicator` | `GRANT` host list, password, `FLUSH PRIVILEGES` on master. |

---

### 4️⃣ HA stack: file sync (`lsyncd`) 📁

On **VPS 1**, push WordPress (or app) files to **VPS 2** so uploads/plugins/themes match DB replication.

#### Install (VPS 1)

```bash
sudo apt update
sudo apt install -y lsyncd rsync openssh-client
```

#### SSH key for `lsyncd` (passwordless)

```bash
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_lsyncd -N ""
sudo ssh-copy-id -i /root/.ssh/id_lsyncd.pub deploy@<SLAVE_VPS_IP>
sudo ssh -i /root/.ssh/id_lsyncd deploy@<SLAVE_VPS_IP> "echo SSH_OK"
```

#### Target tree on VPS 2

```bash
sudo mkdir -p /var/www/site2.example.com
sudo chown -R www-data:www-data /var/www/site2.example.com
```

#### `/etc/lsyncd/lsyncd.conf.lua` (VPS 1)

```lua
settings {
  logfile      = "/var/log/lsyncd/lsyncd.log",
  statusFile   = "/var/log/lsyncd/lsyncd.status",
  statusInterval = 10,
  nodaemon     = false,
  insist       = true
}

sync {
  default.rsyncssh,
  source    = "/var/www/site1.example.com/",
  host      = "<SLAVE_VPS_IP>",
  targetdir = "/var/www/site2.example.com/",
  delay     = 2,
  delete    = true,
  rsync = {
    archive  = true,
    compress = true,
    verbose  = true,
    _extra = {
      "--omit-dir-times",
      "--no-perms",
      "--no-owner",
      "--no-group"
    }
  },
  ssh = {
    port = 22,
    identityFile = "/root/.ssh/id_lsyncd",
    options = {
      "StrictHostKeyChecking=accept-new"
    }
  },
  exclude = {
    ".git/",
    "wp-content/cache/",
    "wp-content/litespeed/",
    "wp-content/wflogs/",
    "*.log"
  }
}
```

| Option | Meaning |
|--------|---------|
| `delay` | Batch rapid changes. |
| `delete` | Mirror deletions from master → slave. |
| `exclude` | Skip cache/runtime dirs that should rebuild locally. |

#### Start `lsyncd`

```bash
sudo mkdir -p /var/log/lsyncd
sudo chown root:adm /var/log/lsyncd
sudo chmod 755 /var/log/lsyncd
sudo systemctl enable --now lsyncd
sudo systemctl status lsyncd
```

#### Smoke test

**VPS 1:**

```bash
sudo -u www-data touch /var/www/site1.example.com/wp-content/uploads/lsyncd-test.txt
```

**VPS 2:**

```bash
ssh -i /root/.ssh/id_lsyncd deploy@<SLAVE_VPS_IP> \
  "ls -l /var/www/site2.example.com/wp-content/uploads/lsyncd-test.txt"
```

**Logs:** `sudo journalctl -u lsyncd -f` · `sudo tail -f /var/log/lsyncd/lsyncd.log`

---

### 5️⃣ Removing file sync completely 🧹

Use this if you **initialized** with `lsyncd` but later want **DB-only** replication (e.g. you deploy code via CI, or only sync uploads another way).

> [!WARNING]
> After removal, **files on the slave will no longer track the master automatically.** Plan how you update `site2.example.com` (deploy, object storage, manual rsync, etc.).

#### On **VPS 1** (master — where `lsyncd` runs)

1. **Stop and disable the service**

```bash
sudo systemctl stop lsyncd
sudo systemctl disable lsyncd
```

2. **Remove or archive config** (pick one)

```bash
# Archive (easy to restore)
sudo mv /etc/lsyncd/lsyncd.conf.lua /etc/lsyncd/lsyncd.conf.lua.disabled

# Or remove package entirely
sudo apt purge -y lsyncd
sudo apt autoremove -y
```

3. **Optional — remove log dir**

```bash
sudo rm -rf /var/log/lsyncd
```

4. **Optional — retire the SSH key used only for sync**

```bash
sudo rm -f /root/.ssh/id_lsyncd /root/.ssh/id_lsyncd.pub
```

#### On **VPS 2** (slave)

1. **Remove the sync user’s public key from `authorized_keys`** (if you used a dedicated deploy/sync user):

```bash
# Edit the deploy user's authorized_keys and delete the lsyncd line
sudo -u deploy nano ~/.ssh/authorized_keys
```

Or, if the key was appended by `ssh-copy-id`, delete the single line that matches `id_lsyncd.pub` (comment often shows `root@hostname`).

2. **Keep or delete** `/var/www/site2.example.com` — your choice. **MariaDB replication is unaffected** by removing `lsyncd`.

#### Verify

- `systemctl status lsyncd` → **inactive** / unit not found after purge.
- No new files appear on slave when you touch files on master.
- `SHOW SLAVE STATUS\G` on slave still shows **Yes** / **Yes** for IO/SQL threads.

---

### 6️⃣ Dynamic `wp-config.php` (two domains) 🌐

Same codebase on **site1** (primary) and **site2** (standby): set `WP_HOME` / `WP_SITEURL` from the requested host so URLs and admin links stay correct.

**Place this block *before*:** `require_once ABSPATH . 'wp-settings.php';`

```php
/**
 * Dynamic domain: primary vs standby (also supports reverse-proxy forwarded host).
 */
$detected_host = '';

if (!empty($_SERVER['HTTP_X_FORWARDED_HOST'])) {
    $forwarded_host = explode(',', $_SERVER['HTTP_X_FORWARDED_HOST'])[0];
    $detected_host = trim($forwarded_host);
} elseif (!empty($_SERVER['HTTP_HOST'])) {
    $detected_host = trim($_SERVER['HTTP_HOST']);
}

$detected_host = strtolower(preg_replace('/:\d+$/', '', $detected_host));

if ($detected_host === 'site2.example.com' || $detected_host === 'www.site2.example.com') {
    define('WP_HOME', 'https://site2.example.com');
    define('WP_SITEURL', 'https://site2.example.com');
} else {
    define('WP_HOME', 'https://site1.example.com');
    define('WP_SITEURL', 'https://site1.example.com');
}
```

**Optional — allowlist hosts** (reduces host-header abuse):

```php
$allowed_hosts = [
    'site1.example.com',
    'www.site1.example.com',
    'site2.example.com',
    'www.site2.example.com',
];

if (!in_array($detected_host, $allowed_hosts, true)) {
    $detected_host = 'site1.example.com';
}
```

**Checklist**

- [ ] `https://site1.example.com/wp-admin` stays on site1 URLs.
- [ ] `https://site2.example.com/wp-admin` stays on site2 URLs.
- [ ] Clear page / object caches after changes.
- [ ] Behind CDN/proxy: confirm `X-Forwarded-Host` (or your chosen header) is set correctly.

---

### 7️⃣ Failover runbook ⚡

1. Adjust DNS / redirects for **site2** as documented in your provider (e.g. point **A** record to VPS 2).
2. **Promote** MariaDB on VPS 2:

```sql
STOP SLAVE;
SET GLOBAL read_only = 0;
```

3. Send traffic to the standby hostname / IP.

> [!IMPORTANT]
> **Replication is not a backup.** Keep **independent** scheduled backups (off-box).

---

## 🚨 Part 3: Emergency failover (short protocol)

If **site1** is unreachable or blocked:

1. **DNS / CDN** — disable rules that force traffic away from **site2**; point **site2** `A` record to **VPS 2**.
2. **Database** — on VPS 2: `STOP SLAVE;` (and `SET GLOBAL read_only = 0;` if you use `read_only`).
3. **Go live** — site runs on **site2** with data replicated up to the last successful sync.

---

## 📎 Quick reference

| Item | Example placeholder |
|------|---------------------|
| Primary site | `site1.example.com` |
| Standby site | `site2.example.com` |
| DB name | `site1_wp` |
| Replication password | `YourStrongPassword` |
| Master / slave IPs | `<MASTER_VPS_IP>` / `<SLAVE_VPS_IP>` |
| Doc root (master / slave) | `/var/www/site1.example.com` · `/var/www/site2.example.com` |

*Practice failover on a maintenance window before you depend on it.*
