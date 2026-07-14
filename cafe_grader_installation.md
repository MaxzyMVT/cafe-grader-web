# Cafe-Grader Installation Guide

Target OS: **Ubuntu 22.04 LTS**. Run the installer as a normal user with `sudo`
privileges (not root). The only manual step afterwards is `sudo reboot`.

The shell installers fully automate every step and are the **source of truth** — this
guide summarises *what* they do and *why*; it does not restate every command (which
would drift). To read the exact steps, see the scripts and the shared library they
source: `deploy/lib/common.sh` (all `cg_*` functions), `install_single_server.sh`,
`install_web_db_server.sh`, `install_worker_server.sh`.

---

## Quick Start

| Deployment | Command |
|---|---|
| Single server (all-in-one) | `bash install_single_server.sh` |
| Web/DB node (Server 1 of 3) | `bash install_web_db_server.sh` |
| Worker node (Server 2, 3, …) | `bash install_worker_server.sh <SERVER_1_IP> <WORKER_ID>` |

Add `--cloud` on AWS/GCP/Azure (uses the instance metadata service for the public IP
and prints security-group reminders instead of touching `ufw`), e.g.
`bash install_single_server.sh --cloud`.

```bash
# 3-server: Server 1 first, then each worker with a UNIQUE id
bash install_web_db_server.sh
bash install_worker_server.sh <SERVER_1_IP> 1
bash install_worker_server.sh <SERVER_1_IP> 2
```

After each script finishes: `sudo reboot`. Everything starts automatically on boot.

**Default login:** `root` / `ioionrails` — change immediately after first login.

---

## What the installers do

Each role script sets its config (repo URL, DB name/user/pass, worker count) and calls
the shared `cg_*` steps from `deploy/lib/common.sh`:

| Step (function) | Single | Web/DB | Worker | Notes |
|---|:--:|:--:|:--:|---|
| System packages + rbenv/Ruby 3.4.4 + bundler | ● | ● | ● | `cg_install_ruby` |
| Language compilers (C/C++/Java/Go/Rust/…) | ● | | ● | grading hosts only |
| MySQL (`grader` + `grader_queue`) | ● | ● | | web/db binds `0.0.0.0` + wildcard user for workers |
| ioi/isolate + system user + swap off | ● | | ● | `cg_install_isolate` |
| isolate systemd + kernel + GRUB cgroup | ● | | ● | hard RAM cap for submissions |
| Clone app, patch `database.yml`/`worker.yml`, credentials | ● | ● | ● | matched `master.key` via `credentials:edit` |
| `db:setup`/`db:migrate` + assets | ● | ● | | empty-DB guard (safe re-run) |
| Passenger + Apache (port 80) | ● | ● | | `cg_install_passenger_apache` |
| Solid Queue service | ● | ● | | background jobs |
| Grader workers + watchdog crontab | ● | | ● | `cg_write_workers_service` |

Services are `systemctl enable`d, so a reboot brings the whole stack up.

---

## Key design points (why the scripts do what they do)

- **isolate lives in `$HOME/isolate` (not `/tmp`)** — `/tmp` is wiped on reboot, which
  would break the `isolate.service` symlink and the sandbox cgroup.
- **`isolate` system user + `subuid`/`subgid` `200000:65536`** — isolate v2.5+ needs
  these for user-namespace sandboxing; the `200000` base avoids a collision with
  Ubuntu's default `100000` allocation. Missing → workers sit idle with no heartbeat.
- **Swap is disabled + `cgroup_enable=memory swapaccount=1` in GRUB** — makes the
  isolate `--cg-mem` limit a *hard* RAM cap with deterministic OOM-kill and clean
  timing. Trade-off: no swap cushion, so the installer runs an advisory **RAM headroom
  check** and warns if physical RAM is below `WORKER_COUNT × 1 GB + system overhead`.
- **Rails credentials via `credentials:edit`** — writes a matched `master.key` +
  `credentials.yml.enc` pair. **Back up `config/master.key`** — losing it makes the
  encrypted credentials (and the app) unrecoverable.
- **rbenv-absolute paths in every systemd unit and Passenger call** — so a system RVM
  can never hijack the Ruby the services run under.

---

## Three-server specifics

- **Server 1 (`install_web_db_server.sh`)** runs the web app + MySQL, **no isolate, no
  grader workers** (`worker.yml` has `isolate_path` blanked, `worker_id: 0`). MySQL
  binds all interfaces with a `grader_user@%` account — **open TCP 3306 only to worker
  IPs**.
- **Workers (`install_worker_server.sh <IP> <WORKER_ID>`)** build isolate and run the
  graders, connecting to Server 1 for the DB. **Each worker server needs a UNIQUE
  `WORKER_ID`** (1, 2, 3, …). The id keys every `GraderProcess (worker_id, box_id)` row
  and scopes the watchdog; two workers sharing an id register as the same processes and
  their watchdogs fight (spawn/kill thrash). `WORKER_ID` defaults to 1.

Check worker health after reboot:

```bash
sudo systemctl status cafe_grader_workers.service
tail -f ~/cafe_grader/web/log/grader-1.txt
```

---

For local development (not production), see the [Local Setup Guide](cafe_grader_local_setup.md).
