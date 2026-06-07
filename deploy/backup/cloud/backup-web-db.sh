#!/usr/bin/env bash
#
# Cafe-Grader — application-level backup for the WEB + DB VM.
#
# Backs up the irreplaceable state that a disk snapshot alone is awkward to
# restore selectively:
#   - MySQL databases: grader, grader_queue   (users, problems, TESTCASES, submissions, contests)
#   - config/master.key + credentials.yml.enc (without master.key the encrypted
#     credentials are permanently unrecoverable)
#   - prod config not in git: database.yml, worker.yml, llm.yml, cafe_grader.rb
#   - Active Storage uploads: storage/         (problem attachments / statements)
#   - test_request I/O: data/                  (optional, usually regenerable)
#
# Produces ONE timestamped tarball, checksums it, and pushes it to Huawei OBS.
# Schedule via cron (see README.md). Idempotent and safe to re-run.
#
# Restore: see README.md "Restore — Web+DB".

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG — edit these for the server, or override via environment variables.
# ----------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/home/grader/cafe-grader-web}"   # Rails app root on the server
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cafe-grader}"  # local staging dir

# Backup stream label -> goes into the filename and scopes local pruning, so the
# hourly DB-only stream and the daily full stream retain independently:
#   hourly DB-only :  BACKUP_LABEL=db    INCLUDE_STORAGE=0  KEEP_LOCAL_DAYS=2
#   daily full     :  BACKUP_LABEL=full  INCLUDE_STORAGE=1  KEEP_LOCAL_DAYS=7
BACKUP_LABEL="${BACKUP_LABEL:-full}"

# MySQL credentials. Prefer a ~/.my.cnf (chmod 600) with [client] user/password
# and leave DB_PASS empty. If DB_PASS is set, a temp 0600 defaults-file is used
# so the password never appears in `ps`.
DB_USER="${DB_USER:-grader}"
DB_PASS="${DB_PASS:-}"
DB_SOCKET="${DB_SOCKET:-/var/run/mysqld/mysqld.sock}"
DBS="${DBS:-grader grader_queue}"

INCLUDE_STORAGE="${INCLUDE_STORAGE:-1}"   # 1 = include storage/ (Active Storage)
INCLUDE_DATA="${INCLUDE_DATA:-0}"         # 1 = include data/ (test_request I/O)

# Huawei OBS (set OBS_BUCKET empty to skip upload and keep local-only).
# Requires obsutil installed & configured: obsutil config -i=AK -k=SK -e=ENDPOINT
OBS_BUCKET="${OBS_BUCKET:-}"                          # e.g. cafe-grader-backups
OBS_PREFIX="${OBS_PREFIX:-web-db}"                    # path inside the bucket
OBSUTIL="${OBSUTIL:-obsutil}"

KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-7}"   # prune local tarballs older than this
# (Remote retention is handled by an OBS lifecycle rule — see README.md.)
# ----------------------------------------------------------------------------

log() { printf '%s [backup-web-db] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -d "$APP_DIR" ] || die "APP_DIR not found: $APP_DIR"
command -v mysqldump >/dev/null || die "mysqldump not found"
mkdir -p "$BACKUP_DIR"

TS="$(date +%F_%H%M%S)"
HOST="$(hostname -s)"
STAGE="$(mktemp -d "${BACKUP_DIR}/.stage.${TS}.XXXX")"
ARCHIVE="${BACKUP_DIR}/cafe-web_${BACKUP_LABEL}_${HOST}_${TS}.tar.gz"

# Always clean up staging + any temp my.cnf, even on failure.
MYCNF=""
cleanup() { rm -rf "$STAGE"; [ -n "$MYCNF" ] && rm -f "$MYCNF" || true; }
trap cleanup EXIT

# --- MySQL auth ---------------------------------------------------------------
MYSQL_AUTH=(--socket="$DB_SOCKET" --user="$DB_USER")
if [ -n "$DB_PASS" ]; then
  MYCNF="$(mktemp)"; chmod 600 "$MYCNF"
  printf '[client]\nuser=%s\npassword=%s\nsocket=%s\n' "$DB_USER" "$DB_PASS" "$DB_SOCKET" > "$MYCNF"
  MYSQL_AUTH=(--defaults-extra-file="$MYCNF")
fi

# --- 1. Dump databases --------------------------------------------------------
mkdir -p "$STAGE/db"
for db in $DBS; do
  log "dumping database: $db"
  mysqldump "${MYSQL_AUTH[@]}" \
    --single-transaction --quick --routines --triggers --events \
    --default-character-set=utf8mb4 \
    --databases "$db" | gzip -6 > "$STAGE/db/${db}.sql.gz"
done

# --- 2. Config / secrets ------------------------------------------------------
mkdir -p "$STAGE/config"
for f in config/master.key config/credentials.yml.enc \
         config/database.yml config/worker.yml config/llm.yml \
         config/initializers/cafe_grader.rb; do
  if [ -e "$APP_DIR/$f" ]; then
    mkdir -p "$STAGE/$(dirname "$f")"
    cp -a "$APP_DIR/$f" "$STAGE/$f"
  fi
done

# --- 3. File assets -----------------------------------------------------------
if [ "$INCLUDE_STORAGE" = "1" ] && [ -d "$APP_DIR/storage" ]; then
  log "archiving storage/ (Active Storage)"
  tar -C "$APP_DIR" -czf "$STAGE/storage.tar.gz" storage
fi
if [ "$INCLUDE_DATA" = "1" ] && [ -d "$APP_DIR/data" ]; then
  log "archiving data/ (test_request)"
  tar -C "$APP_DIR" -czf "$STAGE/data.tar.gz" data
fi

# --- 4. Manifest + bundle -----------------------------------------------------
{
  echo "host=$HOST"; echo "timestamp=$TS"; echo "app_dir=$APP_DIR"
  echo "databases=$DBS"
  echo "include_storage=$INCLUDE_STORAGE"; echo "include_data=$INCLUDE_DATA"
} > "$STAGE/MANIFEST.txt"

log "bundling -> $ARCHIVE"
tar -C "$STAGE" -czf "$ARCHIVE" .
sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
log "size: $(du -h "$ARCHIVE" | cut -f1)"

# --- 5. Upload to OBS ---------------------------------------------------------
if [ -n "$OBS_BUCKET" ]; then
  command -v "$OBSUTIL" >/dev/null || die "obsutil not found (set OBS_BUCKET='' to skip upload)"
  dest="obs://${OBS_BUCKET}/${OBS_PREFIX}/"
  log "uploading to ${dest}"
  "$OBSUTIL" cp "$ARCHIVE"          "$dest" -f
  "$OBSUTIL" cp "${ARCHIVE}.sha256" "$dest" -f
  log "upload complete"
else
  log "OBS_BUCKET unset — keeping local copy only"
fi

# --- 6. Local retention -------------------------------------------------------
log "pruning local '${BACKUP_LABEL}' backups older than ${KEEP_LOCAL_DAYS} days"
find "$BACKUP_DIR" -maxdepth 1 -name "cafe-web_${BACKUP_LABEL}_*.tar.gz*" -mtime "+${KEEP_LOCAL_DAYS}" -print -delete || true

log "DONE"
