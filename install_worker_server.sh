#!/bin/bash
# Cafe-Grader — Worker Node installer (Server 2 & 3, Ubuntu 22.04+).
# Builds ioi/isolate and runs grader workers that connect to the Web/DB server.
# Run as a normal user with sudo privileges (NOT root). Only manual step: sudo reboot.
#
# Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP> [WORKER_ID] [--cloud]
#   Example: bash install_worker_server.sh 10.0.0.1 1
#
# WORKER_ID identifies THIS machine to the web/db server and the watchdog; it keys
# every GraderProcess row (worker_id, box_id). Each worker SERVER MUST get a UNIQUE
# id (1, 2, 3, ...). id 0 is reserved for the Web/DB server. Two workers sharing an
# id register as the same processes and their watchdogs fight (spawn/kill thrash).
# WORKER_ID defaults to 1 (single-worker deployment).
set -euo pipefail

# --- config ---------------------------------------------------------------
CAFE_DIR="$HOME/cafe_grader"
APP_DIR="$CAFE_DIR/web"
RUBY_VERSION="3.4.4"
DB_NAME="grader"; DB_QUEUE="grader_queue"; DB_USER="grader_user"; DB_PASS="grader_pass"
REPO_URL="https://github.com/MaxzyMVT/cafe-grader-web.git"
LINUX_USER="$USER"
CPU_CORES=$(nproc)
WORKER_COUNT=$(( CPU_CORES > 2 ? CPU_CORES - 2 : 1 ))   # box_id 1..WORKER_COUNT on this node

# --- args: <IP> [ID] [--cloud] in any order --------------------------------
CLOUD=""; WEB_DB_IP=""; WORKER_ID=""
for a in "$@"; do
  case "$a" in
    --cloud) CLOUD=1 ;;
    *) if [ -z "$WEB_DB_IP" ]; then WEB_DB_IP="$a"
       elif [ -z "$WORKER_ID" ]; then WORKER_ID="$a"; fi ;;
  esac
done
WORKER_ID="${WORKER_ID:-1}"

if [ -z "$WEB_DB_IP" ]; then
  echo "ERROR: supply the Web/DB server IP as the first argument."
  echo "Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP> [WORKER_ID] [--cloud]"
  exit 1
fi
if ! [[ "$WORKER_ID" =~ ^[0-9]+$ ]] || [ "$WORKER_ID" -lt 1 ]; then
  echo "ERROR: WORKER_ID must be a positive integer (>= 1). Got: '$WORKER_ID'"
  echo "Give each worker SERVER a UNIQUE id (1, 2, 3, ...); id 0 is the Web/DB server."
  exit 1
fi

source "$(cd "$(dirname "$0")" && pwd)/deploy/lib/common.sh"

echo "============================================================"
echo " Cafe-Grader Worker Node Installation (Ubuntu 22.04+)${CLOUD:+  [cloud]}"
echo " Web/DB server IP: $WEB_DB_IP  |  worker_id: $WORKER_ID"
echo " CPU cores: $CPU_CORES  |  Grader workers (box_id 1..$WORKER_COUNT): $WORKER_COUNT"
echo "============================================================"
cg_ram_headroom_check 1024 1024   # per-box MB, system overhead (graders only; DB/web are remote)

cg_section "Installing system packages"
cg_apt_update_upgrade
cg_apt_install_worker_base
cg_apt_install_compilers

cg_install_ruby
cg_install_isolate
cg_setup_isolate_systemd
cg_patch_grub_cgroup

cg_clone_app
cg_patch_database_yml "$WEB_DB_IP"
cg_patch_worker_yml "http://$WEB_DB_IP" "$WORKER_ID"
bundle install

cg_generate_credentials
cg_python_venv
cg_write_startup_service        # no mysql on this node
cg_write_workers_service        # no mysql on this node
cg_install_isolate_cleanup_cron

# Worker nodes need no inbound ports (they dial out to the Web/DB server).
if [ -n "$CLOUD" ]; then
  echo "  Cloud: worker nodes need no inbound rules; allow outbound TCP to $WEB_DB_IP:3306."
fi

echo
echo "============================================================"
echo " Worker Node installation complete!"
echo "============================================================"
echo "  Registered as worker_id=$WORKER_ID, connecting to Web/DB at $WEB_DB_IP."
echo "  Installing ANOTHER worker server? Give it a DIFFERENT id, e.g.:"
echo "    bash install_worker_server.sh $WEB_DB_IP $((WORKER_ID + 1))${CLOUD:+ --cloud}"
echo
echo "  ONE STEP REQUIRED:   sudo reboot"
echo "  After reboot: $WORKER_COUNT grader worker(s) + the watchdog cron start automatically."
