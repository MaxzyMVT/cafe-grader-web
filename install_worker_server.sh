#!/bin/bash
# Cafe-Grader Worker Server Installation Script (Server 2 & 3, Ubuntu 22.04+)
# Fully automated — the only manual step is a final  sudo reboot.
# Run as a normal user with sudo privileges, NOT as root.
#
# Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP>
# Example: bash install_worker_server.sh 10.0.0.1

set -e

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

if [ -z "$WEB_DB_IP" ]; then
  echo "ERROR: Please supply the Web/DB server's IP address as the first argument."
  echo "Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP>"
  exit 1
fi

# Auto-detect worker count: CPU cores - 2, minimum 1
CPU_CORES=$(nproc)
WORKER_COUNT=$(( CPU_CORES > 2 ? CPU_CORES - 2 : 1 ))
LINUX_USER="$USER"
APP_DIR="$CAFE_DIR/web"

echo "============================================================"
echo " Cafe-Grader Worker Node Installation (Ubuntu 22.04+)"
echo " Web/DB server IP: $WEB_DB_IP"
echo " CPU cores: $CPU_CORES  |  Grader workers: $WORKER_COUNT"
echo "============================================================"

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
  echo "  WARNING: $ISOLATE_SVC not found — isolate.service will not be installed."
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
    sudo update-grub
    echo "  GRUB updated — takes effect after reboot."
  else
    echo "  cgroup_enable=memory already present, skipping."
  fi
else
  echo "  WARNING: /etc/default/grub not found — add cgroup_enable=memory manually."
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

# Always regenerate and patch worker.yml
cp config/worker.yml.SAMPLE config/worker.yml
sed -i "s|web:.*|web: http://$WEB_DB_IP|" config/worker.yml
echo "  worker.yml patched (web: http://$WEB_DB_IP)."

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
echo "[8/10] Generating Rails master key..."
if [ ! -f config/master.key ]; then
  cp config/credentials.yml.SAMPLE config/credentials.yml.enc
  openssl rand -hex 32 > config/master.key
  chmod 600 config/master.key
  echo "  master.key generated."
  echo "  NOTE: This key is independent from Server 1's key — credentials"
  echo "  are not shared between servers, which is fine for worker nodes."
else
  echo "  master.key already exists, skipping."
fi

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

# 9b. Grader workers — Grader.restart() spawns detached child processes
# that write to log/grader-N.txt and keep running independently.
# This service fires Grader.restart() using the absolute rbenv ruby (no
# login shell = no RVM) and then watches the log files so systemd has a
# long-running foreground process to supervise. If the workers die the
# tail exits, Restart=always re-fires Grader.restart() after 30s.
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
echo "    - $WORKER_COUNT grader worker(s)   evaluate code submissions"
echo "    - whenever crontab      runs Grader.watchdog every minute"
echo ""
echo "  Connecting to Web/DB server at: $WEB_DB_IP"
echo ""