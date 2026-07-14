# Cafe-Grader Backups — Beginner's Guide

New here? Start at the top and go down. No prior experience needed.

---

## 1. What is a backup, and why do I care?

Cafe-Grader runs on **3 computers in the cloud** (we call them *servers*). They hold everything that
matters: student accounts, problems, test cases, and every code submission.

If one of those servers breaks, gets hacked, or someone deletes the wrong thing — that data is gone.
**Forever**, unless you have a copy somewhere else.

> A **backup** is simply a *copy of the important data, kept in a safe separate place*, so you can put
> it back if the original is lost.

Think of it like photographing your homework before handing it in: if the original gets lost, you can
reprint it from the photo.

This guide sets up automatic copies of all 3 servers onto **your own computer**.

---

## 2. How it works (the simple picture)

You run **one tool, on one computer** (an Ubuntu 22.04 machine — your "control box"). That tool reaches
out to each server over the internet, makes a copy of its data, and pulls the copy back to your machine.

```
   YOUR Ubuntu computer
   (runs pull-backup.sh)
          |
          |  connects over SSH (using your key)
          |
   +------+-------+----------------+
   |              |                |
 web+db server  worker 1        worker 2
 (the main one)  (grades code)   (grades code)
```

**Important:** you do **not** install or run anything *on the servers*. Everything happens from your
one computer. (One question people ask: "Do I run this on every server?" — **No. Just your one
control box.**)

### What exactly gets copied?

| From | What gets backed up | Why it matters |
|------|---------------------|----------------|
| **web+db server** | the two databases `grader` + `grader_queue` | This is *everything*: accounts, problems, test cases, every submission, and contests |
| **web+db server** | `config/` (including `master.key`) and `storage/` | The secret keys the app needs to run, plus uploaded files (problem attachments, statements) |
| **each worker** | `config/worker.yml` and the judge folder | The worker's identity + any custom grading scripts |

Each run produces a few small compressed files (ending in `.gz`). The database file is the most
important one — protect that and you've protected the heart of the system.

---

## 3. Words you'll see (quick glossary)

- **Server** — one of the 3 cloud computers running Cafe-Grader.
- **Control box** — *your* computer (Ubuntu 22.04) where you run the backup tool.
- **Terminal** — the black text window where you type commands. On Ubuntu: press `Ctrl+Alt+T`.
- **SSH** — the secure way to connect to a server over the internet.
- **RSA private key** — a secret file that proves it's really you. Instead of a password, you have this
  key. (You'll paste its text when asked.)
- **mysqldump** — the standard tool that exports a MySQL database into a file. Runs *on the server*; you
  don't install it.
- **cron** — Ubuntu's built-in "alarm clock" that runs a command automatically on a schedule.

---

## 4. What you need before you start

1. An **Ubuntu 22.04 computer** to run this from. (It already has every tool needed — `ssh`, `scp`,
   `tar`. Nothing extra to install.)
2. Your **RSA private key** — the text file you use to log into the servers.
3. The **3 server IP addresses** (numbers like `203.0.113.5`): the web+db server, and the two workers.
   Whoever set up the servers can give you these.

That's all. No cloud account, no passwords, no software to install on the servers.

---

## 5. Install (it's tiny)

There's almost nothing to "install" — you just need to get this folder onto your Ubuntu computer and
mark the script as runnable.

1. Open a **terminal** (`Ctrl+Alt+T`).
2. Get the project (if you don't already have it). For example:
   ```bash
   git clone <your-repo-url>
   cd cafe-grader-web/deploy/backup
   ```
   (Or copy just this `deploy/backup` folder onto the machine — any way you like.)
3. Make the script runnable (one time):
   ```bash
   chmod +x pull-backup.sh
   ```

Done. There's no installer to run.

---

## 6. Run your first backup

Type this, replacing the `<...>` parts with your real server IPs:

```bash
./pull-backup.sh <web-db-ip> <worker1-ip> <worker2-ip>
```

The tool will then ask for your key. **Paste the whole key**, press Enter, then press **Ctrl+D**:

```
Paste your PRIVATE key below. Finish with Enter, then Ctrl-D:
-----BEGIN OPENSSH PRIVATE KEY-----
...all the lines of your key...
-----END OPENSSH PRIVATE KEY-----
        <-- press Enter, then Ctrl+D here
```

> Your key is held in a temporary file just for this run, and **wiped automatically** when the tool
> finishes. It is never saved into the project.

You'll see progress like `==> web+db : ...`, `pull db_....sql.gz`, ending with `DONE.`

**Where did the backups go?** Into a folder in your home directory:
```
~/cafe-grader-backups/
   web-db/        db_2026-06-07_120000.sql.gz      (the database)
                  files_2026-06-07_120000.tar.gz   (settings + uploaded files)
   <worker1-ip>/  worker_....tar.gz   judge_....tar.gz
   <worker2-ip>/  worker_....tar.gz
```

> **Tip:** Don't know the IPs or want it to ask you step by step? Just run `./pull-backup.sh` with
> nothing after it, and it'll prompt for everything. Run `./pull-backup.sh -h` to see all options.

> **If you get an error about the database** (e.g. "produced no backup"), your DB needs a login. Add it:
> ```bash
> DB_USER=grader_user DB_PASS=yourpassword ./pull-backup.sh <web-db-ip> <worker1-ip> <worker2-ip>
> ```

> **If you see "app dir not found", or only the `db_*.sql.gz` appears with no `files_*.tar.gz`:** the
> script couldn't find where Cafe-Grader lives on the servers, so `config/` (including `master.key`),
> `storage/`, and the workers were skipped. Find the real path, then pass it with `APP_DIR`:
> ```bash
> # 1. find it (replace KEY with your key file; installer layout is cafe_grader/web):
> ssh -i KEY root@<web-db-ip> "find / -maxdepth 6 -type d -path '*/cafe_grader/web' 2>/dev/null"
> # 2. back up again, giving that path:
> APP_DIR=/home/grader/cafe_grader/web ./pull-backup.sh <web-db-ip> <worker1-ip> <worker2-ip>
> ```
> (If the servers keep the app in different paths, run the script once per server with the matching
> `APP_DIR`.)

---

## 7. Make it automatic (so you don't have to remember)

Right now you run it by hand. To have Ubuntu run it for you **every hour**, use **cron**.

### How often should it run?

The database changes constantly, but the uploaded files (`storage/`, ~1 GB) and the worker folders
barely change. So back them up at **different rates**:

| What | How often | Why |
|------|-----------|-----|
| **Database only** (`SCOPE=db`) | **every hour** | The hot data — keeps worst-case loss under ~1 hour |
| **Full** (database + storage + workers) | **once a day** | Large (~1.5 GB); changes slowly, so daily is plenty |
| Old backups | kept **7 days**, then auto-deleted (`KEEP_DAYS`) | |

A *full* backup every hour would copy ~1.5 GB each time and fill your disk fast — that's why the hourly
run is **database-only**. The two cron lines below set this up.

Because the automatic run can't stop to ask you to paste the key, you first save the key into a private
file, then tell cron to use it.

1. Save your key once, readable only by you. Paste the key, then press **Ctrl+D**:
   ```bash
   ( umask 077; cat > ~/.cafe-backup.key )
   chmod 600 ~/.cafe-backup.key
   ```
   (`umask 077` makes the file private from the moment it's created.) If your key is already a file on
   this machine, just copy it instead: `cp /path/to/key ~/.cafe-backup.key && chmod 600 ~/.cafe-backup.key`.

2. Open cron's schedule list:
   ```bash
   crontab -e
   ```
   (If it asks which editor, pick `nano` — the easiest.)

3. Add these **two lines** at the bottom (fix the path and the IPs), then save:
   ```cron
   # every hour - DATABASE ONLY (small & fast; only the web+db server is needed)
   0 * * * *   SCOPE=db   SSH_KEY="$(cat $HOME/.cafe-backup.key)" /home/you/cafe-grader-web/deploy/backup/pull-backup.sh <web-db-ip> >> $HOME/cafe-backup.log 2>&1

   # every day at 02:30 - FULL backup (database + storage + workers)
   30 2 * * *  SCOPE=full SSH_KEY="$(cat $HOME/.cafe-backup.key)" /home/you/cafe-grader-web/deploy/backup/pull-backup.sh <web-db-ip> <worker1-ip> <worker2-ip> >> $HOME/cafe-backup.log 2>&1
   ```
   The first field is the schedule: `0 * * * *` = top of every hour, `30 2 * * *` = 02:30 daily. Your
   computer must be **on and awake** at those times for the backup to run.

Backups older than 7 days are deleted automatically so your disk doesn't fill up (change with
`KEEP_DAYS`).

---

## 8. Make sure it actually worked

A backup you've never checked is just a hope. After your first run:

1. **See the files:** `ls -lh ~/cafe-grader-backups/web-db/`
   You should see a `db_*.sql.gz` and a `files_*.tar.gz`.
2. **Check the database file isn't empty:** it should be more than a few KB. If it's tiny, the database
   export failed — re-run with `DB_USER`/`DB_PASS` (Section 6).
3. **Peek inside:** `zcat ~/cafe-grader-backups/web-db/db_*.sql.gz | head` — you should see SQL text.

---

## 9. Putting a backup back (restore)

You hopefully won't need this often. The idea: copy a backup file from your computer **up** to a
server, then load it. Replace `<file>`, `<server-ip>`, and `yourkey` with your real values.

**Restore the database:**
```bash
scp -i yourkey ~/cafe-grader-backups/web-db/db_<time>.sql.gz root@<server-ip>:/tmp/
ssh -i yourkey root@<server-ip> "zcat /tmp/db_<time>.sql.gz | mysql"
```

**Restore settings + uploaded files:**
```bash
scp -i yourkey ~/cafe-grader-backups/web-db/files_<time>.tar.gz root@<server-ip>:/tmp/
ssh -i yourkey root@<server-ip> "tar -C /home/grader/cafe_grader/web -xzf /tmp/files_<time>.tar.gz"
```

**Restore a worker:**
```bash
scp -i yourkey ~/cafe-grader-backups/<worker-ip>/worker_<time>.tar.gz root@<worker-ip>:/tmp/
ssh -i yourkey root@<worker-ip> "tar -C /home/grader/cafe_grader/web -xzf /tmp/worker_<time>.tar.gz"
```

---

## 10. If something goes wrong

| You see… | What it means / fix |
|----------|---------------------|
| `That does not look like a private key` | You pasted the wrong text. Paste the full `-----BEGIN ... PRIVATE KEY-----` block. |
| `Permission denied (publickey)` | Wrong key, or this key isn't allowed on that server. |
| `Host key verification failed` | Connect once by hand to approve the server: `ssh -i yourkey root@<ip>` and type `yes`. |
| `web+db produced no backup` | The database needs a login — add `DB_USER=grader_user DB_PASS=...` (Section 6). |
| `nothing to back up - app dir not found` | Cafe-Grader is installed in an unusual place on that server. Tell me the real path and I'll add it. |
| The scheduled (cron) backup didn't run | Your computer was off/asleep at that time, or the path/IPs in the cron line are wrong. Check `~/cafe-backup.log`. |

---

## What's in this folder

| Item | What it's for |
|------|---------------|
| **`pull-backup.sh`** | **The backup tool. This is the one you use.** |
| `README.md` | This guide. |
| `cloud/` | A *different* backup method for if you ever get a full Huawei Cloud account. **Ignore it for now.** |

---

## Appendix — the `cloud/` folder (not for you yet)

The scripts in `cloud/` upload backups straight from the servers to Huawei's cloud storage (OBS) and
take whole-server snapshots (CBR). They need a Huawei Cloud account with access keys — which you don't
have. If you get one later, ask me and I'll walk you through it. Until then, **use `pull-backup.sh`**.
