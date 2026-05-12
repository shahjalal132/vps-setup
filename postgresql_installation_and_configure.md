# PostgreSQL installation and remote access (multi-server Laravel)

To run PostgreSQL for a multi-server Laravel setup, configure **remote connections** so **Server 3** can reach the database on **Server 2** (database + app server).

All steps below are performed on **Server 2** unless noted.

---

## Step 1: Install PostgreSQL

Update the package index and install PostgreSQL:

```bash
sudo apt update
sudo apt install postgresql postgresql-contrib -y
```

---

## Step 2: Create database and user

Switch to the `postgres` system user and open `psql`:

```bash
sudo -i -u postgres
psql
```

In the `psql` prompt, run:

```sql
-- Create the database
CREATE DATABASE trading_chart_db;

-- Create a user with a strong password (replace in production)
CREATE USER trading_user WITH PASSWORD 'YourStrongPasswordHere';

-- Grant database privileges
GRANT ALL PRIVILEGES ON DATABASE trading_chart_db TO trading_user;

-- Recommended: schema permissions for Laravel migrations
\c trading_chart_db
GRANT ALL ON SCHEMA public TO trading_user;

\q
```

Then leave the `postgres` shell:

```bash
exit
```

---

## Step 3: Configure remote access

By default PostgreSQL listens only on `localhost`. You must listen on the appropriate interfaces and allow clients in `pg_hba.conf`.

### 3.1 `postgresql.conf`

Replace `16` with your installed major version (`14`, `15`, `16`, etc.):

```bash
sudo nano /etc/postgresql/16/main/postgresql.conf
```

Find the line:

```text
#listen_addresses = 'localhost'
```

Change it to:

```text
listen_addresses = '*'
```

Save and exit.

### 3.2 `pg_hba.conf` (client authentication)

```bash
sudo nano /etc/postgresql/16/main/pg_hba.conf
```

At the **end** of the file, add a rule for **Server 3**. Prefer **private** IP on a VPC; use public IP only if required:

```text
# Allow Server 3 to connect (replace with Server 3's IP)
host    all    all    84.xxx.xxx.xxx/32    md5
```

Notes:

- Replace `84.xxx.xxx.xxx` with Server 3’s actual IP.
- On PostgreSQL 13+ with default password encryption, if connections fail with “password authentication failed”, try `scram-sha-256` instead of `md5` in this line (or set `password_encryption` / re-create the role to match your chosen method).
- Allowing `0.0.0.0/0` is possible but **not recommended**; it exposes the port to the whole internet unless tightly firewalled.

---

## Step 4: Firewall and service restart

Allow **only** Server 3 to reach TCP `5432` (adjust IP):

```bash
sudo ufw allow from 84.xxx.xxx.xxx to any port 5432 proto tcp
sudo ufw reload
```

Restart PostgreSQL so `listen_addresses` and `pg_hba.conf` take effect:

```bash
sudo systemctl restart postgresql
```

---

## Step 5: Laravel `.env` on both servers

Use the same database name, user, and password; only `DB_HOST` differs.

### Server 2 (local connection)

```env
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=trading_chart_db
DB_USERNAME=trading_user
DB_PASSWORD=YourStrongPasswordHere
```

### Server 3 (remote connection)

Set `DB_HOST` to an address **Server 3** can route to: Server 2’s private IP (same network/VPC) or, if needed, its public IP.

```env
DB_CONNECTION=pgsql
DB_HOST=YOUR_SERVER_2_IP
DB_PORT=5432
DB_DATABASE=trading_chart_db
DB_USERNAME=trading_user
DB_PASSWORD=YourStrongPasswordHere
```

Replace `YOUR_SERVER_2_IP` with the correct IP for your topology.

---

## Step 6: Verify from Server 3

On **Server 3**, confirm Laravel can reach the database:

```bash
php artisan migrate:status
```

If migrations list without connection errors, the app tier on Server 3 is talking to PostgreSQL on Server 2.

---

## PHP PostgreSQL extension (Ubuntu, PHP 8.4)

Install the PHP PostgreSQL driver on **each** app server that runs Laravel (Server 2 and Server 3 if both run PHP):

```bash
sudo apt install php8.4-pgsql -y
sudo systemctl restart php8.4-fpm
```

Adjust `php8.4` if you use another PHP version.

---

## Quick checklist

| Item | Server 2 |
|------|----------|
| Packages | `postgresql`, `postgresql-contrib` |
| DB / user | `trading_chart_db`, `trading_user` |
| `listen_addresses` | `'*'` (or specific interfaces) |
| `pg_hba.conf` | Rule for Server 3 IP |
| UFW | Allow `5432` from Server 3 only |
| Laravel `.env` | `DB_HOST=127.0.0.1` |

On **Server 3**: `DB_HOST` = reachable IP of Server 2; same DB credentials; `php8.4-pgsql` installed if using PHP 8.4.
