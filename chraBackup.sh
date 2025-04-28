#!/bin/bash
# mariadb_backup.sh

# Load config
source /usr/local/etc/mariadb_backup/backup.conf

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Dates
TODAY=$(date +"%Y-%m-%d")
WEEKDAY=$(date +%u)  # 5 = Friday

# Host and IP info
HOSTNAME_SHORT=$(hostname)
SERVER_IP=$(hostname -I | awk '{print $1}')
IP_LAST_TWO=$(echo "$SERVER_IP" | awk -F. '{print $(NF-1)"."$NF}')

# Determine backup set
if [ "$WEEKDAY" -eq 5 ]; then
    SET_DATE="$TODAY"
else
    SET_DATE=$(date -d "last Friday" +"%Y-%m-%d")
fi

SET_DIR="$BACKUP_DIR/set-$SET_DATE"
FULL_BACKUP_DIR="$SET_DIR/full-$SET_DATE"
INC_BACKUP_DIR="$SET_DIR/inc-$TODAY"

mkdir -p "$SET_DIR"

do_full_backup() {
    echo -e "${YELLOW}[$(date)] Starting FULL backup...${NC}"
    rm -rf "$FULL_BACKUP_DIR"
    mkdir -p "$FULL_BACKUP_DIR"

    mariabackup --backup --target-dir="$FULL_BACKUP_DIR" --user="$DB_USER" --password="$DB_PASSWORD"
    mariabackup --prepare --target-dir="$FULL_BACKUP_DIR"
    echo -e "${GREEN}[$(date)] Full backup complete.${NC}"

    upload_backup "$FULL_BACKUP_DIR" "set-$SET_DATE/full-$SET_DATE"
}

do_incremental_backup() {
    echo -e "${YELLOW}[$(date)] Starting INCREMENTAL backup...${NC}"
    mkdir -p "$INC_BACKUP_DIR"

    mariabackup --backup --target-dir="$INC_BACKUP_DIR" --incremental-basedir="$FULL_BACKUP_DIR" --user="$DB_USER" --password="$DB_PASSWORD"
    echo -e "${GREEN}[$(date)] Incremental backup complete.${NC}"

    upload_backup "$INC_BACKUP_DIR" "set-$SET_DATE/inc-$TODAY"
}

upload_backup() {
    SOURCE_DIR="$1"
    DEST_SUBPATH="$2"

    if [ "$USE_AZCOPY" -eq 1 ]; then
        echo -e "${YELLOW}Uploading $SOURCE_DIR to Azure blob storage...${NC}"
        $AZCOPY_PATH copy "$SOURCE_DIR" "$CONTAINER_URL/$DEST_SUBPATH" --recursive
    else
        echo -e "${YELLOW}Moving $SOURCE_DIR to local blob mount...${NC}"
        mkdir -p "$LOCAL_BLOB_MOUNT/$(dirname "$DEST_SUBPATH")"
        mv "$SOURCE_DIR" "$LOCAL_BLOB_MOUNT/$DEST_SUBPATH"
    fi
}

cleanup_old_backups() {
    echo -e "${YELLOW}[$(date)] Cleaning up old local backups older than $RETENTION_DAYS days...${NC}"
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "set-*" -mtime +$RETENTION_DAYS | while read -r olddir; do
        echo -e "${RED}Deleting old backup set: $olddir${NC}"
        rm -rf "$olddir"
    done
    echo -e "${GREEN}[$(date)] Local cleanup complete.${NC}"
}

# Main
if [ "$WEEKDAY" -eq 5 ]; then
    do_full_backup
else
    do_incremental_backup
fi

cleanup_old_backups

# Capture backup process exit status
EXIT_CODE=$?

# Determine backup type
if [ "$WEEKDAY" -eq 5 ]; then
    BACKUP_TYPE="Full Backup"
else
    BACKUP_TYPE="Incremental Backup"
fi

# Fancy email body
EMAIL_BODY=$(cat <<EOF
MariaDB Backup Report
======================

Server: $HOSTNAME_SHORT (IP: $IP_LAST_TWO)
Backup Type: $BACKUP_TYPE
Date: $(date +"%Y-%m-%d %H:%M:%S")

EOF
)

# Compose and send email
if [ "$EXIT_CODE" -eq 0 ]; then
    EMAIL_BODY+="
Backup Result: SUCCESS

Local Backup Path: $SET_DIR
Upload Method: $(if [ "$USE_AZCOPY" -eq 1 ]; then echo "Azure Blob (azcopy)"; else echo "Local Move (mv)"; fi)
Retention Cleanup: Completed
"
    echo "$EMAIL_BODY" | mail -s "✅ MariaDB Backup Successful [$BACKUP_TYPE]" "$NOTIFY_EMAIL"
else
    EMAIL_BODY+="
Backup Result: FAILURE

Error detected during backup. Check /var/log/mariadb_backup.log for details.
"
    echo "$EMAIL_BODY" | mail -s "❌ MariaDB Backup FAILED [$BACKUP_TYPE]" "$NOTIFY_EMAIL"
fi
