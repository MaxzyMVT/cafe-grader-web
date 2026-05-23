# Cafe-Grader Administrator Guide

This guide is for users with the `admin` or `ta` role. It covers managing the platform, users, problems, contests, and system health.

---

## 1. User Management

### Adding Users

- **Individually** — Go to `Admin → User Admin` and click **New User**.
- **Bulk Import (CSV)** — Go to `Admin → User Admin → Create from List`. Paste a user list or upload a CSV file. The system can auto-generate random passwords.
- **Contest-Specific** — Inside a Contest's management page, add users directly to that contest.

### Permissions & Activation

- **Enable / Disable** — Temporarily disable an account without deleting it.
- **Roles** — Assign `admin`, `ta`, or `group_editor` roles.
- **Clear IP** — If a user is locked to a specific IP (Contest Mode), clear their last known IP to allow login from a new machine.

---

## 2. Problem & Dataset Management

Problems are the core coding tasks. Each problem can have multiple **Datasets**, but only one is *Live* (used for scoring).

### Creating a Problem

1. Go to `Admin → Problems → Quick Create`.
2. Upload the **Statement** (PDF or HTML).
3. Create a **Dataset**.
4. **Import Testcases** — Upload a ZIP file containing `.in` and `.sol` files (e.g., `1.in`, `1.sol`).
5. Set the weight for each testcase.
6. Click **"Set as Live"** to activate this version of the problem.

### Rejudging

If testcases contain errors or a submission was graded incorrectly, use the **Rejudge** button on a specific submission or on the entire problem.

---

## 3. Contest Management

### System Modes

- **Standard Mode** — Typical for classroom use. Students see all available problems.
- **Contest Mode** — Time-bound exams. Students see only assigned problems and may have restricted score visibility.
- **Indv-Contest** — Each student has their own individual start and end time.

### Managing a Contest

- Assign specific **Problems** and **Users** to a contest.
- Set **Extra Time** for individual students if needed.
- Monitor the **Contest View** for real-time scores of all participants.

---

## 4. Reports & Security

Admin roles have access to the following reporting tools:

- **Max Score Report** — Spreadsheet view of all users' highest scores across all problems.
- **Cheat Report** — Plagiarism detection. Compares code submissions to find similarities between students.
- **Login Report** — Detects multiple users logging in from the same IP, or one user logging in from multiple machines.
- **Audit Logs** — Complete history of who changed what in the admin panel (testcase edits, score changes, etc.).

---

## 5. System Configuration

Located under `Admin → Grader Configuration`.

- **Site Settings** — Change the site name, welcome message, and theme.
- **Grading Queue** — View background grading process status. If the grader gets stuck, retry error jobs from here.
- **Announcements** — Create site-wide messages visible on the login page or user dashboard.

---

## 6. Communication

- **Messages** — Built-in ticketing system. Students send messages to admins; admins reply.
- **Announcements** — For important updates (e.g., "The contest will end 10 minutes later than planned").

---

## 7. Diagnosing Grader Problems

If submissions hang indefinitely, check each layer in order:

### Check that grader workers are running

```bash
ps aux | grep ruby | grep -v grep
```

If nothing appears, start workers manually:

```bash
cd ~/cafe_grader/web
RAILS_ENV=production bundle exec rails r "Grader.restart(2)"
```

### Check worker log files

```bash
tail -f ~/cafe_grader/web/log/grader-1.txt
```

Submit a job and watch for activity. If the log shows `isolate` errors, see below.

### Check systemd service status

```bash
sudo systemctl status cafe_grader_workers.service
sudo systemctl status cafe_grader_startup.service
sudo systemctl status solid_queue.service
```

If a service shows `failed` or `inactive`, restart it:

```bash
sudo systemctl restart cafe_grader_workers.service
```

### Check isolate is working

```bash
sudo isolate --init --box-id=0
echo $?   # should print 0
```

Common isolate errors and their fixes:

| Error | Cause | Fix |
|---|---|---|
| `User isolate not found in /etc/subuid` | `isolate` system user or subuid entry missing | See Step 4 of installation guide |
| `Cannot open /run/isolate/cgroup` | `isolate.service` not running | `sudo systemctl start isolate.service` |
| `cgroup: cannot set memory limit` | Kernel not booted with `cgroup_enable=memory` | Check GRUB config and reboot |

### Check the production log

```bash
tail -f ~/cafe_grader/web/log/production.log
```

If this file does not exist, Passenger has not successfully started the Rails app yet. Check:

```bash
sudo tail -50 /var/log/apache2/cafe_grader_error.log
```

---

## 8. Tips for Local Testing

**Mock Submissions** — Log in as a student (or use *Direct Edit* in the admin panel) to submit code for testing.

**Database Reset** — If you accidentally delete data during testing, reset everything with:

```bash
cd ~/cafe_grader/web
bundle exec rails db:seed
```

**Restart all services manually** (useful after a config change without rebooting):

```bash
sudo systemctl restart apache2
sudo systemctl restart solid_queue.service
cd ~/cafe_grader/web && RAILS_ENV=production bundle exec rails r "Grader.restart(2)"
```