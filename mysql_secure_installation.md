# MySQL Installation and Configuration on VPS

This guide covers the installation of MySQL server, securing the installation, managing users, and enabling remote access.

## 1. Installation

To install MySQL server on Ubuntu/Debian:

```bash
sudo apt update
sudo apt install mysql-server -y
```

After installation, verify that the service is running:

```bash
sudo systemctl status mysql
```

## 2. Secure Installation & Set Root Password

Run the security script to remove insecure defaults:

```bash
sudo mysql_secure_installation
```

### Setting the Root Password
If you need to set or change the root password manually:

1. Log in to MySQL:
   ```bash
   sudo mysql
   ```
2. Run the following command (replace `your_password` with a strong password):
   ```sql
   ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'your_password';
   FLUSH PRIVILEGES;
   ```

## 3. Create a User with All Privileges

It is recommended to create a dedicated user for your application instead of using `root`.

1. Log in to MySQL:
   ```bash
   sudo mysql -u root -p
   ```
2. Create the user and grant privileges:
   ```sql
   CREATE USER 'myuser'@'localhost' IDENTIFIED BY 'mypassword';
   GRANT ALL PRIVILEGES ON *.* TO 'myuser'@'localhost' WITH GRANT OPTION;
   FLUSH PRIVILEGES;
   ```

## 4. Create a Remote Login User

### Step A: Create the Remote User
To allow a user to connect from any IP address (`%`):

```sql
CREATE USER 'remote_user'@'%' IDENTIFIED BY 'remote_password';
GRANT ALL PRIVILEGES ON *.* TO 'remote_user'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

### Step B: Update MySQL Configuration
By default, MySQL only listens on `localhost`. To allow remote connections:

1. Edit the configuration file:
   ```bash
   sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
   ```
2. Find the line `bind-address = 127.0.0.1` and change it to:
   ```ini
   bind-address = 0.0.0.0
   ```
3. Restart MySQL to apply changes:
   ```bash
   sudo systemctl restart mysql
   ```

> [!CAUTION]
> Opening MySQL to `0.0.0.0` can be a security risk. Ensure you use a firewall (like `ufw`) to restrict access to specific IP addresses on port 3306.

## 5. MySQL Operational Commands

| Action | Command |
| :--- | :--- |
| **Start MySQL** | `sudo systemctl start mysql` |
| **Stop MySQL** | `sudo systemctl stop mysql` |
| **Restart MySQL** | `sudo systemctl restart mysql` |
| **Check Status** | `sudo systemctl status mysql` |
| **Login (Interactive)** | `mysql -u username -p` |
| **Export Database** | `mysqldump -u user -p dbname > backup.sql` |
| **Import Database** | `mysql -u user -p dbname < backup.sql` |
