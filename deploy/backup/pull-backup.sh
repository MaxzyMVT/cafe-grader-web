#!/usr/bin/env bash
#
# Cafe-Grader backup over SSH only - no cloud account needed.
# Runs on an Ubuntu 22.04 control box. Needs only your RSA private key.
#
# It connects to each server as root, makes the backup THERE in /tmp, copies it
# back to this machine with scp, then deletes the remote temp copy. Nothing is
# installed on the servers.
#
#   web+db server  -> MySQL dump (grader + grader_queue) + config/ + storage/
#   worker server  -> config/worker.yml + judge dir
#
# You PASTE the private key when asked (no file path). The key is written to a
# temp file (chmod 600), used, then shredded on exit.
#
# Usage:
#   ./pull-backup.sh                         # asks for hosts + key
#   ./pull-backup.sh <web-db-ip>             # web+db only
#   ./pull-backup.sh <web-db-ip> <w1> <w2>   # web+db + workers
#   ./pull-backup.sh -h                      # this help
#
# Environment overrides:
#   SSH_USER (root)  DEST_DIR (~/cafe-grader-backups)  KEEP_DAYS (7)
#   DB_USER / DB_PASS  (only if mysqldump needs a login)
#   APP_DIR          (Cafe-Grader path on the servers, if auto-detect fails)
#   SCOPE            (full = DB+files+workers [default] ; db = database only, for hourly)
#   SSH_KEY          (key CONTENTS, not a path - lets it run unattended for cron)

set -euo pipefail

case "${1:-}" in -h|--help) awk 'NR>=3&&/^#/{sub(/^# ?/,"");print;next} NR>=3{exit}' "$0"; exit 0;; esac

# --- settings (override via env) --------------------------------------------
SSH_USER="${SSH_USER:-root}"
DEST_DIR="${DEST_DIR:-$HOME/cafe-grader-backups}"
KEEP_DAYS="${KEEP_DAYS:-7}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
APP_DIR="${APP_DIR:-}"   # path to Cafe-Grader ON THE SERVERS (blank = auto-detect common paths)
SCOPE="${SCOPE:-full}"   # full = DB + files + workers ; db = database only (small/fast, for hourly)

# --- prerequisites -----------------------------------------------------------
for t in ssh scp mktemp grep; do
  command -v "$t" >/dev/null || { echo "Required tool not found: $t"; exit 1; }
done

# --- hosts: from args, else ask ---------------------------------------------
WEB_DB_HOST="${WEB_DB_HOST:-}"
WORKER_HOSTS="${WORKER_HOSTS:-}"
if [ "$#" -ge 1 ]; then WEB_DB_HOST="$1"; shift; WORKER_HOSTS="${*:-$WORKER_HOSTS}"; fi
[ -n "$WEB_DB_HOST" ] || read -rp "web+db server IP: " WEB_DB_HOST
[ -n "$WEB_DB_HOST" ] || { echo "No web+db host given"; exit 1; }
if [ -z "$WORKER_HOSTS" ]; then
  read -rp "worker IPs (space-separated, blank if none): " WORKER_HOSTS || true
fi

# --- private key: PASTE it (or supply content via $SSH_KEY) ------------------
KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"
cleanup() { shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"; }
trap cleanup EXIT
if [ -n "${SSH_KEY:-}" ]; then
  printf '%s\n' "$SSH_KEY" > "$KEYFILE"
else
  echo "Paste your PRIVATE key below. Finish with Enter, then Ctrl-D:"
  cat > "$KEYFILE"
fi
grep -q 'PRIVATE KEY' "$KEYFILE" || { echo "That does not look like a private key. Aborting."; exit 1; }

SSH=(ssh -i "$KEYFILE" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
SCP=(scp -i "$KEYFILE" -o StrictHostKeyChecking=accept-new -o BatchMode=yes)

# --- MySQL auth passed to the remote shell as environment (no string-templating) ---
# (mysqldump reads MYSQL_PWD automatically; DBUSER_ARG is used explicitly below.)
REMOTE_ENV=""
[ -n "$DB_USER" ] && REMOTE_ENV+="DBUSER_ARG='-u$DB_USER' "
[ -n "$DB_PASS" ] && REMOTE_ENV+="MYSQL_PWD='$DB_PASS' "

# APP_DIR (if given) is passed to every host so file/config backup finds the app.
COMMON_ENV=""
[ -n "$APP_DIR" ] && COMMON_ENV+="APP_DIR='$APP_DIR' "
WEB_ENV="$COMMON_ENV$REMOTE_ENV"
[ "$SCOPE" = db ] && WEB_ENV+="SKIP_FILES=1 "   # db scope: dump database, skip storage/config

# --- run a script on a host (via stdin); print its non-empty output lines -----
run_remote() {  # run_remote <host> <script> [env-prefix]
  printf '%s\n' "$2" | "${SSH[@]}" "$SSH_USER@$1" "${3:-}bash -s" | grep -v '^[[:space:]]*$' || true
}

# --- copy listed remote files back, then delete them on the server -----------
fetch() {  # fetch <host> <localdir> <file>...
  local h="$1" ld="$2"; shift 2
  [ "$#" -gt 0 ] || return 0
  mkdir -p "$ld"
  local rf
  for rf in "$@"; do
    echo "    pull $(basename "$rf")"
    "${SCP[@]}" "$SSH_USER@$h:$rf" "$ld/"
  done
  "${SSH[@]}" "$SSH_USER@$h" "rm -f $*" >/dev/null 2>&1 || true
}

# --- Check remote memory before taking backup to prevent OOM crash -----------
echo "Checking remote memory..."
REMOTE_MEM_SCRIPT='free | awk '\''/Mem:/ {print $7}'\'''
REMOTE_AVAIL_MEM=$(run_remote "$WEB_DB_HOST" "$REMOTE_MEM_SCRIPT" || echo 9999999)
REMOTE_AVAIL_MEM=$(echo "$REMOTE_AVAIL_MEM" | tr -d '\r\n' | grep -E '^[0-9]+$' || echo 9999999)

if [ "$REMOTE_AVAIL_MEM" -lt 102400 ]; then # less than 100MB
  echo "ERROR: Remote server is extremely low on memory ($((REMOTE_AVAIL_MEM/1024)) MB available). Skipping backup to prevent OOM crash."
  exit 1
fi

# --- Check space before taking backup to prevent hitting 100% capacity -----------
# Estimate backup size: database size (rough estimate ~100MB) + /storage directory size on remote server
echo "Estimating backup size from remote storage..."
DETECT_SCRIPT='
APP=""
for d in /root/cafe_grader/web /home/*/cafe_grader/web /opt/cafe_grader/web /root/cafe-grader-web /home/*/cafe-grader-web /var/www/cafe-grader-web /opt/cafe-grader-web; do
  [ -d "$d" ] && { APP="$d"; break; }
done
if [ -n "$APP" ] && [ -d "$APP/storage" ]; then
  du -s "$APP/storage" | awk "{print \$1}"
else
  echo 0
fi
'
STORAGE_SIZE_KB=$(run_remote "$WEB_DB_HOST" "$DETECT_SCRIPT" || echo 0)
STORAGE_SIZE_KB=$(echo "$STORAGE_SIZE_KB" | tr -d '\r\n' | grep -E '^[0-9]+$' || echo 0)

# Conservative estimated backup size in KB (compressed to ~50% average)
ESTIMATED_BACKUP_KB=$(( (STORAGE_SIZE_KB + 204800) / 2 ))
# Available space on backup drive in KB
AVAILABLE_KB=$(df "$DEST_DIR" | tail -1 | awk '{print $4}')

# If available space is less than estimated backup size + 2GB safety margin, trigger early cleanup
SAFETY_MARGIN_KB=2097152
REQUIRED_KB=$(( ESTIMATED_BACKUP_KB + SAFETY_MARGIN_KB ))

if [ "$AVAILABLE_KB" -lt "$REQUIRED_KB" ]; then
  echo "WARNING: Low disk space detected ($((AVAILABLE_KB/1024)) MB available). Running pre-backup cleanup..."
  DIR=$(dirname "$0")
  if [ -f "$DIR/cleanup-backups.sh" ]; then
    # Dynamically prune backups down to 1 day early to free up space
    bash "$DIR/cleanup-backups.sh" "$DEST_DIR" 1
  fi
fi

# ============================== WEB + DB =====================================
echo "==> web+db : $WEB_DB_HOST"
read -r -d '' WEB_SCRIPT <<'REMOTE' || true
set -eo pipefail
TS=$(date +%F_%H%M%S)
OUT=/tmp/cafebk; mkdir -p "$OUT"
DB="$OUT/db_$TS.sql.gz"
mysqldump ${DBUSER_ARG:-} --single-transaction --quick --routines --triggers --events --databases grader grader_queue | gzip > "$DB"
[ -s "$DB" ] && echo "$DB"
APP="${APP_DIR:-}"
if [ -z "$APP" ]; then
  for d in /root/cafe_grader/web /home/*/cafe_grader/web /opt/cafe_grader/web \
           /root/cafe-grader-web /home/*/cafe-grader-web /var/www/cafe-grader-web /opt/cafe-grader-web; do
    [ -d "$d" ] && { APP="$d"; break; }
  done
fi
if [ -n "$APP" ] && [ "${SKIP_FILES:-0}" != 1 ]; then
  F="$OUT/files_$TS.tar.gz"
  tar -C "$APP" --ignore-failed-read -czf "$F" config storage 2>/dev/null || true
  [ -s "$F" ] && echo "$F"
fi
REMOTE

mapfile -t webfiles < <(run_remote "$WEB_DB_HOST" "$WEB_SCRIPT" "$WEB_ENV")
[ "${#webfiles[@]}" -gt 0 ] || { echo "ERROR: web+db produced no backup (mysqldump may need DB_USER/DB_PASS)"; exit 1; }
fetch "$WEB_DB_HOST" "$DEST_DIR/web-db" "${webfiles[@]}"
if [ "$SCOPE" != db ]; then
  printf '%s\n' "${webfiles[@]}" | grep -q 'files_' || \
    echo "    WARNING: only the database was saved. config/ (incl. master.key) and storage/ were skipped because the app folder was not found. Re-run with APP_DIR=/real/path"
fi

# ============================== WORKERS ======================================
read -r -d '' WORKER_SCRIPT <<'REMOTE' || true
set -eo pipefail
TS=$(date +%F_%H%M%S)
OUT=/tmp/cafebk; mkdir -p "$OUT"
APP="${APP_DIR:-}"
if [ -z "$APP" ]; then
  for d in /root/cafe_grader/web /home/*/cafe_grader/web /opt/cafe_grader/web \
           /root/cafe-grader-web /home/*/cafe-grader-web /var/www/cafe-grader-web /opt/cafe-grader-web; do
    [ -d "$d" ] && { APP="$d"; break; }
  done
fi
if [ -n "$APP" ]; then
  W="$OUT/worker_$TS.tar.gz"
  tar -C "$APP" --ignore-failed-read -czf "$W" config/worker.yml 2>/dev/null || true
  [ -s "$W" ] && echo "$W"
  if [ -d "$APP/../judge" ]; then
    J="$OUT/judge_$TS.tar.gz"
    tar -C "$APP/.." --ignore-failed-read --exclude=judge/raw --exclude=judge/tmp -czf "$J" judge 2>/dev/null || true
    [ -s "$J" ] && echo "$J"
  fi
fi
REMOTE

[ "$SCOPE" = db ] && WORKER_HOSTS=""   # db scope: web database only, skip workers
for w in $WORKER_HOSTS; do
  echo "==> worker : $w"
  mapfile -t wf < <(run_remote "$w" "$WORKER_SCRIPT" "$COMMON_ENV")
  if [ "${#wf[@]}" -gt 0 ]; then fetch "$w" "$DEST_DIR/$w" "${wf[@]}"
  else echo "    (nothing to back up - app dir not found on $w)"; fi
done

# ============================== RETENTION ====================================
if [ -d "$DEST_DIR" ]; then
  # Run the updated cleanup script to purge old backups and manage space
  DIR=$(dirname "$0")
  if [ -f "$DIR/cleanup-backups.sh" ]; then
    bash "$DIR/cleanup-backups.sh" "$DEST_DIR" "$KEEP_DAYS"
  else
    find "$DEST_DIR" -type f -name '*.gz' -mtime "+$KEEP_DAYS" -print -delete 2>/dev/null \
      | sed 's/^/    prune /' || true
  fi
fi

# Clean up remote temporary backups on WEB_DB_HOST
if [ -n "$WEB_DB_HOST" ]; then
  echo "==> Cleaning old /tmp/cafebk backups on remote host: $WEB_DB_HOST"
  run_remote "$WEB_DB_HOST" "find /tmp/cafebk -type f -mtime +1 -name '*.gz' -delete 2>/dev/null || true" "$WEB_ENV"
fi

echo
echo "DONE. Backups saved under: $DEST_DIR"
