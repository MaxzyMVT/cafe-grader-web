#!/bin/bash
# Cafe-Grader Worker Server Installation Script (Server 2 & 3, Ubuntu 22.04+)
# Run as a normal user with sudo privileges, NOT as root.
# Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP>
#
# Example: bash install_worker_server.sh 10.0.0.1

set -e

CAFE_DIR="$HOME/cafe_grader"
RUBY_VERSION="3.4.4"
WEB_DB_IP="${1:-}"

if [ -z "$WEB_DB_IP" ]; then
  echo "ERROR: Please supply the Web/DB server's IP address as the first argument."
  echo "Usage: bash install_worker_server.sh <WEB_DB_SERVER_IP>"
  exit 1
fi

echo "============================================================"
echo " Cafe-Grader Worker Node Installation (Ubuntu 22.04+)"
echo " Web/DB server IP: $WEB_DB_IP"
echo "============================================================"

# ---------------------------------------------------------------
# 1. System updates — compilers and tools only (no Apache/Node)
# ---------------------------------------------------------------
echo "[1/6] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  git software-properties-common \
  libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
  curl unzip

# Language compilers / runtimes
sudo apt install -y \
  ghc g++ openjdk-21-jdk fpc \
  php-cli php-readline \
  golang-go cargo python3-venv

# ---------------------------------------------------------------
# 2. Install Ruby via rbenv
# ---------------------------------------------------------------
echo "[2/6] Installing rbenv and Ruby $RUBY_VERSION..."
sudo apt install -y \
  git curl libssl-dev libreadline-dev zlib1g-dev \
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
gem install bundler --no-document

# ---------------------------------------------------------------
# 3. Install ioi/isolate
# ---------------------------------------------------------------
echo "[3/6] Installing ioi/isolate..."
if [ ! -d "/tmp/isolate" ]; then
  git clone https://github.com/ioi/isolate.git /tmp/isolate
fi
cd /tmp/isolate
make isolate
sudo make install

# Disable swap (required for reproducible isolate results)
echo "  Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ---------------------------------------------------------------
# 4. Configure systemd services for isolate kernel parameters
# ---------------------------------------------------------------
echo "[4/6] Configuring systemd services for isolate..."

# Link isolate's cgroup-watching service if available
ISOLATE_SVC="/tmp/isolate/systemd/isolate.service"
if [ -f "$ISOLATE_SVC" ]; then
  sudo ln -sf "$ISOLATE_SVC" /etc/systemd/system/isolate.service
fi

# Service to set transparent hugepage + core pattern at boot
sudo tee /etc/systemd/system/set-ioi-isolate.service > /dev/null <<'EOF'
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
EOF

# Disable address space randomization persistently
if ! grep -q "kernel.randomize_va_space" /etc/sysctl.d/99-sysctl.conf 2>/dev/null; then
  echo "# IOI isolate" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
  echo "kernel.randomize_va_space=0" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
fi

sudo systemctl daemon-reload
sudo systemctl enable set-ioi-isolate.service
[ -f /etc/systemd/system/isolate.service ] && sudo systemctl enable isolate.service

# ---------------------------------------------------------------
# 5. Clone Cafe-Grader and point it at the remote database
# ---------------------------------------------------------------
echo "[5/6] Setting up Cafe-Grader app (worker mode)..."
mkdir -p "$CAFE_DIR"
cd "$CAFE_DIR"
if [ ! -d "web" ]; then
  git clone https://github.com/MaxzyMVT/cafe-grader-web.git web
fi
cd web

# Initialise config files from samples
[ ! -f config/application.rb ] && cp config/application.rb.SAMPLE config/application.rb
[ ! -f config/llm.yml ]        && cp config/llm.yml.SAMPLE        config/llm.yml
[ ! -f config/worker.yml ]     && cp config/worker.yml.SAMPLE     config/worker.yml

# Generate database.yml pointing to the remote Web/DB server
cp config/database.yml.SAMPLE config/database.yml
sed -i "s/host: localhost/host: $WEB_DB_IP/" config/database.yml
echo "  config/database.yml updated: host set to $WEB_DB_IP"

bundle install

# ---------------------------------------------------------------
# 6. Print remaining manual steps
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Worker Node script complete! Manual steps remaining:"
echo "============================================================"
echo ""
echo "STEP A — Verify config/database.yml:"
echo "  host:     $WEB_DB_IP"
echo "  database: grader"
echo "  username: grader_user"
echo "  password: grader_pass"
echo "  (Update password if you changed the default on Server 1.)"
echo ""
echo "STEP B — Verify config/worker.yml:"
echo "  Set the 'web:' key to the URL of Server 1 (e.g. http://10.0.0.1)."
echo ""
echo "STEP C — Enable memory cgroups in GRUB (required for isolate):"
echo "  sudo vi /etc/default/grub"
echo "  # Add cgroup_enable=memory to GRUB_CMDLINE_LINUX_DEFAULT, e.g.:"
echo "  #   GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash cgroup_enable=memory\""
echo "  sudo update-grub"
echo ""
echo "STEP D — Reboot to apply kernel and swap changes:"
echo "  sudo reboot"
echo ""
echo "STEP E — After reboot, start grader workers:"
echo "  cd $CAFE_DIR/web"
echo "  RAILS_ENV=production bundle exec rails r \"Grader.restart(4)\""
echo "  bundle exec whenever --update-crontab"
echo ""
echo "  Adjust the worker count (4) to #CPU_cores - 2 for this machine."
echo ""
echo "NOTE: The directory ~/cafe_grader/judge/isolate_submission will grow"
echo "  over time. Add a cron job to clean it up periodically, e.g.:"
echo "  0 2 * * * find $CAFE_DIR/judge/isolate_submission/ -maxdepth 1 -mtime +1 -exec rm -rf {} \\;"