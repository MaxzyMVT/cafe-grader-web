#!/bin/bash
# Cafe-Grader Web/DB Server Installation Script (Server 1 of 3, Ubuntu 22.04+)
# Fully automated — the only manual step is a final  sudo reboot.
# Run as a normal user with sudo privileges, NOT as root.
#
# Usage: bash install_web_db_server.sh
#
# This server hosts the Rails web app and MySQL database.
# Worker nodes (install_worker_server.sh) connect to MySQL on this server.
# Do NOT run grader worker processes on this server.

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

LINUX_USER="$USER"
APP_DIR="$CAFE_DIR/web"

echo "============================================================"
echo " Cafe-Grader Web/DB Server Installation (Ubuntu 22.04+)"
echo "============================================================"

# ---------------------------------------------------------------
# 1. System packages (web/db only — no language compilers needed)
# ---------------------------------------------------------------
echo "[1/9] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  apache2 apache2-dev libapache2-mod-xsendfile \
  mysql-server git software-properties-common \
  libmysqlclient-dev libcap-dev \
  apt-transport-https \
  postgresql postgresql-server-dev-all \
  openssl unzip curl \
  libcurl4-openssl-dev   # provides curl-config, required by Passenger

# ---------------------------------------------------------------
# 2. Ruby via rbenv
# ---------------------------------------------------------------
echo "[2/9] Installing rbenv and Ruby $RUBY_VERSION..."
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
# 3. MySQL — local + remote access for worker nodes
# ---------------------------------------------------------------
echo "[3/9] Configuring MySQL for local and remote access..."
sudo systemctl start mysql || sudo service mysql start

# Allow all interfaces — restrict by firewall to worker IPs in production
sudo sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' \
  /etc/mysql/mysql.conf.d/mysqld.cnf
sudo systemctl restart mysql || sudo service mysql restart

# Create databases
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_QUEUE\`;"

# localhost user (web app on this server)
sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'localhost';"

# Wildcard user for worker nodes (restrict with firewall to worker IPs in production)
sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'%';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'%';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

echo "  NOTE: Firewall must allow TCP 3306 from worker IPs only."

# ---------------------------------------------------------------
# 4. Cafe-Grader app: clone + configure
# ---------------------------------------------------------------
echo "[4/9] Cloning and configuring Cafe-Grader..."
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
# SAMPLE defaults to  username: grader / password: grader  which will fail db:setup.
cp config/database.yml.SAMPLE config/database.yml
sed -i "s/username:.*/username: $DB_USER/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/host:.*/host: localhost/"        config/database.yml
echo "  database.yml patched with DB credentials."

# Always regenerate and patch worker.yml
cp config/worker.yml.SAMPLE config/worker.yml
sed -i "s|web:.*|web: http://localhost|" config/worker.yml
sed -i "s|worker_id:.*|worker_id: 0|" config/worker.yml
# Web/DB server has no isolate binary — blank the path so the grader skips
# isolation init cleanly (see app/engine/isolate_runner.rb setup_isolate guard).
sed -i "s|isolate_path:.*|isolate_path: |" config/worker.yml
echo "  worker.yml patched (web: http://localhost, worker_id: 0, isolate_path: disabled)."

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
# 5. Rails master key + credentials
# ---------------------------------------------------------------
echo "[5/9] Generating Rails master key and credentials..."

# Remove any stale/mismatched key+credentials pair. A mismatch causes:
#   ActiveSupport::MessageEncryptor::InvalidMessage: missing separator
# at db:migrate time because Rails decrypts credentials during environment
# load (config/environment.rb:5). EDITOR=true runs non-interactively.
rm -f config/master.key config/credentials.yml.enc

EDITOR=true bundle exec rails credentials:edit
chmod 600 config/master.key
echo "  master.key and credentials.yml.enc generated (matched pair)."
echo "  *** BACK UP $APP_DIR/config/master.key ***"

# ---------------------------------------------------------------
# 6. Database setup + asset compilation
# ---------------------------------------------------------------
echo "[6/9] Initialising database and compiling assets..."
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
# 7. Phusion Passenger + Apache vhost
# ---------------------------------------------------------------
echo "[7/9] Installing Phusion Passenger and configuring Apache..."

# Resolve the exact rbenv-managed ruby/gem binaries so every install
# lands in the same gem home that Passenger's pre-flight check inspects.
RBENV_RUBY="$(rbenv which ruby)"
RBENV_GEM="$(rbenv which gem)"

"$RBENV_GEM" install passenger --no-document
# Install rack via the SAME ruby binary Passenger will use for its check.
"$RBENV_GEM" install rack --no-document

# Build Apache module as current user (inherits rbenv environment).
PASSENGER_INSTALL=$("$RBENV_GEM" contents passenger 2>/dev/null \
  | grep "passenger-install-apache2-module$" | head -1) || true
if [ -n "$PASSENGER_INSTALL" ]; then
  "$RBENV_RUBY" "$PASSENGER_INSTALL" --auto --languages ruby
else
  passenger-install-apache2-module --auto --languages ruby
fi

PASSENGER_ROOT=$(passenger-config --root)
# Use rbenv's resolved ruby path — `which ruby` returns the shim and Apache
# needs the real absolute binary path to start workers correctly.
PASSENGER_RUBY="$RBENV_RUBY"
PASSENGER_MODULE=$(find "$PASSENGER_ROOT" -name mod_passenger.so 2>/dev/null | head -1) || true

if [ -z "$PASSENGER_MODULE" ]; then
  echo "  ERROR: mod_passenger.so not found. Passenger build may have failed."
  echo "  Check output above for compilation errors."
  exit 1
fi

# The passenger installer already ran a2enmod, but the .load/.conf files it
# writes may not match our rbenv ruby path. Overwrite them with correct values.
sudo tee /etc/apache2/mods-available/passenger.load > /dev/null <<EOF
LoadModule passenger_module $PASSENGER_MODULE
EOF
sudo tee /etc/apache2/mods-available/passenger.conf > /dev/null <<EOF
<IfModule mod_passenger.c>
  PassengerRoot $PASSENGER_ROOT
  PassengerDefaultRuby $PASSENGER_RUBY
</IfModule>
EOF

# Ensure the module is enabled (idempotent — safe to run even if already enabled).
sudo a2enmod passenger
sudo a2enmod xsendfile

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
# Ubuntu sets home dirs to chmod 750 by default — www-data cannot traverse
# into them, which causes a 403 Forbidden even when vhost config is correct.
chmod o+x "$HOME"

# Validate config before restarting.
echo "  Validating Apache configuration..."
if ! sudo apache2ctl configtest 2>&1; then
  echo ""
  echo "  ERROR: Apache config test failed. Dumping passenger module paths:"
  echo "    PASSENGER_MODULE=$PASSENGER_MODULE"
  echo "    PASSENGER_ROOT=$PASSENGER_ROOT"
  echo "    PASSENGER_RUBY=$PASSENGER_RUBY"
  echo "  Fix the errors above before restarting Apache."
  exit 1
fi

sudo systemctl restart apache2
# Enable on boot explicitly (apt enables them by default, but make the boot
# contract unambiguous so a reboot always serves the app + accepts worker DB conns).
sudo systemctl enable apache2 mysql
echo "  Apache + Passenger configured (apache2 + mysql enabled on boot)."

# ---------------------------------------------------------------
# 8. Solid Queue systemd service
# ---------------------------------------------------------------
echo "[8/9] Installing Solid Queue systemd service..."

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
# 9. Update whenever crontab (web server only — no grader workers here)
# ---------------------------------------------------------------
echo "[9/9] Installing whenever crontab update service..."

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

sudo systemctl daemon-reload
sudo systemctl enable cafe_grader_startup.service

# ---------------------------------------------------------------
# Done
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Web/DB Server installation complete!"
echo "============================================================"
echo ""
echo "  Default login  ->  username: root   password: ioionrails"
echo "  Change the password immediately after first login."
echo ""
echo "  Note this server's IP address — you will need it when"
echo "  running install_worker_server.sh on each worker node."
echo "  Give each worker a UNIQUE worker id (1, 2, 3, ...):"
echo "    worker 1:  bash install_worker_server.sh <this-server-ip> 1"
echo "    worker 2:  bash install_worker_server.sh <this-server-ip> 2"
echo "  (Reusing an id makes two workers collide and thrash the watchdog.)"
echo ""
echo "  ONE STEP REQUIRED:"
echo ""
echo "    sudo reboot"
echo ""
echo "  After reboot everything starts automatically:"
echo "    - Apache + Passenger   serves the web app on port 80"
echo "    - Solid Queue          processes background jobs"
echo "    (Do NOT start grader workers on this server.)"
echo ""
echo "  *** BACK UP: $APP_DIR/config/master.key ***"
echo "  Losing this file means losing access to encrypted credentials."
echo ""