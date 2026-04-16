#!/bin/bash

# =============================================================================
# WORDPRESS BACKUP SCRIPT (Files + Database)
# Strategy: Cleanup Google Drive FIRST to free up quota, then upload.
# =============================================================================

# --- CONFIGURATION ---
SITE_NAME="pvamarkets.com"
SOURCE_DIR="/var/www/pvamarkets.com"
BACKUP_DIR="$HOME/backups" 
DB_NAME="database_name"
DB_USER="db_user"
DB_PASS="db_pass"

REMOTE_NAME="google_drive" 
REMOTE_FOLDER="PVA_Backups"

LOCAL_RETENTION=2       # Days to keep on VPS
REMOTE_RETENTION="5d"   # Days to keep on Google Drive (Strict 5-day limit)

# Timestamping
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
FILE_NAME="${SITE_NAME}_${TIMESTAMP}.zip"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

echo "[$TIMESTAMP] Starting quota-optimized backup process..."

# --- STEP 1: REMOTE CLEANUP FIRST ---
# We delete the oldest backup (Day 5) BEFORE we start the new one to free up space.
echo "Step 1: Freeing up Google Drive quota (Deleting backups older than $REMOTE_RETENTION)..."
rclone delete "$REMOTE_NAME:$REMOTE_FOLDER" --min-age "$REMOTE_RETENTION"

# --- STEP 2: DATABASE DUMP ---
echo "Step 2: Dumping database ($DB_NAME)..."
nice -n 19 mysqldump -u "$DB_USER" -p"$DB_PASS" --single-transaction "$DB_NAME" > "$BACKUP_DIR/db.sql"

if [ $? -ne 0 ]; then
    echo "Error: Database dump failed!"
    exit 1
fi

# --- STEP 3: COMPRESSION ---
echo "Step 3: Compressing files..."
nice -n 19 ionice -c 3 zip -r "$BACKUP_DIR/$FILE_NAME" "$SOURCE_DIR" "$BACKUP_DIR/db.sql" > /dev/null
rm "$BACKUP_DIR/db.sql"

# --- STEP 4: UPLOAD TO CLOUD ---
echo "Step 4: Uploading to Google Drive (Quota should be free now)..."
rclone copy "$BACKUP_DIR/$FILE_NAME" "$REMOTE_NAME:$REMOTE_FOLDER"

if [ $? -eq 0 ]; then
    echo "Step 5: Cloud upload successful."
else
    echo "CRITICAL ERROR: Cloud upload failed even after cleanup. Your Drive might be full of other files."
fi

# --- STEP 5: LOCAL CLEANUP ---
echo "Step 6: Cleaning up local backups older than $LOCAL_RETENTION days..."
find "$BACKUP_DIR" -type f -name "${SITE_NAME}_*.zip" -mtime +$LOCAL_RETENTION -exec rm {} \;

echo "[$TIMESTAMP] Backup process finished."