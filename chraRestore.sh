#!/bin/bash
# mariadb_restore.sh

# Load config
source /usr/local/etc/mariadb_backup/backup.conf

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Validate HH:MM:SS time input
validate_time_format() {
    if [[ ! "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]]; then
        echo -e "${RED}Invalid time format. Please use HH:MM:SS (24-hour clock).${NC}"
        exit 1
    fi
}

choose_option() {
    local prompt="$1"
    shift
    local options=("$@")
    PS3="$prompt: "
    select opt in "${options[@]}"; do
        if [[ -n "$opt" ]]; then
            echo "$opt"
            break
        fi
    done
}

# Step 1: Select backup set
echo -e "${YELLOW}Available backup sets:${NC}"
SETS=($(ls "$BACKUP_DIR" | grep "^set-" | sort))
SELECTED_SET=$(choose_option "Select a backup set" "${SETS[@]}")

# Step 2: Select restore point (full or incremental)
SET_PATH="$BACKUP_DIR/$SELECTED_SET"
echo -e "${YELLOW}Available restore points:${NC}"
RESTORE_POINTS=($(find "$SET_PATH" -mindepth 1 -maxdepth 1 -type d | sort))
SELECTED_POINT=$(choose_option "Select a restore point (full or incremental)" "${RESTORE_POINTS[@]}")

# Extract restore date
RESTORE_DATE=$(basename "$SELECTED_POINT" | sed 's/.*-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)/\1/')

# Step 3: Confirm
echo -e "${YELLOW}You selected restore point: $SELECTED_POINT (Restore Date: $RESTORE_DATE)${NC}"
read -rp "Type 'yes' to proceed with restore: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Aborting.${NC}"
    exit 1
fi

# Step 4: Prepare backup
echo -e "${YELLOW}Preparing backup files...${NC}"
rm -rf "$TMP_RESTORE_DIR"
mkdir -p "$TMP_RESTORE_DIR"

# Copy full backup first
BASE_FULL=$(find "$SET_PATH" -name "full-*" -type d | head -n 1)
cp -a "$BASE_FULL/." "$TMP_RESTORE_DIR/"

# Prepare full backup before applying incrementals
echo -e "${YELLOW}Preparing full backup before applying incrementals...${NC}"
mariabackup --prepare --target-dir="$TMP_RESTORE_DIR"

# Apply incremental backups in order up to selected
for inc in $(find "$SET_PATH" -name "inc-*" -type d | sort); do
    if [[ "$inc" > "$SELECTED_POINT" ]]; then
        break
    fi
    echo -e "${YELLOW}Applying incremental: $inc${NC}"
    mariabackup --prepare --target-dir="$TMP_RESTORE_DIR" --incremental-dir="$inc"
done

# Final prepare
echo -e "${YELLOW}Final prepare of restore directory...${NC}"
mariabackup --prepare --target-dir="$TMP_RESTORE_DIR"

# Step 5: Replace datadir
echo -e "${YELLOW}Stopping MariaDB service...${NC}"
systemctl stop "$MARIADB_SERVICE"

TIMESTAMP=$(date +%Y%m%d%H%M%S)
echo -e "${YELLOW}Backing up existing datadir to $MARIADB_DATADIR_BACKUP_BASE/datadir_backup_$TIMESTAMP...${NC}"
mkdir -p "$MARIADB_DATADIR_BACKUP_BASE"
mv "$MARIADB_DATADIR" "$MARIADB_DATADIR_BACKUP_BASE/datadir_backup_$TIMESTAMP"

echo -e "${YELLOW}Restoring new datadir...${NC}"
cp -a "$TMP_RESTORE_DIR" "$MARIADB_DATADIR"

echo -e "${YELLOW}Fixing permissions...${NC}"
chown -R mysql:mysql "$MARIADB_DATADIR"

echo -e "${YELLOW}Starting MariaDB service...${NC}"
systemctl start "$MARIADB_SERVICE"

echo -e "${GREEN}Restore complete!${NC}"

# Step 6: Optional binlog replay
read -rp "Would you like to apply binlogs to a specific time on $RESTORE_DATE? (yes/no): " APPLY_BINLOGS
if [ "$APPLY_BINLOGS" == "yes" ]; then
    read -rp "Enter target restore TIME (HH:MM:SS): " TARGET_TIME

    validate_time_format "$TARGET_TIME"
    TARGET_DATETIME="$RESTORE_DATE $TARGET_TIME"

    # Check if MariaDB is running
    echo -e "${YELLOW}Checking if MariaDB is running...${NC}"
    if ! systemctl is-active --quiet "$MARIADB_SERVICE"; then
        echo -e "${RED}MariaDB is NOT running!${NC}"
        read -rp "Would you like to start MariaDB in safe LOCAL-ONLY (skip-networking) mode first? (yes/no): " START_SAFE
        if [ "$START_SAFE" == "yes" ]; then
            # Backup my.cnf and inject skip-networking if needed
            cp /etc/my.cnf /etc/my.cnf.bak_$(date +%Y%m%d%H%M%S)
            grep -q "skip-networking" /etc/my.cnf || sed -i '/^\[mysqld\]/a skip-networking' /etc/my.cnf
        fi
        echo -e "${YELLOW}Starting MariaDB service...${NC}"
        systemctl start "$MARIADB_SERVICE"
        sleep 5
    fi

    echo -e "${YELLOW}Applying binlogs up to $TARGET_DATETIME...${NC}"

    for binlog in $(ls "$BINLOG_DIR" | grep -E '^mysql-bin.[0-9]+$' | sort); do
        FULL_BINLOG_PATH="$BINLOG_DIR/$binlog"
        echo -e "${YELLOW}Processing binlog: $binlog${NC}"
        mysqlbinlog --stop-datetime="$TARGET_DATETIME" "$FULL_BINLOG_PATH" | mysql -u"$DB_USER" -p"$DB_PASSWORD"

        LAST_EVENT_TIME=$(mysqlbinlog --verbose "$FULL_BINLOG_PATH" | grep 'SET TIMESTAMP=' | tail -n 1 | awk -F= '{print $2}' | awk '{print $1}')
        if [ -n "$LAST_EVENT_TIME" ]; then
            LAST_EVENT_DATE=$(date -d "@$LAST_EVENT_TIME" +"%Y-%m-%d %H:%M:%S")
            if [[ "$LAST_EVENT_DATE" > "$TARGET_DATETIME" ]]; then
                echo -e "${GREEN}Reached target time. Stopping binlog replay.${NC}"
                break
            fi
        fi
    done

    # Cleanup skip-networking if it was set
    if grep -q "skip-networking" /etc/my.cnf; then
        echo -e "${YELLOW}Removing skip-networking from my.cnf...${NC}"
        sed -i '/skip-networking/d' /etc/my.cnf
        echo -e "${YELLOW}Restarting MariaDB normally...${NC}"
        systemctl restart "$MARIADB_SERVICE"
    fi

    echo -e "${GREEN}Binlog replay completed up to $TARGET_DATETIME.${NC}"
else
    echo -e "${YELLOW}Skipping binlog application.${NC}"
fi
