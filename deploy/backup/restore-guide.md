# Cafe-Grader Restoration Guide

This guide provides step-by-step instructions for restoring Cafe-Grader's Web/DB server and worker nodes using backups pulled via `pull-backup.sh`.

---

## 1. Point-in-Time Alignment (Selecting Backups)

Because databases are backed up hourly (`SCOPE=db`) and application assets (`storage/`, `config/`) are backed up daily (`SCOPE=full`), you must pair the target database snapshot with the latest files archive taken **prior to or at the same time** as the database backup.

The following backup files are available:

**Database Backups (`db_*.sql.gz`):**
- `db_2026-06-22_160002.sql.gz`
- `db_2026-06-22_170002.sql.gz`
- `db_2026-06-26_140002.sql.gz`
- `db_2026-06-26_150002.sql.gz`
- `db_2026-06-30_120001.sql.gz`
- `db_2026-06-30_130002.sql.gz`

**Files Backups (`files_*.tar.gz`):**
- `files_2026-06-20_013002.tar.gz`
- `files_2026-06-21_013002.tar.gz`

### Recommended Restoration Pairs

Choose one of the recovery points below based on your target state:

| Target Recovery Date | Database File (`db_*.sql.gz`) | Asset Files (`files_*.tar.gz`) | Note |
| :--- | :--- | :--- | :--- |
| **June 22, 2026 (16:00)** | `db_2026-06-22_160002.sql.gz` | `files_2026-06-21_013002.tar.gz` | Latest files backup prior to target DB state |
| **June 22, 2026 (17:00)** | `db_2026-06-22_170002.sql.gz` | `files_2026-06-21_013002.tar.gz` | Latest files backup prior to target DB state |
| **June 26, 2026 (14:00)** | `db_2026-06-26_140002.sql.gz` | `files_2026-06-21_013002.tar.gz` | *Warning: Files uploaded after June 21 will be missing.* |
| **June 26, 2026 (15:00)** | `db_2026-06-26_150002.sql.gz` | `files_2026-06-21_013002.tar.gz` | *Warning: Files uploaded after June 21 will be missing.* |
| **June 30, 2026 (12:00)** | `db_2026-06-30_120001.sql.gz` | `files_2026-06-21_013002.tar.gz` | *Warning: Files uploaded after June 21 will be missing.* |
| **June 30, 2026 (13:00)** | `db_2026-06-30_130002.sql.gz` | `files_2026-06-21_013002.tar.gz` | *Warning: Files uploaded after June 21 will be missing.* |

---

## 2. Windows Client Setup (Command Prompt / PowerShell)

If you are executing restoration commands from a Windows machine (using standard `cmd.exe` or PowerShell), you must secure your SSH private key first. Windows OpenSSH will refuse to connect if the key file permissions are too open.

### Restricting Key Permissions via Windows Command Prompt (CMD)
Run the following commands in `cmd.exe` to reset inheritance and restrict access solely to your user account (replacing `chmod 600` on Linux):
```cmd
:: 1. Reset permissions
icacls "%USERPROFILE%\.cafe-backup.key" /reset

:: 2. Disable permission inheritance
icacls "%USERPROFILE%\.cafe-backup.key" /inheritance:r

:: 3. Grant read-only access to the current Windows user
icacls "%USERPROFILE%\.cafe-backup.key" /grant:r "%USERNAME%":"(R)"
```

### Path Resolution differences
- **Windows Command Prompt (`cmd.exe`)**: Does not support `~`. Use `%USERPROFILE%\.cafe-backup.key` instead.
- **PowerShell**: Supports `~/.cafe-backup.key` or `$HOME\.cafe-backup.key`.

---

## 3. Web & Database Server Restore

Follow these steps to restore the database and Rails application assets (`config/` and `storage/`) on the Web/DB server.

### Prerequisites
- SSH root access key (e.g., `%USERPROFILE%\.cafe-backup.key` on Windows CMD, or `~/.cafe-backup.key` on Linux/PowerShell).
- Target Web/DB Server IP address.
- Standard app installation directory: `/home/grader/cafe_grader/web`.

### Step 1: Copy Backup Files to the Server
Run this from your own local machine (control box):
```bash
# Example using June 22 (17:00) state
# Note: On Windows CMD, replace ~/.cafe-backup.key with %USERPROFILE%\.cafe-backup.key
scp -i ~/.cafe-backup.key db_2026-06-22_170002.sql.gz root@<web-db-ip>:/tmp/
scp -i ~/.cafe-backup.key files_2026-06-21_013002.tar.gz root@<web-db-ip>:/tmp/
```

### Step 2: Stop Services Remotely
Run this from your own local machine (control box):
```bash
ssh -i ~/.cafe-backup.key root@<web-db-ip> "systemctl stop apache2 && systemctl stop solid_queue.service"
```

### Step 3: Restore the Databases Remotely
Run this from your own local machine (control box):
```bash
# Using root MySQL credentials on the remote server:
ssh -i ~/.cafe-backup.key root@<web-db-ip> "zcat /tmp/db_2026-06-22_170002.sql.gz | mysql -u root"

# Alternatively, using application database credentials:
# ssh -i ~/.cafe-backup.key root@<web-db-ip> "zcat /tmp/db_2026-06-22_170002.sql.gz | mysql -u grader_user -pgrader_pass"
```

### Step 4: Restore Configs and Active Storage Files Remotely
Run this from your own local machine (control box) to extract the configurations and files directly into the Rails application folder:
```bash
ssh -i ~/.cafe-backup.key root@<web-db-ip> "tar -C /home/grader/cafe_grader/web -xzf /tmp/files_2026-06-21_013002.tar.gz && chown -R grader:grader /home/grader/cafe_grader/web/config /home/grader/cafe_grader/web/storage"
```

### Step 5: Start Services Remotely and Verify
Run this from your own local machine (control box):
```bash
ssh -i ~/.cafe-backup.key root@<web-db-ip> "systemctl start solid_queue.service && systemctl start apache2"
```
Verify that you can log in, view problem descriptions (retrieved from `storage/`), and access submission history (retrieved from the database).

---

## 4. Worker Node Restore

Grader worker nodes are stateless, except for their unique machine identity/key (`config/worker.yml`) and compiler scripts/configurations (`judge/` directory).

### Prerequisites
- Backed-up files for the specific worker node:
  - `worker_<timestamp>.tar.gz` (contains `config/worker.yml`)
  - `judge_<timestamp>.tar.gz` (contains the custom `judge` scripts directory)
- Target Worker Server IP address.
- Standard worker directories:
  - App root: `/home/grader/cafe_grader/web`
  - Judge root: `/home/grader/cafe_grader/judge`

### Step 1: Copy Worker Backup Files to the Worker Node
Run this from your own local machine (control box):
```bash
# Note: On Windows CMD, replace ~/.cafe-backup.key with %USERPROFILE%\.cafe-backup.key
scp -i ~/.cafe-backup.key worker_2026-06-21_013002.tar.gz root@<worker-ip>:/tmp/
scp -i ~/.cafe-backup.key judge_2026-06-21_013002.tar.gz root@<worker-ip>:/tmp/
```

### Step 2: Stop Worker Services Remotely
Run this from your own local machine (control box):
```bash
ssh -i ~/.cafe-backup.key root@<worker-ip> "systemctl stop cafe_grader_workers.service"
```

### Step 3: Extract Identity & Judge Scripts Remotely
Run this from your own local machine (control box):
```bash
ssh -i ~/.cafe-backup.key root@<worker-ip> "tar -C /home/grader/cafe_grader/web -xzf /tmp/worker_2026-06-21_013002.tar.gz && tar -C /home/grader/cafe_grader -xzf /tmp/judge_2026-06-21_013002.tar.gz && chown -R grader:grader /home/grader/cafe_grader/web/config/worker.yml /home/grader/cafe_grader/judge"
```

### Step 4: Restart Worker Services and Monitor Logs Remotely
Run this from your own local machine (control box):
```bash
ssh -i ~/.cafe-backup.key root@<worker-ip> "systemctl start cafe_grader_workers.service"

# Monitor startup logs in real-time
ssh -i ~/.cafe-backup.key root@<worker-ip> "journalctl -u cafe_grader_workers.service -n 50 -f"
```

---

## 5. Troubleshooting Post-Restore

- **Error: `ActiveSupport::MessageEncryptor::InvalidMessage`**
  - **Reason**: The `master.key` file in `config/master.key` does not match the encrypted credentials file `config/credentials.yml.enc`.
  - **Fix**: Ensure you restored both files from the same `files_*.tar.gz` backup. Do not regenerate the `master.key` if you are attempting to decrypt pre-existing production credentials.
- **Error: Missing Statement Attachments or Images in Web UI**
  - **Reason**: A point-in-time database backup was restored, but the associated `files_*.tar.gz` archive does not contain the corresponding uploads in `storage/` because they were created after the files backup occurred.
  - **Fix**: Align the restoration with a newer `files_*.tar.gz` backup if available.
- **Worker Heartbeat / Grading Not Running**
  - **Reason**: `worker_id` or `server_key` mismatch in `config/worker.yml`, or database connection issue.
  - **Fix**: Verify `/home/grader/cafe_grader/web/config/database.yml` on the worker has the correct remote database credentials and that port 3306 is open from worker to Web/DB server. Verify worker configuration with:
    ```bash
    cat /home/grader/cafe_grader/web/config/worker.yml
    ```
