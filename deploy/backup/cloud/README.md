# cloud/ — Huawei OBS + CBR backup (needs a cloud account)

These scripts are the **alternative** backup approach for when you have a **Huawei Cloud account**
(console access + OBS access keys). They run *on the servers* and push backups to **OBS**, plus set up
**CBR** whole-VM disk snapshots.

> **If you only have SSH access (an RSA key) and no cloud account, ignore this folder** and use
> `../pull-backup.sh` instead. See `../README.md`.

| Script | Where to run | What it does |
|--------|--------------|--------------|
| `install.sh` | on each server, once | Installs obsutil, schedules cron, runs first backup. Asks only the server role. |
| `backup-web-db.sh` | scheduled by `install.sh` | Dumps `grader`+`grader_queue`, `config/`, `storage/` → OBS. |
| `backup-worker.sh` | scheduled by `install.sh` | Backs up `worker.yml` + judge dir → OBS. |
| `huawei-cbr-setup.sh` | once, from a machine with `hcloud` | Creates a CBR vault + scheduled disk-snapshot policy for all VMs. |

Full setup, scheduling, and restore instructions for this approach live in the git history of
`../README.md` (before it was rewritten for the SSH-only method). Ask and I'll restore the detailed
cloud guide here if you move to a cloud account.
