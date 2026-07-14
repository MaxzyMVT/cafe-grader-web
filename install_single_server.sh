#!/bin/bash
# Cafe-Grader Single Server Installation Script (Ubuntu 22.04+)
# Fully automated — the only manual step is a final  sudo reboot.
# Run as a normal user with sudo privileges, NOT as root.
#
# Usage: bash install_single_server.sh

# -e: abort on error  -u: error on unset var  -o pipefail: a pipe fails if any stage fails.
# NOTE: command substitutions that end in `| head`/`| grep` and are validated by a
# later `[ -z ... ]` check are guarded with `|| true` so pipefail doesn't abort on the
# expected non-zero (no match / SIGPIPE from head closing the pipe early).
set -euo pipefail

# ---------------------------------------------------------------
# Configuration — edit before running if needed
# ---------------------------------------------------------------
CAFE_DIR="$HOME/cafe_grader"
RUBY_VERSION="3.4.4"
DB_NAME="grader"
DB_QUEUE="grader_queue"
DB_USER="grader_user"
DB_PASS="grader_pass"
REPO_URL="https://github.com/MaxzyMVT/cafe-grader-web.git"

# Auto-detect worker count: CPU cores - 2, minimum 1
CPU_CORES=$(nproc)
WORKER_COUNT=$(( CPU_CORES > 2 ? CPU_CORES - 2 : 1 ))
LINUX_USER="$USER"
APP_DIR="$CAFE_DIR/web"

echo "============================================================"
echo " Cafe-Grader Single Server Installation (Ubuntu 22.04+)"
echo " CPU cores: $CPU_CORES  |  Grader workers: $WORKER_COUNT"
echo "============================================================"

# ---------------------------------------------------------------
# RAM headroom check (advisory)
# ---------------------------------------------------------------
# Swap is disabled later (isolate needs a hard RAM cap). With no swap cushion the
# host must physically fit every concurrent sandbox PLUS the base system, or the
# OOM killer strikes — possibly MySQL or a grader, not just the offending box.
# Estimate peak = WORKER_COUNT boxes * per-box budget + base-system overhead.
PER_BOX_MB=1024        # generous per-submission budget (dataset memory_limit default 512)
SYS_OVERHEAD_MB=2048   # MySQL + Rails + Apache co-located on this single server
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
  echo "  # Without swap the OOM killer may kill MySQL or a grader under load."
  echo "  # Mitigate: add RAM, lower WORKER_COUNT near the top of this script,"
  echo "  # or cap each problem's memory_limit. Continuing anyway."
  echo "  ####################################################################"
else
  echo "  RAM check OK: ${RAM_MB} MB >= ${NEED_MB} MB recommended for $WORKER_COUNT worker(s)."
fi

# ---------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------
echo "[1/13] Installing system dependencies..."

# Remove any stale cafe_grader Apache vhost left over from a previous install.
# If the app directory was deleted between runs, the old vhost still points to the
# missing DocumentRoot. When apt upgrade reconfigures the apache2 package it runs
# apache2ctl internally — with a broken config this fails immediately, causing
# `set -e` to abort the entire script right after the apt commands.
if [ -f /etc/apache2/sites-enabled/cafe_grader.conf ] || \
   [ -f /etc/apache2/sites-available/cafe_grader.conf ]; then
  echo "  Removing stale Apache vhost config from previous install..."
  sudo a2dissite cafe_grader 2>/dev/null || true
  sudo rm -f /etc/apache2/sites-available/cafe_grader.conf
  sudo rm -f /etc/apache2/sites-enabled/cafe_grader.conf
  # Reload so apache2 is running clean before apt upgrade runs its postinst.
  sudo systemctl reload apache2 2>/dev/null || true
  echo "  Stale vhost removed."
fi

sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  apache2 apache2-dev libapache2-mod-xsendfile \
  mysql-server git software-properties-common \
  libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
  apt-transport-https \
  postgresql postgresql-server-dev-all \
  openssl unzip curl \
  libcurl4-openssl-dev   # provides curl-config, required by Passenger

# Language compilers / runtimes
sudo apt install -y \
  ghc g++ openjdk-21-jdk fpc \
  php-cli php-readline \
  golang-go cargo python3-venv

# ---------------------------------------------------------------
# 2. Ruby via rbenv
# ---------------------------------------------------------------
echo "[2/13] Installing rbenv and Ruby $RUBY_VERSION..."
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
# 3. MySQL
# ---------------------------------------------------------------
echo "[3/13] Setting up MySQL databases and user..."
sudo systemctl start mysql || sudo service mysql start
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_QUEUE\`;"
sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

# ---------------------------------------------------------------
# 4. ioi/isolate
# ---------------------------------------------------------------
echo "[4/13] Building and installing ioi/isolate..."

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
# 5. Isolate systemd services + kernel settings
# ---------------------------------------------------------------
echo "[5/13] Configuring isolate kernel settings..."

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
# 6. GRUB: enable cgroup memory support (required for isolate)
# ---------------------------------------------------------------
echo "[6/13] Patching GRUB for cgroup_enable=memory..."
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
# 7. Cafe-Grader app: clone + configure
# ---------------------------------------------------------------
echo "[7/13] Cloning and configuring Cafe-Grader..."
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
cp config/database.yml.SAMPLE config/database.yml
sed -i "s/username:.*/username: $DB_USER/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/host:.*/host: localhost/"        config/database.yml
echo "  database.yml patched with DB credentials."

# Always regenerate and patch worker.yml
cp config/worker.yml.SAMPLE config/worker.yml
sed -i "s|web:.*|web: http://localhost|" config/worker.yml
echo "  worker.yml patched (web: http://localhost)."

# Silence Dart Sass @import deprecation warnings from Bootstrap.
cat > config/initializers/dartsass_silence_deprecations.rb <<'RUBYEOF'
Rails.application.config.dartsass.build_options \
  << "--silence-deprecation=import" \
  << "--silence-deprecation=global-builtin" \
  << "--silence-deprecation=color-functions" \
  << "--silence-deprecation=mixed-decls"
RUBYEOF
echo "  Dart Sass deprecation warnings silenced."

bundle install

# ---------------------------------------------------------------
# 8. Rails master key + credentials
# ---------------------------------------------------------------
echo "[8/13] Generating Rails master key and credentials..."

# Remove any stale/mismatched key+credentials pair left from a previous run
# or copied from the repo's SAMPLE. A mismatch causes:
#   ActiveSupport::MessageEncryptor::InvalidMessage: missing separator
# at db:migrate/db:setup time because Rails tries to decrypt credentials
# during environment load (config/environment.rb:5).
#
# The correct approach is to let Rails generate a matched key+credentials
# pair from scratch using `credentials:edit`. We use a throwaway EDITOR
# (true) so the command completes non-interactively without opening a text
# editor. This writes a fresh encrypted credentials.yml.enc and master.key
# that are always in sync.
rm -f config/master.key config/credentials.yml.enc

EDITOR=true bundle exec rails credentials:edit
chmod 600 config/master.key
echo "  master.key and credentials.yml.enc generated (matched pair)."
echo "  *** BACK UP $APP_DIR/config/master.key ***"

# ---------------------------------------------------------------
# 9. Python venv for grader engine
# ---------------------------------------------------------------
echo "[9/13] Creating Python venv at /venv/grader..."
if [ ! -d "/venv/grader" ]; then
  sudo python3 -m venv /venv/grader
  sudo /venv/grader/bin/pip install --upgrade pip --quiet
  echo "  Python venv ready."
else
  echo "  /venv/grader already exists, skipping."
fi

# ---------------------------------------------------------------
# 10. Database setup + asset compilation
# ---------------------------------------------------------------
echo "[10/13] Initialising database and compiling assets..."
cd "$APP_DIR"

# Check if tables exist. If rerunning, db:setup tries to drop tables and crashes on Foreign Keys.
# This check ensures it safely runs db:migrate instead if data already exists.
TABLE_COUNT=$(sudo mysql -u root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';")
TABLE_COUNT=${TABLE_COUNT:-0}

if [ "$TABLE_COUNT" -eq 0 ]; then
  echo "  Database is empty. Loading schema (db:setup)..."
  RAILS_ENV=production bundle exec rails db:setup DISABLE_DATABASE_ENVIRONMENT_CHECK=1
else
  echo "  Database already has tables. Running migrations (db:migrate) to prevent FK crashes..."
  RAILS_ENV=production bundle exec rails db:migrate
fi

echo "  Seeding default data..."
RAILS_ENV=production bundle exec rails db:seed || true

echo "  Building assets..."
RAILS_ENV=production bundle exec rails dartsass:build
RAILS_ENV=production bundle exec rails assets:precompile
echo "  Database and assets ready."


# ---------------------------------------------------------------
# 11. Phusion Passenger + Apache vhost
# ---------------------------------------------------------------
echo "[11/13] Installing Phusion Passenger and configuring Apache..."

# ---- Purge stale Passenger Apache config from any previous install ----
# If a prior run (or a system-level RVM Passenger) left passenger.load pointing
# to a different path, the installer's pre-flight check sees a mismatch and
# aborts with "Incorrect Passenger module path detected".
# We delete both files now so this run writes them fresh with correct paths.
sudo a2dismod passenger 2>/dev/null || true
sudo rm -f /etc/apache2/mods-available/passenger.load
sudo rm -f /etc/apache2/mods-available/passenger.conf
sudo rm -f /etc/apache2/mods-enabled/passenger.load
sudo rm -f /etc/apache2/mods-enabled/passenger.conf
echo "  Cleared any stale Passenger Apache module files."

# ---- Use rbenv-absolute paths for every Passenger command ----
# On machines with RVM installed, bare commands like `passenger-config`,
# `passenger-install-apache2-module`, and `gem` resolve to RVM's versions.
# We use `rbenv which` to get the exact binary and never rely on PATH.
RBENV_RUBY="$(rbenv which ruby)"
RBENV_GEM="$(rbenv which gem)"
RBENV_BIN_DIR="$(dirname "$RBENV_RUBY")"

# Install passenger and rack into the rbenv gem home.
"$RBENV_GEM" install passenger --no-document
"$RBENV_GEM" install rack --no-document

# Locate the installer script inside the rbenv-managed passenger gem.
PASSENGER_INSTALL=$("$RBENV_GEM" contents passenger 2>/dev/null \
  | grep "passenger-install-apache2-module$" | head -1) || true
if [ -z "$PASSENGER_INSTALL" ]; then
  echo "  ERROR: passenger-install-apache2-module not found in gem contents."
  exit 1
fi

# Build the Apache module using the absolute rbenv ruby.
"$RBENV_RUBY" "$PASSENGER_INSTALL" --auto --languages ruby

# Derive PASSENGER_ROOT directly from the rbenv gem directory.
# Never use passenger-config or bare PATH commands — on machines with RVM
# installed those resolve to the RVM passenger, not the rbenv one.
RBENV_GEM_HOME="$("$RBENV_RUBY" -e 'puts Gem.dir')"
PASSENGER_ROOT=$(find "$RBENV_GEM_HOME/gems" -maxdepth 1 -name "passenger-*" -type d 2>/dev/null \
  | sort -V | tail -1) || true
PASSENGER_RUBY="$RBENV_RUBY"
PASSENGER_MODULE=$(find "$PASSENGER_ROOT" -name mod_passenger.so 2>/dev/null | head -1) || true

if [ -z "$PASSENGER_ROOT" ]; then
  echo "  ERROR: Could not find passenger gem under rbenv gem home."
  echo "  RBENV_GEM_HOME=$RBENV_GEM_HOME"
  exit 1
fi
if [ -z "$PASSENGER_MODULE" ]; then
  echo "  ERROR: mod_passenger.so not found after build."
  echo "  PASSENGER_ROOT=$PASSENGER_ROOT"
  exit 1
fi

echo "  PASSENGER_ROOT=$PASSENGER_ROOT"
echo "  PASSENGER_RUBY=$PASSENGER_RUBY"
echo "  PASSENGER_MODULE=$PASSENGER_MODULE"

# Write passenger.load and passenger.conf with correct rbenv paths.
sudo tee /etc/apache2/mods-available/passenger.load > /dev/null <<EOF
LoadModule passenger_module $PASSENGER_MODULE
EOF
sudo tee /etc/apache2/mods-available/passenger.conf > /dev/null <<EOF
<IfModule mod_passenger.c>
  PassengerRoot $PASSENGER_ROOT
  PassengerDefaultRuby $PASSENGER_RUBY
</IfModule>
EOF

sudo a2enmod passenger
sudo a2enmod xsendfile

# Suppress Apache FQDN warning on cloud instances with no reverse DNS.
grep -q "^ServerName" /etc/apache2/apache2.conf || \
  echo "ServerName 127.0.0.1" | sudo tee -a /etc/apache2/apache2.conf

# Detect the primary LAN/VM IP — works on VirtualBox, bare metal, and cloud.
# Falls back to 127.0.0.1 if no non-loopback address is found.
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}') || true
SERVER_IP="${SERVER_IP:-127.0.0.1}"

sudo a2dissite 000-default 2>/dev/null || true
sudo tee /etc/apache2/sites-available/cafe_grader.conf > /dev/null <<EOF
<VirtualHost *:80>
  ServerName $SERVER_IP
  DocumentRoot $APP_DIR/public

  <Directory $APP_DIR/public>
    AllowOverride all
    Options -MultiViews
    Require all granted
  </Directory>

  PassengerEnabled on
  PassengerRuby $PASSENGER_RUBY
  PassengerAppEnv production

  # Enable X-Sendfile to offload file downloads to Apache
  XSendFile on
  XSendFilePath $APP_DIR/storage

  ErrorLog \${APACHE_LOG_DIR}/cafe_grader_error.log
  CustomLog \${APACHE_LOG_DIR}/cafe_grader_access.log combined
</VirtualHost>
EOF

sudo a2ensite cafe_grader

# Grant Apache (www-data) traversal permission on the home directory.
chmod o+x "$HOME"

echo "  Validating Apache configuration..."
if ! sudo apache2ctl configtest 2>&1; then
  echo ""
  echo "  ERROR: Apache config test failed. Paths written:"
  echo "    PASSENGER_MODULE=$PASSENGER_MODULE"
  echo "    PASSENGER_ROOT=$PASSENGER_ROOT"
  echo "    PASSENGER_RUBY=$PASSENGER_RUBY"
  echo "  Fix the errors above before restarting Apache."
  exit 1
fi

sudo systemctl restart apache2
# Enable on boot explicitly (apt enables them by default, but make the boot
# contract unambiguous so a reboot always serves the app).
sudo systemctl enable apache2 mysql
echo "  Apache + Passenger configured (apache2 + mysql enabled on boot)."

# Open port 80 in ufw if active (safe no-op if ufw is inactive or port already open).
if sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
  sudo ufw allow 80/tcp
  echo "  ufw: allowed TCP port 80."
fi

# 12. Solid Queue systemd service
# ---------------------------------------------------------------
echo "[12/13] Installing Solid Queue systemd service..."

# Resolve absolute paths at install time — written into the unit file so
# systemd never goes through bash login shells (which load RVM and override
# our rbenv ruby).
RBENV_RUBY_BIN="$(rbenv which ruby)"
RBENV_BUNDLE_BIN="$(rbenv which bundle)"

sudo tee /etc/systemd/system/solid_queue.service > /dev/null <<EOF
[Unit]
Description=Solid Queue for Cafe-Grader
After=network.target mysql.service
Wants=mysql.service

[Service]
User=$LINUX_USER
WorkingDirectory=$APP_DIR
# Use absolute rbenv ruby path — avoids RVM login shell interference.
ExecStart=$RBENV_BUNDLE_BIN exec rails solid_queue:start
Environment=RAILS_ENV=production
Environment=PATH=$HOME/.rbenv/shims:$HOME/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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
# 13. Grader workers + whenever crontab
# ---------------------------------------------------------------
echo "[13/13] Installing grader services..."

# 13a. Oneshot — updates the whenever crontab only.
sudo tee /etc/systemd/system/cafe_grader_startup.service > /dev/null <<EOF
[Unit]
Description=Update Cafe-Grader whenever crontab after reboot
After=network.target mysql.service solid_queue.service
Wants=mysql.service

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

# 13b. Grader workers — Grader.restart(N) spawns N detached child processes
# that write to log/grader-N.txt, keep running independently, then returns.
# Type=simple + RemainAfterExit=yes: systemd runs this one-shot restart command
# via the absolute rbenv bundle (no login shell = no RVM interference) and then
# treats the service as "active" after it exits. There is intentionally NO
# Restart= directive — re-firing Grader.restart() would spawn duplicate workers;
# dead workers are respawned by Grader.watchdog, run each minute by the whenever cron.
sudo tee /etc/systemd/system/cafe_grader_workers.service > /dev/null <<EOF
[Unit]
Description=Cafe-Grader grader workers
After=network.target mysql.service solid_queue.service cafe_grader_startup.service
Wants=mysql.service

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
# Done
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Installation complete!"
echo "============================================================"
echo ""
echo "  Default login  ->  username: root   password: ioionrails"
echo "  Change the password immediately after first login."
echo ""
echo "  ONE STEP REQUIRED:"
echo ""
echo "    sudo reboot"
echo ""
echo "  After reboot everything starts automatically:"
echo "    - Apache + Passenger   serves the web app on port 80"
echo "    - Solid Queue          processes background jobs"
echo "    - $WORKER_COUNT grader worker(s)   evaluate code submissions"
echo ""
echo "  *** BACK UP: $APP_DIR/config/master.key ***"
echo "  Losing this file means losing access to encrypted credentials."
echo ""