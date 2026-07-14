#!/bin/bash
# Cafe-Grader — Single Server installer (Ubuntu 22.04+).
# Web app + MySQL + grader workers all on one machine.
# Run as a normal user with sudo privileges (NOT root). Only manual step: sudo reboot.
#
# Usage: bash install_single_server.sh [--cloud]
#   --cloud  on AWS/GCP/Azure: use the metadata service for the public IP and
#            print security-group reminders instead of touching ufw.
set -euo pipefail

# --- config (edit before running if needed) --------------------------------
CAFE_DIR="$HOME/cafe_grader"
APP_DIR="$CAFE_DIR/web"
RUBY_VERSION="3.4.4"
DB_NAME="grader"; DB_QUEUE="grader_queue"; DB_USER="grader_user"; DB_PASS="grader_pass"
REPO_URL="https://github.com/MaxzyMVT/cafe-grader-web.git"
LINUX_USER="$USER"
CPU_CORES=$(nproc)
WORKER_COUNT=$(( CPU_CORES > 2 ? CPU_CORES - 2 : 1 ))   # CPU cores - 2, min 1

CLOUD=""
for a in "$@"; do [ "$a" = "--cloud" ] && CLOUD=1; done

source "$(cd "$(dirname "$0")" && pwd)/deploy/lib/common.sh"

echo "============================================================"
echo " Cafe-Grader Single Server Installation (Ubuntu 22.04+)${CLOUD:+  [cloud]}"
echo " CPU cores: $CPU_CORES  |  Grader workers: $WORKER_COUNT"
echo "============================================================"
cg_ram_headroom_check 1024 2048   # per-box MB, system overhead (MySQL+Rails+Apache)

cg_section "Installing system packages"
cg_purge_stale_apache_vhost
cg_apt_update_upgrade
cg_apt_install_web
cg_apt_install_compilers

cg_install_ruby
cg_mysql_single
cg_install_isolate
cg_setup_isolate_systemd
cg_patch_grub_cgroup

cg_clone_app
cg_patch_database_yml localhost
cg_patch_worker_yml "http://localhost"
cg_write_dartsass_silencer
bundle install

cg_generate_credentials
cg_python_venv
cg_db_setup_or_migrate
cg_build_assets

cg_install_passenger_apache
cg_write_solid_queue_service
cg_write_startup_service mysql
cg_write_workers_service mysql

echo
echo "============================================================"
echo " Installation complete!"
echo "============================================================"
FINAL_IP=$(cg_detect_server_ip)
echo "  Web app URL    ->  http://$FINAL_IP"
echo "  Default login  ->  root / ioionrails   (change immediately)"
[ -n "$CLOUD" ] && echo "  Cloud: open port 80 (HTTP) in your security group."
echo
echo "  ONE STEP REQUIRED:   sudo reboot"
echo "  After reboot: Apache+Passenger (port 80), Solid Queue, and"
echo "  $WORKER_COUNT grader worker(s) all start automatically."
echo
echo "  *** BACK UP $APP_DIR/config/master.key — losing it loses credentials. ***"
