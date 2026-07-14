#!/bin/bash
# Cafe-Grader Worker Server Installation Script (Server 2 & 3, Ubuntu 22.04+)
# Fully automated — the only manual step is a final  sudo reboot.
# Run as a normal user with sudo privileges, NOT as root.
#
# Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP> [WORKER_ID]
# Example: bash install_worker_server.sh 10.0.0.1 1
#
# WORKER_ID identifies THIS worker machine to the web/db server and the watchdog.
# It is written into worker.yml and keys every GraderProcess row (worker_id, box_id).
# Each separate worker SERVER MUST get a UNIQUE id (1, 2, 3, ...). worker_id 0 is
# reserved for the Web/DB server. If two workers share an id they register as the
# same processes and their watchdogs fight (spawn/kill thrash). WORKER_ID defaults
# to 1 for a single-worker deployment.

# -e: abort on error  -u: error on unset var  -o pipefail: a pipe fails if any stage fails.
# WEB_DB_IP / WORKER_ID are read as ${1:-}/${2:-} below so -u doesn't trip on a missing arg.
set -euo pipefail

# ---------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------
CAFE_DIR="$HOME/cafe_grader"
RUBY_VERSION="3.4.4"
DB_NAME="grader"
DB_USER="grader_user"
DB_PASS="grader_pass"
REPO_URL="https://github.com/MaxzyMVT/cafe-grader-web.git"
WEB_DB_IP="${1:-}"
WORKER_ID="${2:-1}"

if [ -z "$WEB_DB_IP" ]; then
  echo "ERROR: Please supply the Web/DB server's IP address as the first argument."
  echo "Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP> [WORKER_ID]"
  exit 1
fi

# WORKER_ID must be a positive integer and unique across worker servers.
# 0 is reserved for the Web/DB server, so reject it here.
if ! [[ "$WORKER_ID" =~ ^[0-9]+$ ]] || [ "$WORKER_ID" -lt 1 ]; then
  echo "ERROR: WORKER_ID must be a positive integer (>= 1). Got: '$WORKER_ID'"
  echo "Give each worker SERVER a UNIQUE id (1, 2, 3, ...); id 0 is the Web/DB server."
  exit 1
fi

# Auto-detect worker count: CPU cores - 2, minimum 1
CPU_CORES=$(nproc)
WORKER_COUNT=$(( CPU_CORES > 2 ? CPU_CORES - 2 : 1 ))
LINUX_USER="$USER"
APP_DIR="$CAFE_DIR/web"

# ---------------------------------------------------------------
# Cloud compatibility helpers
# ---------------------------------------------------------------
ufw_allow_if_active() {
  local port="$1"
  if sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
    sudo ufw allow "${port}/tcp"
    echo "  ufw: opened port $port/tcp."
  else
    echo "  ufw inactive — skipping ufw rule for port $port."
    echo "  Cloud users: open port $port in your security group / firewall rules."
  fi
}

echo "============================================================"
echo " Cafe-Grader Worker Node Installation (Ubuntu 22.04+)"
echo " Web/DB server IP: $WEB_DB_IP  |  worker_id: $WORKER_ID"
echo " CPU cores: $CPU_CORES  |  Grader workers (box_id 1..$WORKER_COUNT): $WORKER_COUNT"
echo "============================================================"

# ---------------------------------------------------------------
# RAM headroom check (advisory)
# ---------------------------------------------------------------
# Swap is disabled later (isolate needs a hard RAM cap). With no swap cushion the
# host must physically fit every concurrent sandbox PLUS the base system, or the
# OOM killer strikes — possibly a grader, not just the offending box.
# Estimate peak = WORKER_COUNT boxes * per-box budget + base-system overhead.
# (Worker nodes have no local MySQL/Apache, so overhead is lower than single-server.)
PER_BOX_MB=1024        # generous per-submission budget (dataset memory_limit default 512)
SYS_OVERHEAD_MB=1024   # Ruby graders only (DB + web live on the Web/DB server)
RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)
RAM_MB=$(( ${RAM_KB:-0} / 1024 ))
NEED_MB=$(( WORKER_COUNT * PER_BOX_MB + SYS_OVERHEAD_MB ))
if [ "$RAM_MB" -eq 0 ]; then
  echo "  (could not read /proc/meminfo — skipping RAM headroom check)"
elif [ "$RAM_MB" -lt "$NEED_MB" ]; then
  echo "  ####################################################################"
  echo "  # WARNING: low RAM for $WORKER_COUNT grader worker(s) with swap disabled."
  echo "  #   physical RAM : ${RAM_MB} MB"
  echo "  #   recommended  : ${NEED_MB} MB  (${WORKER_COUNT} x ${PER_BOX_MB}MB boxes + ${SYS_OVERHEAD_MB}MB system)"
  echo "  # Without swap the OOM killer may kill a grader under load."
  echo "  # Mitigate: add RAM, lower WORKER_COUNT near the top of this script,"
  echo "  # or cap each problem's memory_limit. Continuing anyway."
  echo "  ####################################################################"
else
  echo "  RAM check OK: ${RAM_MB} MB >= ${NEED_MB} MB recommended for $WORKER_COUNT worker(s)."
fi

# ---------------------------------------------------------------
# 1. System packages (compilers only — no Apache or MySQL)
# ---------------------------------------------------------------
echo "[1/10] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  git software-properties-common \
  libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
  openssl curl unzip

# Language compilers / runtimes
sudo apt install -y \
  ghc g++ openjdk-21-jdk fpc \
  php-cli php-readline \
  golang-go cargo python3-venv

# ---------------------------------------------------------------
# 2. Ruby via rbenv
# ---------------------------------------------------------------
echo "[2/10] Installing rbenv and Ruby $RUBY_VERSION..."
sudo apt install -y \
  curl libssl-dev libreadline-dev zlib1g-dev \
  autoconf bison build-essential libyaml-dev \
  libncurses5-dev libffi-dev libgdbm-dev

if [ ! -d "$HOME/.rbenv" ]; then
  curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash
fi

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init -)"

grep -qxF 'export PATH="$HOME/.rbenv/bin:$PATH"' ~/.bashrc || \
  echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
grep -qxF 'eval "$(rbenv init -)"' ~/.bashrc || \
  echo 'eval "$(rbenv init -)"' >> ~/.bashrc

rbenv install -s "$RUBY_VERSION"
rbenv global "$RUBY_VERSION"

# Remove stale system-level gem stubs that conflict with rbenv-managed Ruby.
if [ -d "$HOME/.gem/ruby" ]; then
  rm -rf "$HOME/.gem/ruby"
fi

gem install bundler --no-document

# ---------------------------------------------------------------
# 3. ioi/isolate
# ---------------------------------------------------------------
echo "[3/10] Building and installing ioi/isolate..."

# Clone into a permanent location (NOT /tmp — it is wiped on reboot,
# which breaks the isolate.service symlink and /run/isolate/cgroup).
ISOLATE_SRC_DIR="$HOME/isolate"
if [ ! -d "$ISOLATE_SRC_DIR" ]; then
  git clone https://github.com/ioi/isolate.git "$ISOLATE_SRC_DIR"
fi
cd "$ISOLATE_SRC_DIR"
make isolate
sudo make install

# Create the isolate system user required by ioi/isolate (v2.5+).
# isolate's default.cf sets  subid_user = isolate  which means it reads
# /etc/subuid and /etc/subgid to find the UID/GID block for sandboxes.
# Without the user + subuid/subgid entries every isolate --init call dies with
# "User isolate not found in /etc/subuid", which makes workers crash silently
# and appear forever idle with no heartbeat.
#
# Range choice: Ubuntu 22.04 pre-assigns 100000:65536 to the default "ubuntu"
# user (and often to the install user too).  Using the same range causes a
# silent UID collision inside user namespaces.  We use 200000:65536 which is
# safely above all default Ubuntu allocations.
if ! id isolate &>/dev/null; then
  sudo useradd --system --no-create-home --shell /usr/sbin/nologin isolate
  echo "  Created system user 'isolate'."
else
  echo "  System user 'isolate' already exists."
fi

# Add subuid/subgid entries only if not already present
if ! grep -q "^isolate:" /etc/subuid; then
  echo "isolate:200000:65536" | sudo tee -a /etc/subuid
  echo "  Added /etc/subuid entry: isolate:200000:65536"
else
  echo "  /etc/subuid entry for 'isolate' already exists."
fi
if ! grep -q "^isolate:" /etc/subgid; then
  echo "isolate:200000:65536" | sudo tee -a /etc/subgid
  echo "  Added /etc/subgid entry: isolate:200000:65536"
else
  echo "  /etc/subgid entry for 'isolate' already exists."
fi

echo "  Disabling swap (required by isolate)..."
sudo swapoff -a
# Comment out swap line in /etc/fstab (handles both /swap.img and partition entries)
sudo sed -i '/\sswap\s/ s/^\(.*\)$/#\1/' /etc/fstab
# Also remove the swap file itself if it exists
[ -f /swap.img ] && sudo rm -f /swap.img

# ---------------------------------------------------------------
# 4. Isolate systemd services + kernel settings
# ---------------------------------------------------------------
echo "[4/10] Configuring isolate kernel settings..."

# Symlink isolate's own service from its permanent source location.
# Using a symlink (not a copy) so it stays in sync if isolate is updated.
# Must point to the permanent clone dir — /tmp is cleared on reboot.
ISOLATE_SVC="$ISOLATE_SRC_DIR/systemd/isolate.service"
if [ -f "$ISOLATE_SVC" ]; then
  sudo ln -sf "$ISOLATE_SVC" /etc/systemd/system/isolate.service
  echo "  isolate.service symlinked from $ISOLATE_SVC"
else
  echo "  ####################################################################"
  echo "  # WARNING: $ISOLATE_SVC not found."
  echo "  # isolate.service was NOT installed. Grading workers CANNOT sandbox"
  echo "  # submissions without it — they will sit idle with no heartbeat."
  echo "  # Fix before relying on grading: reinstall ioi/isolate, then"
  echo "  #   sudo ln -sf <isolate>/systemd/isolate.service /etc/systemd/system/"
  echo "  #   sudo systemctl enable --now isolate.service"
  echo "  ####################################################################"
fi

sudo tee /etc/systemd/system/set-ioi-isolate.service > /dev/null <<'SVCEOF'
[Unit]
Description=Set Transparent Hugepage and Core Pattern Settings for IOI isolate
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled; \
                      echo never > /sys/kernel/mm/transparent_hugepage/defrag; \
                      echo 0 > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag; \
                      echo core > /proc/sys/kernel/core_pattern;"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

if ! grep -q "kernel.randomize_va_space" /etc/sysctl.d/99-sysctl.conf 2>/dev/null; then
  echo "# IOI isolate" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
  echo "kernel.randomize_va_space=0" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
fi

sudo systemctl daemon-reload
sudo systemctl enable set-ioi-isolate.service
[ -f /etc/systemd/system/isolate.service ] && sudo systemctl enable isolate.service

# ---------------------------------------------------------------
# 5. GRUB: enable cgroup memory support (required for isolate)
# ---------------------------------------------------------------
echo "[5/10] Patching GRUB for cgroup_enable=memory..."
if [ -f /etc/default/grub ]; then
  if ! grep -q "cgroup_enable=memory" /etc/default/grub; then
    sudo sed -i \
      's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 cgroup_enable=memory swapaccount=1"/' \
      /etc/default/grub
    sudo sed -i \
      's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 cgroup_enable=memory swapaccount=1"/' \
      /etc/default/grub
    if command -v update-grub &>/dev/null; then
      sudo update-grub
    elif command -v grub2-mkconfig &>/dev/null; then
      sudo grub2-mkconfig -o /boot/grub2/grub.cfg
    else
      sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
    echo "  GRUB updated — takes effect after reboot."
  else
    echo "  cgroup_enable=memory already present, skipping."
  fi
else
  echo "  WARNING: /etc/default/grub not found — cgroup_enable=memory must be set manually."
fi

# ---------------------------------------------------------------
# 6. Cafe-Grader app: clone + configure for remote DB
# ---------------------------------------------------------------
echo "[6/10] Cloning and configuring Cafe-Grader (worker mode)..."
mkdir -p "$CAFE_DIR"
cd "$CAFE_DIR"
if [ ! -d "web" ]; then
  git clone "$REPO_URL" web
fi
cd web

# Copy sample configs
[ ! -f config/application.rb ] && cp config/application.rb.SAMPLE config/application.rb
[ ! -f config/llm.yml ]        && cp config/llm.yml.SAMPLE        config/llm.yml

# Always regenerate and patch database.yml.
# Patch all credential fields AND set host to the remote Web/DB server.
cp config/database.yml.SAMPLE config/database.yml
sed -i "s/username:.*/username: $DB_USER/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/host:.*/host: $WEB_DB_IP/"       config/database.yml
echo "  database.yml patched — host: $WEB_DB_IP, user: $DB_USER."

# Always regenerate and patch worker.yml.
# worker_id keys this machine's GraderProcess rows and scopes the watchdog — it MUST
# be unique per worker server (sed patches both the development and production blocks).
# server_key / worker_passcode are left as-is: they are the shared secrets that
# authenticate every worker to the same Web/DB server.
cp config/worker.yml.SAMPLE config/worker.yml
sed -i "s|web:.*|web: http://$WEB_DB_IP|" config/worker.yml
sed -i "s|worker_id:.*|worker_id: $WORKER_ID|" config/worker.yml
echo "  worker.yml patched (web: http://$WEB_DB_IP, worker_id: $WORKER_ID)."

bundle install

# ---------------------------------------------------------------
# 7. Python venv for grader engine
# ---------------------------------------------------------------
echo "[7/10] Creating Python venv at /venv/grader..."
if [ ! -d "/venv/grader" ]; then
  sudo python3 -m venv /venv/grader
  sudo /venv/grader/bin/pip install --upgrade pip --quiet
  echo "  Python venv ready."
else
  echo "  /venv/grader already exists, skipping."
fi

# ---------------------------------------------------------------
# 8. Rails master key + credentials (needed to boot Rails runner)
# ---------------------------------------------------------------
echo "[8/10] Generating Rails master key and credentials..."

# Remove any stale/mismatched key+credentials pair. Copying credentials.yml.SAMPLE
# alongside a fresh `openssl rand` master.key produces a MISMATCH — the SAMPLE was
# encrypted with a different key, so it cannot be decrypted. That crashes the Rails
# runner (and every boot) with:
#   ActiveSupport::MessageEncryptor::InvalidMessage: missing separator
# because Rails decrypts credentials during environment load (config/environment.rb:5).
# Generate a MATCHED key+credentials pair from scratch via `credentials:edit`;
# EDITOR=true completes it non-interactively.
rm -f config/master.key config/credentials.yml.enc

EDITOR=true bundle exec rails credentials:edit
chmod 600 config/master.key
echo "  master.key and credentials.yml.enc generated (matched pair)."
echo "  NOTE: This key is independent from Server 1's key — credentials"
echo "  are not shared between servers, which is fine for worker nodes."

# ---------------------------------------------------------------
# 9. Grader workers + whenever crontab as systemd services
# ---------------------------------------------------------------
echo "[9/10] Installing grader services..."

# Resolve absolute paths at install time — written into the unit file so
# systemd never goes through bash login shells (which load RVM and override
# our rbenv ruby).
RBENV_BUNDLE_BIN="$(rbenv which bundle)"

# 9a. Oneshot — updates the whenever crontab only.
sudo tee /etc/systemd/system/cafe_grader_startup.service > /dev/null <<EOF
[Unit]
Description=Update Cafe-Grader whenever crontab after reboot
After=network.target

[Service]
Type=oneshot
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=$RBENV_BUNDLE_BIN exec whenever --update-crontab
Environment=RAILS_ENV=production
Environment=PATH=$HOME/.rbenv/shims:$HOME/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 9b. Grader workers — Grader.restart(N) spawns N detached child processes
# that write to log/grader-N.txt, keep running independently, then returns.
# Type=simple + RemainAfterExit=yes: systemd runs this one-shot restart command
# via the absolute rbenv bundle (no login shell = no RVM interference) and then
# treats the service as "active" after it exits. There is intentionally NO
# Restart= directive — re-firing Grader.restart() would spawn duplicate workers;
# dead workers are respawned by Grader.watchdog, run each minute by the whenever cron.
sudo tee /etc/systemd/system/cafe_grader_workers.service > /dev/null <<EOF
[Unit]
Description=Cafe-Grader grader workers
After=network.target cafe_grader_startup.service

[Service]
Type=simple
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=$RBENV_BUNDLE_BIN exec rails runner "Grader.restart($WORKER_COUNT)"
Environment=RAILS_ENV=production
Environment=PATH=$HOME/.rbenv/shims:$HOME/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Grader.restart() returns immediately after spawning workers.
# RemainAfterExit lets systemd treat the service as "active" after that.
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cafe_grader_startup.service
sudo systemctl enable cafe_grader_workers.service

# ---------------------------------------------------------------
# 10. Isolate submission cleanup cron job
# ---------------------------------------------------------------
echo "[10/10] Installing isolate_submission cleanup cron job..."
CRON_JOB="0 2 * * * find $CAFE_DIR/judge/isolate_submission/ -maxdepth 1 -mtime +1 -exec rm -rf {} \; 2>/dev/null"
# Add only if not already present
( crontab -l 2>/dev/null | grep -qF "isolate_submission" ) || \
  ( crontab -l 2>/dev/null; echo "$CRON_JOB" ) | crontab -
echo "  Cleanup cron job installed (runs daily at 02:00)."

# Worker nodes need no inbound ports open (they initiate outbound connections
# to the Web/DB server). Only open if ufw is active to avoid blocking outbound.
# Remind cloud users that the security group needs no inbound rules for workers.
if sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
  echo "  ufw is active — no inbound port rules needed for worker nodes."
else
  echo "  Cloud users: worker nodes need no inbound security group rules."
  echo "  Ensure outbound TCP to $WEB_DB_IP:3306 is allowed."
fi

# ---------------------------------------------------------------
# Done
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Worker Node installation complete!"
echo "============================================================"
echo ""
echo "  ONE STEP REQUIRED:"
echo ""
echo "    sudo reboot"
echo ""
echo "  After reboot everything starts automatically:"
echo "    - $WORKER_COUNT grader worker(s)   evaluate code submissions (worker_id $WORKER_ID, box_id 1..$WORKER_COUNT)"
echo "    - whenever crontab      runs Grader.watchdog every minute"
echo ""
echo "  Connecting to Web/DB server at: $WEB_DB_IP"
echo "  This worker registered as worker_id=$WORKER_ID."
echo "  Installing ANOTHER worker server? Give it a DIFFERENT id, e.g.:"
echo "    bash install_worker_server.sh $WEB_DB_IP $((WORKER_ID + 1))"
echo "  Cloud users: ensure outbound TCP to $WEB_DB_IP:3306 is not blocked."
echo ""