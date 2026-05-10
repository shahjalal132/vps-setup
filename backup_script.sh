#!/bin/bash

# =============================================================================
# WORDPRESS (OR STATIC SITE) BACKUP — files + MySQL/MariaDB dump → zip → cloud
#
# Flow (quota-friendly for small Google Drive plans):
#   1) Delete old objects on the remote FIRST (frees space before new upload).
#   2) mysqldump the database to a temp SQL file.
#   3) zip document root + SQL, remove the SQL file from disk.
#   4) rclone copy the zip to the configured remote folder.
#   5) Delete local zips older than LOCAL_RETENTION days.
#
# Requires: mysqldump, zip, find, rclone (see rclone_install_and_configure.md).
# Run via cron as a user that can read SOURCE_DIR and run mysqldump (often root
# or a dedicated backup user with DB read rights).
# =============================================================================

# --- CONFIGURATION (replace placeholders with your real values) ---

# Public hostname used only in the backup zip filename (e.g. site1.example.com_2026-01-15_02-30.zip).
SITE_NAME="site1.example.com"

# Filesystem path to back up (WordPress root = directory containing wp-config.php).
SOURCE_DIR="/var/www/site1.example.com"

# Where intermediate SQL and zip files are written (must have enough free disk).
BACKUP_DIR="$HOME/backups"

# Database credentials — dummy values; use your real DB name/user/password.
# Security: prefer ~/.my.cnf with chmod 600, or export DB_PASS from a root-only
# env file sourced before cron runs, instead of keeping passwords in this script.
DB_NAME="site1_wp"
DB_USER="wp_user"
DB_PASS="YourStrongPassword"

# rclone remote name exactly as shown by `rclone listremotes` (trailing colon omitted here).
REMOTE_NAME="google_drive"

# Folder path on the remote (created on first copy if the backend allows).
REMOTE_FOLDER="Site_Backups"

# How long to keep completed .zip files on this machine (days).
LOCAL_RETENTION=3

# Max age of objects on the remote to KEEP; older objects under REMOTE_FOLDER are deleted
# before upload. rclone uses suffix d=days, w=weeks, M=months (see `rclone delete --help`).
REMOTE_RETENTION="5d"

# --- derived names ---

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
FILE_NAME="${SITE_NAME}_${TIMESTAMP}.zip"

mkdir -p "$BACKUP_DIR"

echo "[$TIMESTAMP] Starting quota-optimized backup process..."

# --- STEP 1: remote cleanup first ---
# Deleting old backups on Drive before creating a new large zip avoids "disk full"
# / quota errors mid-upload when the account is near its limit.
echo "Step 1: Freeing up remote quota (deleting backups older than $REMOTE_RETENTION under $REMOTE_FOLDER)..."
rclone delete "$REMOTE_NAME:$REMOTE_FOLDER" --min-age "$REMOTE_RETENTION" --drive-use-trash=false

# --- STEP 2: database dump ---
# --single-transaction: InnoDB consistent snapshot without global read lock (good for live WP).
# nice -n 19: lowest CPU scheduling priority so backup does not starve the web server.
echo "Step 2: Dumping database ($DB_NAME)..."
nice -n 19 mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction "$DB_NAME" > "$BACKUP_DIR/db.sql"

if [ $? -ne 0 ]; then
    echo "Error: Database dump failed!"
    exit 1
fi

# --- STEP 3: compress site + dump ---
# ionice -c 3: "idle" I/O class — further reduces impact on concurrent requests.
# zip includes SOURCE_DIR tree and the flat db.sql; SQL is removed after zip closes.
echo "Step 3: Compressing files..."
nice -n 19 ionice -c 3 zip -r "$BACKUP_DIR/$FILE_NAME" "$SOURCE_DIR" "$BACKUP_DIR/db.sql" > /dev/null
rm -f "$BACKUP_DIR/db.sql"

# --- STEP 4: upload to cloud ---
# rclone copy: adds/updates files on remote; does not mirror-deletes outside what step 1 removed.
echo "Step 4: Uploading to remote (quota was freed in step 1)..."
rclone copy "$BACKUP_DIR/$FILE_NAME" "$REMOTE_NAME:$REMOTE_FOLDER"

if [ $? -eq 0 ]; then
    echo "Step 5: Cloud upload successful."
else
    echo "CRITICAL ERROR: Cloud upload failed. Check remote quota, credentials, and rclone logs."
fi

# --- STEP 5: local retention ---
# Only deletes zips matching this site's prefix so other projects in BACKUP_DIR are untouched.
echo "Step 6: Removing local backups older than $LOCAL_RETENTION days matching ${SITE_NAME}_*.zip ..."
find "$BACKUP_DIR" -type f -name "${SITE_NAME}_*.zip" -mtime +$LOCAL_RETENTION -exec rm -f {} \;

echo "[$TIMESTAMP] Backup process finished."
