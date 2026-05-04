#!/bin/bash
# Cafe-Grader Single Server Installation Script (Ubuntu 22.04+)
# Fully automated — the only manual step is a final  sudo reboot.
# Run as a normal user with sudo privileges, NOT as root.
#
# Usage: bash install_single_server.sh

set -e

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
# 1. System packages
# ---------------------------------------------------------------
echo "[1/13] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  apache2 apache2-dev \
  mysql-server git software-properties-common \
  libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
  apt-transport-https \
  postgresql postgresql-server-dev-all \
  openssl unzip curl

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
if[ ! -d "/tmp/isolate" ]; then
  git clone https://github.com/ioi/isolate.git /tmp/isolate
fi
cd /tmp/isolate
make isolate
sudo make install

echo "  Disabling swap (required by isolate)..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# ---------------------------------------------------------------
# 5. Isolate systemd services + kernel settings
# ---------------------------------------------------------------
echo "[5/13] Configuring isolate kernel settings..."

ISOLATE_SRC="/tmp/isolate/systemd/isolate.service"
if [ -f "$ISOLATE_SRC" ]; then
  sudo ln -sf "$ISOLATE_SRC" /etc/systemd/system/isolate.service
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
echo "[8/13] Generating Rails master key..."
if [ ! -f config/master.key ]; then
  cp config/credentials.yml.SAMPLE config/credentials.yml.enc
  openssl rand -hex 32 > config/master.key
  chmod 600 config/master.key
  echo "  master.key generated."
  echo "  *** BACK UP $APP_DIR/config/master.key ***"
else
  echo "  master.key already exists, skipping."
fi

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

if[ "$TABLE_COUNT" -eq 0 ]; then
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
gem install passenger --no-document

# Build Apache module
PASSENGER_INSTALL=$(gem contents passenger 2>/dev/null \
  | grep "passenger-install-apache2-module$" | head -1)
if[ -n "$PASSENGER_INSTALL" ]; then
  sudo "$(which ruby)" "$PASSENGER_INSTALL" --auto --languages ruby
else
  passenger-install-apache2-module --auto --languages ruby
fi

PASSENGER_ROOT=$(passenger-config --root)
PASSENGER_RUBY=$(which ruby)
PASSENGER_MODULE=$(find "$PASSENGER_ROOT" -name mod_passenger.so 2>/dev/null | head -1)

if [ -z "$PASSENGER_MODULE" ]; then
  echo "  WARNING: mod_passenger.so not found — Apache module may need manual setup."
  echo "  See: https://www.phusionpassenger.com/docs/tutorials/deploy_to_production/"
else
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
fi

sudo a2dissite 000-default 2>/dev/null || true
sudo tee /etc/apache2/sites-available/cafe_grader.conf > /dev/null <<EOF
<VirtualHost *:80>
  ServerName localhost
  DocumentRoot $APP_DIR/public

  <Directory $APP_DIR/public>
    AllowOverride all
    Options -MultiViews
    Require all granted
  </Directory>

  PassengerEnabled on
  PassengerRuby $PASSENGER_RUBY
  PassengerEnvVar RAILS_ENV production

  ErrorLog \${APACHE_LOG_DIR}/cafe_grader_error.log
  CustomLog \${APACHE_LOG_DIR}/cafe_grader_access.log combined
</VirtualHost>
EOF

sudo a2ensite cafe_grader
sudo systemctl restart apache2
echo "  Apache + Passenger configured."

# ---------------------------------------------------------------
# 12. Solid Queue systemd service
# ---------------------------------------------------------------
echo "[12/13] Installing Solid Queue systemd service..."
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
# 13. Post-reboot service: grader workers + whenever crontab
# ---------------------------------------------------------------
echo "[13/13] Installing post-reboot grader startup service..."
sudo tee /etc/systemd/system/cafe_grader_startup.service > /dev/null <<EOF
[Unit]
Description=Start Cafe-Grader grader workers after reboot
After=network.target mysql.service solid_queue.service
Wants=mysql.service[Service]
Type=oneshot
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=/bin/bash -lc 'RAILS_ENV=production bundle exec rails r "Grader.restart($WORKER_COUNT)"'
ExecStart=/bin/bash -lc 'bundle exec whenever --update-crontab'
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cafe_grader_startup.service

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