#!/bin/bash
# Cafe-Grader — Web/DB Server installer (Server 1 of 3, Ubuntu 22.04+).
# Hosts the Rails web app + MySQL. Worker nodes connect here for the DB.
# Runs NO grader workers and NO isolate (isolate_path blanked in worker.yml).
# Run as a normal user with sudo privileges (NOT root). Only manual step: sudo reboot.
#
# Usage: bash install_web_db_server.sh [--cloud]
set -euo pipefail

# --- config ---------------------------------------------------------------
CAFE_DIR="$HOME/cafe_grader"
APP_DIR="$CAFE_DIR/web"
RUBY_VERSION="3.4.4"
DB_NAME="grader"; DB_QUEUE="grader_queue"; DB_USER="grader_user"; DB_PASS="grader_pass"
REPO_URL="https://github.com/MaxzyMVT/cafe-grader-web.git"
LINUX_USER="$USER"
WORKER_COUNT=0   # this node runs no grader workers

CLOUD=""
for a in "$@"; do [ "$a" = "--cloud" ] && CLOUD=1; done

source "$(cd "$(dirname "$0")" && pwd)/deploy/lib/common.sh"

echo "============================================================"
echo " Cafe-Grader Web/DB Server Installation (Ubuntu 22.04+)${CLOUD:+  [cloud]}"
echo "============================================================"

cg_section "Installing system packages"
cg_purge_stale_apache_vhost
cg_apt_update_upgrade
cg_apt_install_web

cg_install_ruby
cg_mysql_webdb

cg_clone_app
cg_patch_database_yml localhost
cg_patch_worker_yml "http://localhost" "" disable_isolate
cg_write_dartsass_silencer
bundle install

cg_generate_credentials
cg_db_setup_or_migrate
cg_build_assets

cg_install_passenger_apache
cg_ufw_allow_if_active 3306   # workers reach MySQL here
cg_write_solid_queue_service
cg_write_startup_service mysql

echo
echo "============================================================"
echo " Web/DB Server installation complete!"
echo "============================================================"
FINAL_IP=$(cg_detect_server_ip)
echo "  Web app URL    ->  http://$FINAL_IP"
echo "  Default login  ->  root / ioionrails   (change immediately)"
[ -n "$CLOUD" ] && echo "  Cloud: open port 80 (HTTP) and 3306 (MySQL, worker IPs only)."
echo
echo "  This server's IP for worker setup: $FINAL_IP"
echo "  Run on each worker with a UNIQUE worker id (1, 2, 3, ...):"
echo "    worker 1:  bash install_worker_server.sh $FINAL_IP 1"
echo "    worker 2:  bash install_worker_server.sh $FINAL_IP 2"
echo "  (Reusing an id makes two workers collide and thrash the watchdog.)"
echo
echo "  ONE STEP REQUIRED:   sudo reboot   (Apache + Solid Queue start on boot)"
echo "  *** BACK UP $APP_DIR/config/master.key — losing it loses credentials. ***"
