#!/bin/bash
# Cafe-Grader Single Server Installation Script (Ubuntu 22.04+)
# Run as a normal user with sudo privileges, NOT as root.
# Usage: bash install_single_server.sh

set -e

CAFE_DIR="$HOME/cafe_grader"
RUBY_VERSION="3.4.4"
DB_NAME="grader"
DB_QUEUE="grader_queue"
DB_USER="grader_user"
DB_PASS="grader_pass"

echo "============================================================"
echo " Cafe-Grader Single Server Installation (Ubuntu 22.04+)"
echo "============================================================"

# ---------------------------------------------------------------
# 1. System updates and packages
# ---------------------------------------------------------------
echo "[1/8] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  apache2 apache2-dev \
  mysql-server git software-properties-common \
  libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
  apt-transport-https \
  postgresql postgresql-server-dev-all \
  unzip curl

# Language compilers / runtimes
sudo apt install -y \
  ghc g++ openjdk-21-jdk fpc \
  php-cli php-readline \
  golang-go cargo python3-venv

# ---------------------------------------------------------------
# 2. Install Ruby via rbenv (replaces RVM)
# ---------------------------------------------------------------
echo "[2/8] Installing rbenv and Ruby $RUBY_VERSION..."
sudo apt install -y \
  git curl libssl-dev libreadline-dev zlib1g-dev \
  autoconf bison build-essential libyaml-dev \
  libncurses5-dev libffi-dev libgdbm-dev

if [ ! -d "$HOME/.rbenv" ]; then
  curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash
fi

# Add rbenv to PATH for this session and future sessions
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
# 3. MySQL Setup
# ---------------------------------------------------------------
echo "[3/8] Setting up MySQL databases and user..."
sudo systemctl start mysql || sudo service mysql start
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_QUEUE\`;"
sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

# ---------------------------------------------------------------
# 4. Install ioi/isolate (sandboxing)
# ---------------------------------------------------------------
echo "[4/8] Installing ioi/isolate..."
if [ ! -d "/tmp/isolate" ]; then
  git clone https://github.com/ioi/isolate.git /tmp/isolate
fi
cd /tmp/isolate
make isolate
sudo make install

# Disable swap (required by isolate for reproducible results)
echo "  Disabling swap..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ---------------------------------------------------------------
# 5. Setup systemd services for isolate kernel parameters
# ---------------------------------------------------------------
echo "[5/8] Configuring systemd services for isolate..."

# 5a. Link isolate's own cgroup-watching service
ISOLATE_SRC="/tmp/isolate/systemd/isolate.service"
if [ -f "$ISOLATE_SRC" ]; then
  sudo ln -sf "$ISOLATE_SRC" /etc/systemd/system/isolate.service
fi

# 5b. Service to set transparent hugepage + core pattern at boot
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

# 5c. Disable address space randomization persistently
if ! grep -q "kernel.randomize_va_space" /etc/sysctl.d/99-sysctl.conf 2>/dev/null; then
  echo "# IOI isolate" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
  echo "kernel.randomize_va_space=0" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
fi

sudo systemctl daemon-reload
sudo systemctl enable set-ioi-isolate.service
[ -f /etc/systemd/system/isolate.service ] && sudo systemctl enable isolate.service

# ---------------------------------------------------------------
# 6. Clone and configure Cafe-Grader web app
# ---------------------------------------------------------------
echo "[6/8] Setting up Cafe-Grader web app..."
mkdir -p "$CAFE_DIR"
cd "$CAFE_DIR"
if [ ! -d "web" ]; then
  git clone https://github.com/MaxzyMVT/cafe-grader-web.git web
fi
cd web

# Initialise config files from samples (required for Rails to boot)
[ ! -f config/application.rb ] && cp config/application.rb.SAMPLE config/application.rb
[ ! -f config/database.yml ]   && cp config/database.yml.SAMPLE   config/database.yml
[ ! -f config/llm.yml ]        && cp config/llm.yml.SAMPLE        config/llm.yml
[ ! -f config/worker.yml ]     && cp config/worker.yml.SAMPLE     config/worker.yml

bundle install

# ---------------------------------------------------------------
# 7. Setup systemd service for Solid Queue
# ---------------------------------------------------------------
echo "[7/8] Installing Solid Queue systemd service..."
LINUX_USER="$USER"
APP_DIR="$CAFE_DIR/web"

sudo tee /etc/systemd/system/solid_queue.service > /dev/null <<EOF
[Unit]
Description=Solid Queue for Cafe-Grader
After=network.target mysql.service
Wants=mysql.service

[Service]
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash -lc 'bundle exec rails solid_queue:start'
Environment=RAILS_ENV=production
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable solid_queue.service

# ---------------------------------------------------------------
# 8. Print remaining manual steps
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Installation script complete! Manual steps remaining:"
echo "============================================================"
echo ""
echo "STEP A — Set admin password (do this BEFORE db:setup):"
echo "  export GRADER_ADMIN_PASSWORD='your_secure_password_here'"
echo ""
echo "STEP B — Create Rails master key:"
echo "  cd $APP_DIR"
echo "  export EDITOR=nano"
echo "  bundle exec rails credentials:edit"
echo ""
echo "STEP C — Update config/database.yml with DB credentials:"
echo "  host:     localhost"
echo "  database: $DB_NAME"
echo "  username: $DB_USER"
echo "  password: $DB_PASS"
echo ""
echo "STEP D — Initialise the database and precompile assets:"
echo "  bundle exec rails db:setup DISABLE_DATABASE_ENVIRONMENT_CHECK=1 RAILS_ENV=production"
echo "  bundle exec rails db:seed RAILS_ENV=production"
echo "  bundle exec rails dartsass:build RAILS_ENV=production"
echo "  bundle exec rails assets:precompile RAILS_ENV=production"
echo ""
echo "STEP E — Enable memory cgroups in GRUB (required for isolate):"
echo "  sudo vi /etc/default/grub"
echo "  # Add cgroup_enable=memory to GRUB_CMDLINE_LINUX_DEFAULT, e.g.:"
echo "  #   GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash cgroup_enable=memory\""
echo "  sudo update-grub"
echo ""
echo "STEP F — Reboot to apply kernel and swap changes:"
echo "  sudo reboot"
echo ""
echo "STEP G — After reboot, start grader workers:"
echo "  cd $APP_DIR"
echo "  RAILS_ENV=production bundle exec rails r \"Grader.restart(4)\""
echo "  bundle exec whenever --update-crontab"
echo ""
echo "STEP H — Configure Apache + Phusion Passenger:"
echo "  Follow https://www.phusionpassenger.com/docs/tutorials/deploy_to_production/"
echo "  DocumentRoot: $APP_DIR/public"
echo ""
echo "STEP I — Start Solid Queue service:"
echo "  sudo systemctl start solid_queue.service"
echo ""
echo "Default login: username=root, password=<value of GRADER_ADMIN_PASSWORD>"