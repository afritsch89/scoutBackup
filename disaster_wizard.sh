#!/bin/bash
# disaster_wizard.sh - Emergency guided recovery tool

# Load config
source /usr/local/etc/mariadb_backup/backup.conf

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${YELLOW}==== MariaDB Disaster Recovery Wizard ====${NC}"

# Step 1: Stop MariaDB
echo -e "${YELLOW}[Step 1] Stopping MariaDB service...${NC}"
systemctl stop "$MARIADB_SERVICE"
if [ $? -eq 0 ]; then
    echo -e "${GREEN}MariaDB service stopped.${NC}"
else
    echo -e "${RED}Warning: Could not stop MariaDB. Check manually.${NC}"
fi

# Step 2: Restore backup
echo -e "${YELLOW}[Step 2] Starting interactive backup restore...${NC}"
/usr/local/bin/mariadb_restore.sh

# Step 3: Optional safe startup for binlog replay
read -rp "Would you like to bring up MariaDB in safe LOCAL-ONLY mode for binlog replay? (yes/no): " SAFE_MODE
if [[ "$SAFE_MODE" == "yes" ]]; then
    echo -e "${YELLOW}Temporarily setting skip-networking in my.cnf...${NC}"

    # Backup original my.cnf
    cp /etc/my.cnf /etc/my.cnf.bak_$(date +%Y%m%d%H%M%S)

    # Insert skip-networking if not already present
    grep -q "skip-networking" /etc/my.cnf || sed -i '/^\[mysqld\]/a skip-networking' /etc/my.cnf

    echo -e "${YELLOW}Starting MariaDB service with networking disabled...${NC}"
    systemctl start "$MARIADB_SERVICE"
    sleep 5
    echo -e "${GREEN}MariaDB started safely. Proceed with binlog replay.${NC}"
else
    echo -e "${YELLOW}Skipping safe-mode startup. Proceed carefully.${NC}"
fi

# Step 4: Restore normal configuration
read -rp "When binlog replay is complete, restore normal networking and restart MariaDB? (yes/no): " RESTORE_NORMAL
if [[ "$RESTORE_NORMAL" == "yes" ]]; then
    echo -e "${YELLOW}Removing skip-networking from my.cnf...${NC}"
    sed -i '/skip-networking/d' /etc/my.cnf

    echo -e "${YELLOW}Restarting MariaDB normally...${NC}"
    systemctl restart "$MARIADB_SERVICE"
    echo -e "${GREEN}MariaDB restarted without skip-networking.${NC}"
else
    echo -e "${YELLOW}Leaving MariaDB running in safe mode. You must manually restore /etc/my.cnf when ready.${NC}"
fi

# Step 5: Done
echo -e "${GREEN}==== Disaster Recovery Wizard Completed ====${NC}"
