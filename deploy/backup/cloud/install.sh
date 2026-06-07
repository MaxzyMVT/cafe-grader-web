#!/usr/bin/env bash
#
# Cafe-Grader — one-shot backup installer (Layer B: app backups -> Huawei OBS).
#
# You only choose the SERVER ROLE. Everything else is auto-filled from the
# defaults below (edit them once if your setup differs, or pass env vars).
#
# Run ONCE on each server:
#   sudo ./install.sh                 # asks: web-db or worker?
#   sudo ./install.sh web-db          # or pass the role directly
#   sudo ./install.sh worker
#
# It installs obsutil, sets the clock, copies the backup script, schedules it,
# and runs the first backup. (Whole-VM snapshots = Layer A = huawei-cbr-setup.sh.)

set -euo pipefail

# ============================================================================
# AUTO-FILLED DEFAULTS — edit here once if needed, or override with env vars.
# ============================================================================
APP_DIR="${APP_DIR:-/home/grader/cafe-grader-web}"          # where Cafe-Grader lives
OBS_BUCKET="${OBS_BUCKET:-cafe-grader-backups}"             # OBS bucket for backups
OBS_ENDPOINT="${OBS_ENDPOINT:-obs.ap-southeast-2.myhuaweicloud.com}"
DB_USER="${DB_USER:-grader}"

# Secrets — leave BLANK to reuse an already-configured obsutil / existing ~/.my.cnf.
# To set them on the fly:  sudo OBS_AK=.. OBS_SK=.. DB_PASS=.. ./install.sh web-db
OBS_AK="${OBS_AK:-}"
OBS_SK="${OBS_SK:-}"
DB_PASS="${DB_PASS:-}"
# ============================================================================

DEST_DIR="/opt/cafe-backup"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- must be root ------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo:  sudo ./install.sh"; exit 1; }

# --- the ONLY input: server role --------------------------------------------
ROLE="${1:-${ROLE:-}}"
if [ -z "$ROLE" ]; then
  read -rp "Server role — type 'web-db' or 'worker': " ROLE
fi
case "$ROLE" in
  web-db|worker) ;;
  *) echo "ROLE must be 'web-db' or 'worker' (got: '$ROLE')"; exit 1;;
esac

echo "=== Installing Cafe-Grader backups: role=$ROLE ==="
[ -d "$APP_DIR" ] || echo "  (note: APP_DIR '$APP_DIR' not found yet — edit the default if wrong)"

# --- 1. timezone -------------------------------------------------------------
echo "==> Setting timezone to Asia/Bangkok"
timedatectl set-timezone Asia/Bangkok || echo "  (could not set timezone; set it manually)"

# --- 2. obsutil --------------------------------------------------------------
if ! command -v obsutil >/dev/null; then
  echo "==> Installing obsutil"
  tmp="$(mktemp -d)"; pushd "$tmp" >/dev/null
  wget -q https://obs-community.obs.cn-north-1.myhuaweicloud.com/obsutil/current/obsutil_linux_amd64.tar.gz
  tar xzf obsutil_linux_amd64.tar.gz
  install -m 0755 obsutil_linux_amd64_*/obsutil /usr/local/bin/obsutil
  popd >/dev/null; rm -rf "$tmp"
fi

if [ -n "$OBS_AK" ] && [ -n "$OBS_SK" ]; then
  echo "==> Connecting obsutil to your account"
  obsutil config -i="$OBS_AK" -k="$OBS_SK" -e="$OBS_ENDPOINT" >/dev/null
elif [ -f "$HOME/.obsutilconfig" ]; then
  echo "==> Reusing existing obsutil config ($HOME/.obsutilconfig)"
else
  echo "ERROR: obsutil is not configured and no OBS_AK/OBS_SK were given."
  echo "  Either configure once:  obsutil config -i=AK -k=SK -e=$OBS_ENDPOINT"
  echo "  or re-run:              sudo OBS_AK=.. OBS_SK=.. ./install.sh $ROLE"
  exit 1
fi
# create the bucket (harmless if it already exists)
obsutil mb "obs://$OBS_BUCKET" >/dev/null 2>&1 || true

# --- 3. MySQL credentials (web-db only) --------------------------------------
if [ "$ROLE" = "web-db" ]; then
  if [ -n "$DB_PASS" ]; then
    echo "==> Writing /root/.my.cnf (chmod 600)"
    ( umask 077; printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASS" > /root/.my.cnf )
  elif [ -f /root/.my.cnf ] || [ -f "$HOME/.my.cnf" ]; then
    echo "==> Reusing existing ~/.my.cnf for MySQL auth"
  else
    echo "  WARN: no DB_PASS given and no ~/.my.cnf found — the DB dump may fail."
    echo "        Re-run with  sudo DB_PASS=.. ./install.sh web-db  or create ~/.my.cnf."
  fi
fi

# --- 4. install backup scripts ----------------------------------------------
echo "==> Installing backup scripts to $DEST_DIR"
mkdir -p "$DEST_DIR" /var/backups/cafe-grader
install -m 0755 "$SRC_DIR/backup-web-db.sh" "$DEST_DIR/backup-web-db.sh"
install -m 0755 "$SRC_DIR/backup-worker.sh" "$DEST_DIR/backup-worker.sh"

# --- 5. cron schedule (idempotent — one file in /etc/cron.d) -----------------
CRON_FILE="/etc/cron.d/cafe-grader-backup"
echo "==> Writing schedule to $CRON_FILE"
{
  echo "# Cafe-Grader backups — managed by install.sh. Edit timing here if needed."
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/bin:/usr/bin:/bin"
  echo "APP_DIR=$APP_DIR"
  echo "OBS_BUCKET=$OBS_BUCKET"
  echo
  if [ "$ROLE" = "web-db" ]; then
    echo "# hourly — database only (light, no table locks)"
    echo "15 * * * * root BACKUP_LABEL=db INCLUDE_STORAGE=0 INCLUDE_DATA=0 OBS_PREFIX=web-db/hourly KEEP_LOCAL_DAYS=2 $DEST_DIR/backup-web-db.sh >> /var/log/cafe-backup.log 2>&1"
    echo "# daily 02:30 — full (database + storage/ + configs)"
    echo "30 2 * * * root BACKUP_LABEL=full INCLUDE_STORAGE=1 OBS_PREFIX=web-db/daily KEEP_LOCAL_DAYS=7 $DEST_DIR/backup-web-db.sh >> /var/log/cafe-backup.log 2>&1"
  else
    echo "# weekly Sun 03:00 — worker config + judge dir"
    echo "0 3 * * 0 root $DEST_DIR/backup-worker.sh >> /var/log/cafe-backup.log 2>&1"
  fi
} > "$CRON_FILE"
chmod 0644 "$CRON_FILE"

# --- 6. run one backup now ---------------------------------------------------
echo "==> Running a first backup now (proves it works)"
if [ "$ROLE" = "web-db" ]; then
  APP_DIR="$APP_DIR" OBS_BUCKET="$OBS_BUCKET" BACKUP_LABEL=full \
    OBS_PREFIX=web-db/daily INCLUDE_STORAGE=1 "$DEST_DIR/backup-web-db.sh"
else
  APP_DIR="$APP_DIR" OBS_BUCKET="$OBS_BUCKET" "$DEST_DIR/backup-worker.sh"
fi

cat <<EOF

=== DONE ===
  Role     : $ROLE
  Backups  : obs://$OBS_BUCKET/
  Schedule : $CRON_FILE
  Log      : /var/log/cafe-backup.log

Next:
  - Set up whole-VM snapshots (Layer A) once — see README "Whole-server snapshots".
  - In OBS console, add Lifecycle Rules to auto-delete old backups (README step 6).
  - Check it landed:  obsutil ls obs://$OBS_BUCKET/
EOF
