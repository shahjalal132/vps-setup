# MariaDB Master-Slave Replication & High Availability Guide

This guide details the process of migrating from MySQL 8.0 to MariaDB and setting up a robust Master-Slave replication environment for WordPress, ensuring 100% data safety and fast failover.

> [!CAUTION]
> **CRITICAL WARNING**: Since MySQL 8.0, MariaDB is no longer a "drop-in replacement." Due to changes in data dictionaries and authentication methods, you **cannot** install MariaDB directly over MySQL 8.0. Doing so will likely corrupt your data. The **Dump-and-Restore** method described below is the only professional way to migrate.

---

## Part 1: Migration (MySQL 8.0 to MariaDB)

### Phase 1: The Safety Backup
Run this on both servers before starting the migration.

```bash
# Create a backup folder
mkdir -p ~/db_migration

# Dump all databases including users, routines, and triggers
sudo mysqldump --all-databases --routines --triggers --events -u root -p > ~/db_migration/full_backup.sql
```
*Verify that `full_backup.sql` exists and has a size greater than 0 before proceeding.*

### Phase 2: Remove MySQL Completely
Wipe the system clean to avoid configuration conflicts.

```bash
# 1. Stop MySQL service
sudo systemctl stop mysql

# 2. Purge MySQL packages
sudo apt purge mysql-server mysql-client mysql-common mysql-server-core-* mysql-client-core-* -y

# 3. Clean up dependencies
sudo apt autoremove -y
sudo apt autoclean

# 4. Archive old data directories (Safety first)
sudo mv /var/lib/mysql /var/lib/mysql_old
sudo mv /etc/mysql /etc/mysql_old
```

### Phase 3: Install MariaDB
```bash
sudo apt update
sudo apt install mariadb-server mariadb-client -y

# Start and enable the service
sudo systemctl start mariadb
sudo systemctl enable mariadb
```

### Phase 4: Secure and Restore Data
1. **Run Security Script**:
   `sudo mysql_secure_installation`
2. **Restore Backup**:
   ```bash
   sudo mysql -u root -p < ~/db_migration/full_backup.sql
   ```
3. **Finish**:
   ```sql
   sudo mysql -u root -p -e "FLUSH PRIVILEGES;"
   ```

### Phase 5: Troubleshooting Collation Errors (`utf8mb4_0900_ai_ci`)

As a DevOps engineer, you might see this error frequently when migrating from **MySQL 8.0** to **MariaDB**.

#### The Reason
The collation `utf8mb4_0900_ai_ci` is a new default specific to **MySQL 8.0**. MariaDB does not recognize it because it uses a different internal logic for sorting. When you try to import a MySQL 8.0 dump into MariaDB, it fails because it doesn't know what `0900_ai_ci` means.

#### The Professional Fix
We need to "downgrade" the collation in your SQL dump file to one that MariaDB understands, which is `utf8mb4_unicode_ci`.

Run these two `sed` commands to find and replace the problematic strings in your SQL file (`full_backup.sql`) before importing:

```bash
# 1. Replace the 0900 collation with the standard unicode collation
sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql

# 2. Replace any remaining references to general utf8mb4 collation compatibility
sed -i 's/utf8mb4_general_ci/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql
```

#### Why `utf8mb4_unicode_ci`?
For a WordPress site, `utf8mb4_unicode_ci` is the safest and most compatible choice. It supports emojis and all international characters perfectly in MariaDB.

#### Step-by-Step Recovery Flow

1.  **Run the Fix Command:**
    ```bash
    sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql
    ```

2.  **Try the Import again:**
    ```bash
    sudo mysql -u root -p < ~/db_migration/full_backup.sql
    ```

3.  **If it still gives a similar error (e.g., about `utf8mb4_0900_nopad_ai_ci`):**
    Run this broader replace command:
    ```bash
    sed -i 's/utf8mb4_0900_[^ ]*/utf8mb4_unicode_ci/g' ~/db_migration/full_backup.sql
    ```

#### Pro DevOps Tip: Prevention
Next time you create a dump from a MySQL 8 server to move to MariaDB, use this flag to avoid this issue entirely:

```bash
mysqldump --default-character-set=utf8mb4 --skip-set-charset --all-databases --routines --triggers --events -u root -p > ~/db_migration/full_backup.sql
```

---

### Phase 6: Verification (WordPress)
1. **Status Check**: `sudo systemctl status mariadb`
2. **Compatibility**: PHP 8.3 `php-mysql` extension works for both.
3. **Database Connection Check**: If "Error Establishing a Database Connection" appears on `pvamarkets.com`, reset the user password:
   ```sql
   ALTER USER 'pva_user'@'localhost' IDENTIFIED BY 'YourOldPassword';
   ```

---

## Part 2: The "Mirror and the Switch" Strategy

This architecture uses a **Master-Slave (Warm Standby)** setup for high availability.

### 1. Database Replication (Master-Slave)

**Main Server (VPS 1 - Master)**:
1. Edit `/etc/mysql/mariadb.conf.d/50-server.cnf`:
   ```ini
   bind-address = 0.0.0.0
   server-id = 1
   log_bin = /var/log/mysql/mariadb-bin.log
   binlog_do_db = pvamarkets
   ```
2. Create Replication User:
   ```sql
   GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'SECONDARY_VPS_IP' IDENTIFIED BY 'StrongPassword';
   FLUSH PRIVILEGES;
   SHOW MASTER STATUS; -- Save the File and Position values!
   ```

**Secondary Server (VPS 2 - Slave)**:
1. Set `server-id = 2` in the config file.
2. Connect to Master:
   ```sql
   CHANGE MASTER TO 
     MASTER_HOST='MAIN_VPS_IP', 
     MASTER_USER='replicator', 
     MASTER_PASSWORD='StrongPassword', 
     MASTER_LOG_FILE='[File_from_Master]', 
     MASTER_LOG_POS=[Position_from_Master];
   START SLAVE;
   ```

### 2. File Sync (lsyncd)
Install on **Main Server** to push files to the Secondary Server instantly.

1. `sudo apt install lsyncd`
2. Edit `/etc/lsyncd/lsyncd.conf.lua`:
   ```lua
   settings {
       logfile = "/var/log/lsyncd/lsyncd.log",
       statusFile = "/var/log/lsyncd/lsyncd.status"
   }
   sync {
       default.rsync,
       source = "/var/www/pvamarkets.com",
       target = "SECONDARY_VPS_IP:/var/www/pvaseller.com",
       rsync = {
           archive = true,
           compress = true,
           _extra = {"-e", "ssh -i /root/.ssh/id_rsa"}
       }
   }
   ```

### 3. Dynamic `wp-config.php`
Allows the same code to serve both domains. Update on **both** servers:

```php
// Detect the domain being used to access the site
$http_host = $_SERVER['HTTP_HOST'];

if (strpos($http_host, 'pvaseller.com') !== false) {
    define('WP_HOME', 'https://pvaseller.com');
    define('WP_SITEURL', 'https://pvaseller.com');
} else {
    define('WP_HOME', 'https://pvamarkets.com');
    define('WP_SITEURL', 'https://pvamarkets.com');
}

define('DB_NAME', 'pvamarkets');
```

---

## Part 3: Emergency Failover Protocol

If `pvamarkets.com` is banned or goes down:

1. **Stop DNS Redirect**: Disable Cloudflare Redirect Rule for `pvaseller.com`.
2. **Update DNS**: Point `pvaseller.com` `A` record to **VPS 2 IP**.
3. **Promote Database**: On VPS 2, run `STOP SLAVE;`. This makes the slave the new Master.
4. **Go Live**: Your site is now functional on the secondary domain with all latest data.
