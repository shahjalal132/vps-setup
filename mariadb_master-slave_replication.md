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

## Part 2: Master-Slave Replication - The "Mirror and the Switch" Strategy

This section provides a detailed, production-ready guide for configuring MariaDB Master-Slave replication between two VPS instances.
The architecture implements a **warm standby** high-availability model for a WordPress site (or any MariaDB-backed application) using **asynchronous replication**.

When combined with file synchronization (`lsyncd`) and a dynamic `wp-config.php`, the slave becomes a fully functional, always up-to-date clone of the master.
In case the primary VPS fails, the secondary can be promoted to master within seconds with near-zero data loss.

---

### 1. Architecture Overview

- **VPS 1 (Master)**: Handles all write operations. The live site `pvamarkets.com` points here.
- **VPS 2 (Slave)**: Maintains a real-time, read-only copy of the database. The failover site `pvaseller.com` is served from this machine.
- **Replication flow**:
  Master -> binary log -> Slave I/O thread -> relay log -> Slave SQL thread -> local database.
- **All configuration changes in this section are applied to `/etc/mysql/mariadb.conf.d/50-server.cnf`**, the primary MariaDB server configuration file on Ubuntu/Debian systems.

**Prerequisites**
- MariaDB successfully migrated from MySQL 8.0 on **both** VPSs (using dump-and-restore).
- The application database `pvamarkets` exists on both servers.
- Network connectivity: the slave must be able to reach the master on TCP port `3306`.
- Root access to MariaDB on both servers.

Allow only the slave IP to connect to MariaDB on the master:

```bash
sudo ufw allow from 185.95.159.146 to any port 3306
```

### 2. Master Configuration (VPS 1)

#### 2.1 Edit MariaDB Configuration

Open `/etc/mysql/mariadb.conf.d/50-server.cnf` and add/uncomment these lines under `[mysqld]`:

```ini
[mysqld]
bind-address            = 0.0.0.0
server-id               = 1
log_bin                 = /var/log/mysql/mariadb-bin.log
expire_logs_days        = 10
binlog_do_db            = pvamarkets
```

What each directive does:

| Directive | Purpose |
|---|---|
| `bind-address` | Listens on all network interfaces so the slave can connect remotely. |
| `server-id` | Unique replication node ID. Master is `1`. |
| `log_bin` | Enables binary logging and sets file location for change events. |
| `expire_logs_days` | Rotates old binlogs (10 days) to avoid disk bloat while preserving catch-up window. |
| `binlog_do_db` | Limits binlogging to `pvamarkets` to reduce noise and overhead. |

If `/var/log/mysql` does not exist:

```bash
sudo mkdir -p /var/log/mysql
sudo chown mysql:adm /var/log/mysql
sudo chmod 2750 /var/log/mysql
```

#### 2.2 Restart and Verify MariaDB

```bash
sudo systemctl restart mariadb
sudo systemctl status mariadb
```

If restart fails:

```bash
sudo journalctl -xeu mariadb.service
```

If AppArmor blocks the log path:

```bash
sudo apparmor_parser -r /etc/apparmor.d/usr.sbin.mariadbd
sudo systemctl restart mariadb
```

#### 2.3 Confirm Binary Logging

```bash
mysql -u root -p
```

```sql
SHOW MASTER STATUS;
```

Expected shape:

```
+-----------------------+----------+--------------+------------------+
| File                  | Position | Binlog_Do_DB | Binlog_Ignore_DB |
+-----------------------+----------+--------------+------------------+
| mariadb-bin.000001    |      650 | pvamarkets   |                  |
+-----------------------+----------+--------------+------------------+
```

If empty, binary logging is not active. Re-check `log_bin` and MariaDB logs.

#### 2.4 Create Replication User

```sql
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'185.95.159.146' IDENTIFIED BY 'StrongPassword123!';
FLUSH PRIVILEGES;
```

Notes:
- `REPLICATION SLAVE` is the only required privilege.
- Restricting by slave IP improves security.
- Use a strong password and store it securely.

#### 2.5 Take a Consistent Snapshot (Optional but Recommended)

1) Lock writes and capture exact coordinates:

```sql
FLUSH TABLES WITH READ LOCK;
SHOW MASTER STATUS;
```

2) From a second terminal, dump database:

```bash
sudo mysqldump -u root -pStrongPassword123! pvamarkets > ~/pvamarkets_master_snapshot.sql
```

3) Unlock tables:

```sql
UNLOCK TABLES;
```

4) Copy dump to slave:

```bash
scp ~/pvamarkets_master_snapshot.sql user@185.95.159.146:~/
```

### 3. Slave Configuration (VPS 2)

#### 3.1 Edit MariaDB Configuration

On VPS 2 (`/etc/mysql/mariadb.conf.d/50-server.cnf`):

```ini
[mysqld]
server-id               = 2
bind-address            = 0.0.0.0
log_bin                 = /var/log/mysql/mariadb-bin.log
expire_logs_days        = 10
binlog_do_db            = pvamarkets
read_only               = 1
```

Why:
- `server-id = 2`: must be unique.
- `log_bin`: needed if this slave is later promoted to master.
- `read_only = 1`: blocks accidental writes from regular users.

Ensure log directory exists:

```bash
sudo mkdir -p /var/log/mysql
sudo chown mysql:adm /var/log/mysql
sudo chmod 2750 /var/log/mysql
```

#### 3.2 Restart MariaDB

```bash
sudo systemctl restart mariadb
```

#### 3.3 Import Initial Snapshot

```bash
sudo mysql -u root -p pvamarkets < ~/pvamarkets_master_snapshot.sql
```

If using an older dump, ensure it matches the recorded master binlog coordinates.

#### 3.4 Configure Replication Link

```bash
mysql -u root -p
```

```sql
CHANGE MASTER TO
  MASTER_HOST='<MAIN_VPS_IP>',
  MASTER_USER='replicator',
  MASTER_PASSWORD='StrongPassword123!',
  MASTER_LOG_FILE='mariadb-bin.000001',
  MASTER_LOG_POS=650;
```

Then start replication:

```sql
START SLAVE;
```

#### 3.5 Verify Replication Health

```sql
SHOW SLAVE STATUS\G
```

Confirm:

```
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
```

If either thread is `No`, inspect `Last_IO_Error` or `Last_SQL_Error`.

### 4. Troubleshooting Common Replication Issues

#### 4.1 `SHOW MASTER STATUS` returns empty set
- Cause: binary logging disabled or MariaDB not restarted.
- Fix: validate `log_bin`, permissions, and restart service.

#### 4.2 `Slave_IO_Running: Connecting` or `No`
- Check firewall, host/user/password, and master log coordinates.
- Test TCP: `telnet MASTER_IP 3306`
- Test auth: `mysql -u replicator -p -h MASTER_IP`
- If binlog is purged, resnapshot and reconfigure with fresh coordinates.

#### 4.3 `Slave_SQL_Running: No`
- Usually data conflict (e.g., duplicate key or out-of-order change).
- Check `Last_SQL_Error`.
- If safe and validated:
  ```sql
  SET GLOBAL SQL_SLAVE_SKIP_COUNTER = 1;
  START SLAVE;
  ```

#### 4.4 Fatal error 1236
- Means requested binlog file/position no longer exists on master.
- Increase binlog retention and re-seed from a fresh snapshot.

#### 4.5 Error 1045 (Access denied for `replicator`)
- Re-check password and host/IP restriction in `GRANT`.
- Run `FLUSH PRIVILEGES` on master.

### 5. Next Steps in the HA Stack

1. **File synchronization (`lsyncd`)**
   - Install on master to mirror WordPress files to VPS 2 over SSH/rsync.

2. **Dynamic `wp-config.php`**
   - Detect domain (`pvamarkets.com` vs `pvaseller.com`) and set `WP_HOME`/`WP_SITEURL` accordingly on both nodes.

3. **Failover runbook**
   - Disable DNS redirect for `pvaseller.com`.
   - Point DNS `A` record to VPS 2.
   - Promote slave:
     ```sql
     STOP SLAVE;
     SET GLOBAL read_only = 0;
     ```
   - Bring traffic live on standby domain.

> Practice failover regularly. Replication is not a backup strategy, so keep independent scheduled backups.

---

## Part 3: Emergency Failover Protocol

If `pvamarkets.com` is banned or goes down:

1. **Stop DNS Redirect**: Disable Cloudflare Redirect Rule for `pvaseller.com`.
2. **Update DNS**: Point `pvaseller.com` `A` record to **VPS 2 IP**.
3. **Promote Database**: On VPS 2, run `STOP SLAVE;`. This makes the slave the new Master.
4. **Go Live**: Your site is now functional on the secondary domain with all latest data.
