#!/bin/bash
# Cafe-Grader Web/DB Server Installation Script (Server 1 of 3, Ubuntu 22.04+)
# Run as a normal user with sudo privileges, NOT as root.
# Usage: bash install_web_db_server.sh

set -e

CAFE_DIR="$HOME/cafe_grader"
RUBY_VERSION="3.4.4"
DB_NAME="grader"
DB_QUEUE="grader_queue"
DB_USER="grader_user"
DB_PASS="grader_pass"

echo "============================================================"
echo " Cafe-Grader Web/DB Node Installation (Ubuntu 22.04+)"
echo "============================================================"

# ---------------------------------------------------------------
# 1. System updates and packages (web/db — no compilers needed)
# ---------------------------------------------------------------
echo "[1/5] Installing system dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  apache2 apache2-dev \
  mysql-server git software-properties-common \
  libmysqlclient-dev libcap-dev \
  apt-transport-https \
  postgresql postgresql-server-dev-all \
  unzip curl

# ---------------------------------------------------------------
# 2. Install Ruby via rbenv
# ---------------------------------------------------------------
echo "[2/5] Installing rbenv and Ruby $RUBY_VERSION..."
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
# 3. MySQL — configure for remote connections from worker nodes
# ---------------------------------------------------------------
echo "[3/5] Configuring MySQL for remote access..."
sudo systemctl start mysql || sudo service mysql start

# Allow all interfaces (lock down with firewall rules, not bind-address)
sudo sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' \
  /etc/mysql/mysql.conf.d/mysqld.cnf
sudo service mysql restart

# Create databases and users
# localhost user (for the web app on this server)
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_QUEUE\`;"

sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'localhost';"

# Wildcard user for worker nodes (restrict via firewall to worker IPs in production)
sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'%';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'%';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

echo "  NOTE: Ensure your firewall allows TCP port 3306 from Worker node IPs only."

# ---------------------------------------------------------------
# 4. Clone and configure Cafe-Grader web app
# ---------------------------------------------------------------
echo "[4/5] Setting up Cafe-Grader web app..."
mkdir -p "$CAFE_DIR"
cd "$CAFE_DIR"
if [ ! -d "web" ]; then
  git clone https://github.com/MaxzyMVT/cafe-grader-web.git web
fi
cd web

# Initialise config files from samples
[ ! -f config/application.rb ] && cp config/application.rb.SAMPLE config/application.rb
[ ! -f config/database.yml ]   && cp config/database.yml.SAMPLE   config/database.yml
[ ! -f config/llm.yml ]        && cp config/llm.yml.SAMPLE        config/llm.yml
[ ! -f config/worker.yml ]     && cp config/worker.yml.SAMPLE     config/worker.yml

bundle install

# ---------------------------------------------------------------
# 5. Setup Solid Queue as a systemd service
# ---------------------------------------------------------------
echo "[5/5] Installing Solid Queue systemd service..."
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
# Print remaining manual steps
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Web/DB Node script complete! Manual steps remaining:"
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
echo "STEP C — Update config/database.yml:"
echo "  host:     localhost   (web app connects locally)"
echo "  database: $DB_NAME"
echo "  username: $DB_USER"
echo "  password: $DB_PASS"
echo ""
echo "  Also update config/worker.yml — set 'web:' to this server's URL."
echo ""
echo "STEP D — Initialise database and precompile assets:"
echo "  bundle exec rails db:setup DISABLE_DATABASE_ENVIRONMENT_CHECK=1 RAILS_ENV=production"
echo "  bundle exec rails db:seed RAILS_ENV=production"
echo "  bundle exec rails dartsass:build RAILS_ENV=production"
echo "  bundle exec rails assets:precompile RAILS_ENV=production"
echo ""
echo "STEP E — Configure Apache + Phusion Passenger:"
echo "  Follow https://www.phusionpassenger.com/docs/tutorials/deploy_to_production/"
echo "  DocumentRoot: $APP_DIR/public"
echo ""
echo "STEP F — Start Solid Queue:"
echo "  sudo systemctl start solid_queue.service"
echo ""
echo "  Do NOT start grader worker processes on this server."
echo "  Worker processes run only on Server 2 & 3."
echo ""
echo "Default login: username=root, password=<value of GRADER_ADMIN_PASSWORD>"