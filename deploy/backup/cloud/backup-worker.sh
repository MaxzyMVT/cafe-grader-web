#!/usr/bin/env bash
#
# Cafe-Grader — application-level backup for a WORKER / judge VM.
#
# Workers are largely stateless — they poll Job records in the DB and grade in a
# transient sandbox (/var/local/lib/isolate is NOT backed up; it's throwaway).
# What is worth keeping:
#   - config/worker.yml      (server_key, worker_id, worker_passcode — per machine!)
#   - any custom judge scripts / language configs under the judge dir
#   - the user crontab (so the schedule itself is recoverable)
#
# This is a lightweight tarball pushed to Huawei OBS. The heavy crash-recovery
# is the CBR disk snapshot; this just makes the per-machine identity portable.
#
# Restore: see README.md "Restore — Worker".

set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG — edit per worker, or override via environment variables.
# ----------------------------------------------------------------------------
APP_DIR="${APP_DIR:-/home/grader/cafe-grader-web}"   # Rails app root (has config/worker.yml)
JUDGE_DIR="${JUDGE_DIR:-/home/grader/cafe-grader-web/../judge}"  # judge_path; '' to skip
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cafe-grader}"

# Exclude transient/regenerable judge subdirs from the archive.
JUDGE_EXCLUDES="${JUDGE_EXCLUDES:---exclude=judge/raw --exclude=judge/tmp --exclude=judge/result}"

OBS_BUCKET="${OBS_BUCKET:-}"                          # e.g. cafe-grader-backups
OBS_PREFIX="${OBS_PREFIX:-worker-$(hostname -s)}"     # per-worker path in bucket
OBSUTIL="${OBSUTIL:-obsutil}"

KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-7}"
# ----------------------------------------------------------------------------

log() { printf '%s [backup-worker] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$BACKUP_DIR"
TS="$(date +%F_%H%M%S)"
HOST="$(hostname -s)"
STAGE="$(mktemp -d "${BACKUP_DIR}/.stage.${TS}.XXXX")"
ARCHIVE="${BACKUP_DIR}/cafe-worker_${HOST}_${TS}.tar.gz"
trap 'rm -rf "$STAGE"' EXIT

# --- 1. worker config ---------------------------------------------------------
if [ -e "$APP_DIR/config/worker.yml" ]; then
  mkdir -p "$STAGE/config"
  cp -a "$APP_DIR/config/worker.yml" "$STAGE/config/worker.yml"
else
  log "WARN: $APP_DIR/config/worker.yml not found"
fi

# --- 2. judge dir (custom scripts / language config) --------------------------
if [ -n "$JUDGE_DIR" ] && [ -d "$JUDGE_DIR" ]; then
  jparent="$(cd "$JUDGE_DIR/.." && pwd)"; jname="$(basename "$JUDGE_DIR")"
  log "archiving judge dir: $JUDGE_DIR"
  # shellcheck disable=SC2086
  tar -C "$jparent" $JUDGE_EXCLUDES -czf "$STAGE/judge.tar.gz" "$jname"
fi

# --- 3. crontab ---------------------------------------------------------------
crontab -l > "$STAGE/crontab.txt" 2>/dev/null || echo "(no crontab)" > "$STAGE/crontab.txt"

# --- 4. manifest + bundle -----------------------------------------------------
{ echo "host=$HOST"; echo "timestamp=$TS"; echo "app_dir=$APP_DIR"; echo "judge_dir=$JUDGE_DIR"; } > "$STAGE/MANIFEST.txt"
log "bundling -> $ARCHIVE"
tar -C "$STAGE" -czf "$ARCHIVE" .
sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"

# --- 5. upload ----------------------------------------------------------------
if [ -n "$OBS_BUCKET" ]; then
  command -v "$OBSUTIL" >/dev/null || die "obsutil not found (set OBS_BUCKET='' to skip)"
  dest="obs://${OBS_BUCKET}/${OBS_PREFIX}/"
  log "uploading to ${dest}"
  "$OBSUTIL" cp "$ARCHIVE"          "$dest" -f
  "$OBSUTIL" cp "${ARCHIVE}.sha256" "$dest" -f
else
  log "OBS_BUCKET unset — keeping local copy only"
fi

# --- 6. retention -------------------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 -name 'cafe-worker_*.tar.gz*' -mtime "+${KEEP_LOCAL_DAYS}" -print -delete || true
log "DONE"
