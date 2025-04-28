# MariaDB Backup & Restore Suite

---

## Files Included

- `backup.conf`
- `mariadb_backup.sh`
- `mariadb_restore.sh`
- `README.txt`
- `example-cronjob.txt`
- `disaster_wizard.sh`

---

## Setup Instructions

### 1. Install Required Tools

- `mariabackup` (from MariaDB tools)
- `azcopy` (for Azure Blob Storage uploads)
- `mailutils` or equivalent mail command-line tool (for email notifications)

### 2. File Placement

| File | Destination |
|:-----|:------------|
| `backup.conf` | `/usr/local/etc/mariadb_backup/backup.conf` |
| `mariadb_backup.sh` | `/usr/local/bin/mariadb_backup.sh` |
| `mariadb_restore.sh` | `/usr/local/bin/mariadb_restore.sh` |
| `disaster_wizard.sh` | `/usr/local/bin/disaster_wizard.sh` |

Ensure directories exist:
```bash
mkdir -p /usr/local/etc/mariadb_backup
mkdir -p /usr/local/bin
```

### 3. Permissions

```bash
chmod 600 /usr/local/etc/mariadb_backup/backup.conf
chmod 700 /usr/local/bin/mariadb_backup.sh
chmod 700 /usr/local/bin/mariadb_restore.sh
chmod 700 /usr/local/bin/disaster_wizard.sh
```

### 4. Configure `backup.conf`

Edit `/usr/local/etc/mariadb_backup/backup.conf` to match your environment:

- Backup storage paths
- MariaDB user/password
- Azure storage URL
- Binlog directory
- Datadir locations
- Target email address for notifications (`NOTIFY_EMAIL`)
- Upload method selection:
  - `USE_AZCOPY=1` to upload using azcopy to Azure
  - `USE_AZCOPY=0` to move backups locally to attached blob storage via `mv`
  - If using local move, set `LOCAL_BLOB_MOUNT="/mnt/blob-storage"`

Example:
```bash
NOTIFY_EMAIL="you@example.com"
USE_AZCOPY=1
LOCAL_BLOB_MOUNT="/mnt/blob-storage"
```

### 5. Setup Cron Job

Add this line to your crontab:
```bash
0 0 * * * /usr/local/bin/mariadb_backup.sh >> /var/log/mariadb_backup.log 2>&1
```

---

## MariaDB Restore Script Enhancement

- `mariadb_restore.sh` now includes a MariaDB service check before binlog replay.
- If MariaDB is not running during binlog replay, the script will:
  - Prompt the user to start MariaDB.
  - Optionally suggest starting in safe LOCAL-ONLY (skip-networking) mode for safety.

---

## Disaster Wizard Script

Path: `/usr/local/bin/disaster_wizard.sh`

Quick Usage Example:
```bash
sudo /usr/local/bin/disaster_wizard.sh
```

This command safely walks you through full database recovery, backup selection, optional binlog replay, and full restart.

Automates:
- Stopping MariaDB
- Running interactive restore
- Optionally starting MariaDB in safe local-only mode for binlog replay
- Full recovery and verification

---

## Fast Recovery Flowchart

```
+------------------------+
|    Disaster Happens    |
+-----------+------------+
            |
            v
+------------------------+
|  Stop MariaDB Service   |
|  (systemctl stop mariadb) |
+-----------+------------+
            |
            v
+------------------------+
|  Run Disaster Wizard    |
| (disaster_wizard.sh)    |
+-----------+------------+
            |
            v
+------------------------+
|  Select Backup Set      |
|  (Full + Incremental)   |
+-----------+------------+
            |
            v
+------------------------+
|  Restore Data Directory |
| (Auto handles prepare)  |
+-----------+------------+
            |
            v
+-------------------------------+
|  Start MariaDB in Safe Mode?  |
| (optional for binlog replay)  |
+-----------+-------------------+
            |
            v
+-------------------------------+
|  Replay Binlogs if Needed     |
+-----------+-------------------+
            |
            v
+------------------------+
|  Restart MariaDB Normally |
+-----------+------------+
            |
            v
+------------------------+
|  Recovery Complete      |
+------------------------+
```

---

## Recovery Timing Tips

| Database Size | Estimated Restore Time | Notes |
|:--------------|:-----------------------|:------|
| 5GB           | ~5-10 minutes            | Very quick; mainly disk speed dependent |
| 20GB          | ~15-25 minutes           | Slightly longer; incremental restores help |
| 100GB         | ~1-2 hours               | Ensure disk I/O is healthy |
| 1TB+          | 6+ hours (typical range)  | **Plan for overnight maintenance window**; consider restoring full + applying latest incremental and binlogs for efficiency |

### Factors That Affect Restore Speed

- Disk speed (SSD vs HDD)
- CPU performance (for `mariabackup --prepare`)
- IOPS (Input/Output per second on storage)
- Binlog size and number of transactions to replay
- Network speed (if pulling from remote blob storage)

**Tip:** For large 1TB+ databases, always restore the latest full backup first, then the latest incremental, and only apply binlogs if absolutely needed.

---

## Dry-Run Checklist

### Backup Dry-Run

1. Ensure all scripts and config files are placed correctly.
2. Set `backup.conf` to a test Azure Blob or set to local move temporarily.
3. Manually trigger a full backup:

```bash
/usr/local/bin/mariadb_backup.sh
```

4. Verify:
   - Local backup directory created under `/var/backups/mariadb/`
   - Backup completes without errors
   - Azure upload OR local move happens depending on config
   - Email notification is received

### Restore Dry-Run

1. Pick a small test database or non-production MariaDB server.
2. Run the restore script:

```bash
/usr/local/bin/mariadb_restore.sh
```

3. Follow prompts:
   - Select latest backup set
   - Select latest incremental or full backup
   - Confirm and proceed
4. After restore:
   - MariaDB service should be running
   - Database should contain expected test data

5. Optionally test binlog replay:
   - Choose a restore time during binlog prompt
   - Confirm replay works without errors

### Post-Dry-Run

- Review `/var/log/mariadb_backup.log`
- Check restored database state
- Confirm that retention cleanup (deletion of old backups) works after 28 days (or adjust for quick test)

---

## Disaster Recovery Cheat Sheet

### Immediate Steps After Data Loss

1. **Stop MariaDB Service Immediately**
```bash
systemctl stop mariadb
```

2. **Restore the latest full + incrementals**
```bash
/usr/local/bin/mariadb_restore.sh
```
- Select backup set
- Select latest incremental (or just full if no incrementals)
- Prepare backups (mariabackup prepares backups without MariaDB running)
- Datadir is replaced automatically

3. **Optional: Start MariaDB in Local-Only Mode for Binlog Replay**
```bash
# (Temporary) Edit /etc/mysql/my.cnf and add:
[mysqld]
skip-networking
```
Start MariaDB:
```bash
systemctl start mariadb
```

4. **Normal Start of MariaDB Service (after binlog replay if needed)**
```bash
# Remove skip-networking from my.cnf if added
systemctl restart mariadb
```

5. **Verify Database and Logs**
- Confirm restored data
- Review `/var/log/mariadb_backup.log` for any issues

---

## Release Notes — Version 1.0

- Initial public release
- Full backup & incremental system using MariaBackup
- Azure Blob Storage upload support or local attached blob move
- Local retention policies (default 28 days)
- Colorized output for clarity
- Fancy email notifications per backup run
- Disaster recovery wizard with guided recovery
- Full binlog replay supported with safe-mode startup
- Restore scripts safely check MariaDB service state
- Designed for small to multi-terabyte database recovery

---

