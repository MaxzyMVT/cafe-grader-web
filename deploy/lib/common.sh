#!/bin/bash
# Cafe-Grader installer shared library.
#
# Sourced by the role installers (install_single_server.sh, install_web_db_server.sh,
# install_worker_server.sh). NOT meant to be run directly. Each installer sets the
# config globals below, sources this file, then calls the cg_* functions it needs.
#
# Target OS: Ubuntu 22.04+. Every function is idempotent and safe to re-run.
#
# Required globals (set by the caller BEFORE sourcing / calling):
#   CAFE_DIR      install root (default $HOME/cafe_grader)
#   APP_DIR       Rails app dir   ($CAFE_DIR/web)
#   RUBY_VERSION  e.g. 3.4.4
#   DB_NAME DB_QUEUE DB_USER DB_PASS
#   REPO_URL      git URL to clone
#   LINUX_USER    unit-file User=  ($USER)
#   WORKER_COUNT  grader box count (single/worker roles)
#   CLOUD         "1" on cloud instances (enables metadata IP + ufw reminders), else ""
#
# The caller is expected to run under:  set -euo pipefail
# Command substitutions ending in `| head`/`| grep` validated by a later `[ -z ]`
# check are guarded with `|| true` so pipefail doesn't abort on the expected non-zero.

cg_section() { echo; echo "==> $*"; }

# ---------------------------------------------------------------------------
# Cloud helpers (no-ops / local fallbacks when CLOUD is unset)
# ---------------------------------------------------------------------------

# Best-effort public/primary IP. On cloud, try the AWS/GCP/Azure metadata service
# first; always fall back to the first non-loopback IPv4, then 127.0.0.1.
cg_detect_server_ip() {
  local ip=""
  if [ "${CLOUD:-}" = "1" ]; then
    ip=$(curl -sf --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null) \
      && { echo "$ip"; return; }
    ip=$(curl -sf --max-time 2 -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
      2>/dev/null) && { echo "$ip"; return; }
  fi
  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  [ -z "$ip" ] && { ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet/{print $2}' | cut -d/ -f1 | head -1) || true; }
  echo "${ip:-127.0.0.1}"
}

# Open a TCP port in ufw only when ufw is active; otherwise remind cloud users.
cg_ufw_allow_if_active() {
  local port="$1"
  if sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
    sudo ufw allow "${port}/tcp"
    echo "  ufw: opened port $port/tcp."
  elif [ "${CLOUD:-}" = "1" ]; then
    echo "  ufw inactive — open port $port in your security group / firewall rules."
  fi
}

# ---------------------------------------------------------------------------
# RAM headroom check (advisory)
# ---------------------------------------------------------------------------
# Swap is disabled for isolate (hard RAM cap), which removes the OOM cushion. The
# host must physically fit every concurrent sandbox plus the base system, or the
# OOM killer strikes — possibly MySQL or a grader, not just the offending box.
#   $1 = per-box budget MB   $2 = base-system overhead MB
cg_ram_headroom_check() {
  local per_box_mb="$1" overhead_mb="$2" ram_kb ram_mb need_mb
  ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || true)
  ram_mb=$(( ${ram_kb:-0} / 1024 ))
  need_mb=$(( WORKER_COUNT * per_box_mb + overhead_mb ))
  if [ "$ram_mb" -eq 0 ]; then
    echo "  (could not read /proc/meminfo — skipping RAM headroom check)"
  elif [ "$ram_mb" -lt "$need_mb" ]; then
    echo "  ####################################################################"
    echo "  # WARNING: low RAM for $WORKER_COUNT grader worker(s) with swap disabled."
    echo "  #   physical RAM : ${ram_mb} MB"
    echo "  #   recommended  : ${need_mb} MB  (${WORKER_COUNT} x ${per_box_mb}MB boxes + ${overhead_mb}MB system)"
    echo "  # Without swap the OOM killer may kill MySQL or a grader under load."
    echo "  # Mitigate: add RAM, lower WORKER_COUNT at the top of the installer,"
    echo "  # or cap each problem's memory_limit. Continuing anyway."
    echo "  ####################################################################"
  else
    echo "  RAM check OK: ${ram_mb} MB >= ${need_mb} MB recommended for $WORKER_COUNT worker(s)."
  fi
}

# ---------------------------------------------------------------------------
# Packages + Ruby
# ---------------------------------------------------------------------------

# Remove a stale cafe_grader vhost so `apt upgrade`'s apache2 postinst can't abort
# the script on a broken DocumentRoot left by a previous install.
cg_purge_stale_apache_vhost() {
  if [ -f /etc/apache2/sites-enabled/cafe_grader.conf ] || \
     [ -f /etc/apache2/sites-available/cafe_grader.conf ]; then
    echo "  Removing stale Apache vhost from a previous install..."
    sudo a2dissite cafe_grader 2>/dev/null || true
    sudo rm -f /etc/apache2/sites-available/cafe_grader.conf /etc/apache2/sites-enabled/cafe_grader.conf
    sudo systemctl reload apache2 2>/dev/null || true
  fi
}

cg_apt_update_upgrade() { sudo apt update && sudo apt upgrade -y; }

# Web/DB packages (Apache + MySQL + Passenger build deps).
cg_apt_install_web() {
  sudo apt install -y \
    apache2 apache2-dev libapache2-mod-xsendfile \
    mysql-server git software-properties-common \
    libmysqlclient-dev libcap-dev \
    apt-transport-https \
    postgresql postgresql-server-dev-all \
    openssl unzip curl \
    libcurl4-openssl-dev   # curl-config, required by Passenger
}

# Worker base packages (no Apache/MySQL; adds isolate build deps).
cg_apt_install_worker_base() {
  sudo apt install -y \
    git software-properties-common \
    libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
    openssl curl unzip
}

# Language compilers / runtimes (grading hosts: single + worker).
cg_apt_install_compilers() {
  sudo apt install -y \
    ghc g++ openjdk-21-jdk fpc \
    php-cli php-readline \
    golang-go cargo python3-venv
}

# rbenv + Ruby + bundler (identical across all roles).
cg_install_ruby() {
  cg_section "Installing rbenv and Ruby $RUBY_VERSION"
  sudo apt install -y \
    curl libssl-dev libreadline-dev zlib1g-dev \
    autoconf bison build-essential libyaml-dev \
    libncurses5-dev libffi-dev libgdbm-dev
  if [ ! -d "$HOME/.rbenv" ]; then
    curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash
  fi
  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init -)"
  grep -qxF 'export PATH="$HOME/.rbenv/bin:$PATH"' ~/.bashrc || echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
  grep -qxF 'eval "$(rbenv init -)"' ~/.bashrc || echo 'eval "$(rbenv init -)"' >> ~/.bashrc
  rbenv install -s "$RUBY_VERSION"
  rbenv global "$RUBY_VERSION"
  [ -d "$HOME/.gem/ruby" ] && rm -rf "$HOME/.gem/ruby"   # stale gem stubs
  gem install bundler --no-document
}

# ---------------------------------------------------------------------------
# MySQL
# ---------------------------------------------------------------------------

# Single-server: local-only user + the two databases.
cg_mysql_single() {
  cg_section "Setting up MySQL (local) databases and user"
  sudo systemctl start mysql || sudo service mysql start
  sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
  sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_QUEUE\`;"
  sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
  sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
  sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
  sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'localhost';"
  sudo mysql -u root -e "FLUSH PRIVILEGES;"
}

# Web/DB server: bind all interfaces + localhost user + wildcard user for workers.
cg_mysql_webdb() {
  cg_section "Configuring MySQL for local + remote (worker) access"
  sudo systemctl start mysql || sudo service mysql start
  sudo sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
  sudo systemctl restart mysql || sudo service mysql restart
  sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
  sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB_QUEUE\`;"
  local host
  for host in localhost '%'; do
    sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'$host';"
    sudo mysql -u root -e "CREATE USER '$DB_USER'@'$host' IDENTIFIED BY '$DB_PASS';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$host';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`$DB_QUEUE\`.* TO '$DB_USER'@'$host';"
  done
  sudo mysql -u root -e "FLUSH PRIVILEGES;"
  echo "  NOTE: firewall must allow TCP 3306 from worker IPs only."
}

# ---------------------------------------------------------------------------
# ioi/isolate  (single + worker roles)
# ---------------------------------------------------------------------------

cg_install_isolate() {
  cg_section "Building and installing ioi/isolate"
  local src="$HOME/isolate"
  [ -d "$src" ] || git clone https://github.com/ioi/isolate.git "$src"
  ( cd "$src" && make isolate && sudo make install )

  # isolate v2.5+ reads /etc/subuid+subgid for the 'isolate' user. Without it every
  # --init dies ("User isolate not found") and workers sit idle with no heartbeat.
  # Range 200000:65536 is safely above Ubuntu's default 100000 allocations.
  if ! id isolate &>/dev/null; then
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin isolate
    echo "  Created system user 'isolate'."
  fi
  grep -q "^isolate:" /etc/subuid || echo "isolate:200000:65536" | sudo tee -a /etc/subuid >/dev/null
  grep -q "^isolate:" /etc/subgid || echo "isolate:200000:65536" | sudo tee -a /etc/subgid >/dev/null

  echo "  Disabling swap (isolate needs a hard RAM cap)..."
  sudo swapoff -a
  sudo sed -i '/\sswap\s/ s/^\(.*\)$/#\1/' /etc/fstab   # stop reboot re-enable
  [ -f /swap.img ] && sudo rm -f /swap.img || true
}

cg_setup_isolate_systemd() {
  cg_section "Configuring isolate systemd services + kernel settings"
  local svc="$HOME/isolate/systemd/isolate.service"
  if [ -f "$svc" ]; then
    sudo ln -sf "$svc" /etc/systemd/system/isolate.service
    echo "  isolate.service symlinked from $svc"
  else
    echo "  ####################################################################"
    echo "  # WARNING: $svc not found."
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
    echo "# IOI isolate"                | sudo tee -a /etc/sysctl.d/99-sysctl.conf >/dev/null
    echo "kernel.randomize_va_space=0"  | sudo tee -a /etc/sysctl.d/99-sysctl.conf >/dev/null
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable set-ioi-isolate.service
  [ -f /etc/systemd/system/isolate.service ] && sudo systemctl enable isolate.service
}

# GRUB cgroup-memory enable. Patches both CMDLINE keys (desktop + cloud) and uses
# whichever grub config tool exists.
cg_patch_grub_cgroup() {
  cg_section "Patching GRUB for cgroup_enable=memory"
  if [ ! -f /etc/default/grub ]; then
    echo "  WARNING: /etc/default/grub not found — set cgroup_enable=memory manually."
    return
  fi
  if grep -q "cgroup_enable=memory" /etc/default/grub; then
    echo "  cgroup_enable=memory already present, skipping."
    return
  fi
  sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 cgroup_enable=memory swapaccount=1"/' /etc/default/grub
  sudo sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 cgroup_enable=memory swapaccount=1"/' /etc/default/grub
  if   command -v update-grub    &>/dev/null; then sudo update-grub
  elif command -v grub2-mkconfig &>/dev/null; then sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  else sudo grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true; fi
  echo "  GRUB updated — takes effect after reboot."
}

# ---------------------------------------------------------------------------
# App clone + config
# ---------------------------------------------------------------------------

# Clone the repo into $CAFE_DIR/web and cd into it.
cg_clone_app() {
  cg_section "Cloning and configuring Cafe-Grader"
  mkdir -p "$CAFE_DIR"
  [ -d "$CAFE_DIR/web" ] || git clone "$REPO_URL" "$CAFE_DIR/web"
  cd "$APP_DIR"
  [ -f config/application.rb ] || cp config/application.rb.SAMPLE config/application.rb
  [ -f config/llm.yml ]        || cp config/llm.yml.SAMPLE        config/llm.yml
}

# Patch database.yml (host = $1).
cg_patch_database_yml() {
  local host="$1"
  cp config/database.yml.SAMPLE config/database.yml
  sed -i "s/username:.*/username: $DB_USER/" config/database.yml
  sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
  sed -i "s/host:.*/host: $host/"            config/database.yml
  echo "  database.yml patched (user: $DB_USER, host: $host)."
}

# Patch worker.yml. $1 = web URL; $2 = worker_id (optional); $3 = "disable_isolate" (optional).
cg_patch_worker_yml() {
  local web="$1" wid="${2:-}" disable_isolate="${3:-}"
  cp config/worker.yml.SAMPLE config/worker.yml
  sed -i "s|web:.*|web: $web|" config/worker.yml
  if [ -n "$wid" ]; then sed -i "s|worker_id:.*|worker_id: $wid|" config/worker.yml; fi
  if [ "$disable_isolate" = "disable_isolate" ]; then
    # Web/DB server has no isolate binary — blank the path so the grader skips
    # isolation init cleanly (app/engine/isolate_runner.rb setup_isolate guard).
    sed -i "s|worker_id:.*|worker_id: 0|" config/worker.yml
    sed -i "s|isolate_path:.*|isolate_path: |" config/worker.yml
  fi
  echo "  worker.yml patched (web: $web${wid:+, worker_id: $wid}${disable_isolate:+, isolate disabled})."
}

# Silence Dart Sass @import deprecation noise from Bootstrap (asset-building roles).
cg_write_dartsass_silencer() {
  cat > config/initializers/dartsass_silence_deprecations.rb <<'RUBYEOF'
Rails.application.config.dartsass.build_options \
  << "--silence-deprecation=import" \
  << "--silence-deprecation=global-builtin" \
  << "--silence-deprecation=color-functions" \
  << "--silence-deprecation=mixed-decls"
RUBYEOF
}

# Generate a MATCHED master.key + credentials.yml.enc pair. Copying the SAMPLE .enc
# with a fresh random key mismatches and crashes boot with InvalidMessage; letting
# Rails write both via credentials:edit keeps them in sync (EDITOR=true = non-interactive).
cg_generate_credentials() {
  cg_section "Generating Rails master key and credentials"
  rm -f config/master.key config/credentials.yml.enc
  EDITOR=true bundle exec rails credentials:edit
  chmod 600 config/master.key
  echo "  master.key + credentials.yml.enc generated (matched pair)."
  echo "  *** BACK UP $APP_DIR/config/master.key ***"
}

cg_python_venv() {
  cg_section "Creating Python venv at /venv/grader"
  if [ ! -d "/venv/grader" ]; then
    sudo python3 -m venv /venv/grader
    sudo /venv/grader/bin/pip install --upgrade pip --quiet
  else
    echo "  /venv/grader already exists, skipping."
  fi
}

# Empty-DB guard: db:setup on a fresh DB, else db:migrate (avoids FK-drop crash on rerun).
cg_db_setup_or_migrate() {
  cg_section "Initialising database"
  local n
  n=$(sudo mysql -u root -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';")
  n=${n:-0}
  if [ "$n" -eq 0 ]; then
    echo "  Database empty — loading schema (db:setup)..."
    RAILS_ENV=production bundle exec rails db:setup DISABLE_DATABASE_ENVIRONMENT_CHECK=1
  else
    echo "  Database has tables — running db:migrate..."
    RAILS_ENV=production bundle exec rails db:migrate
  fi
  RAILS_ENV=production bundle exec rails db:seed || true
}

cg_build_assets() {
  cg_section "Building assets"
  RAILS_ENV=production bundle exec rails dartsass:build
  RAILS_ENV=production bundle exec rails assets:precompile
}

# ---------------------------------------------------------------------------
# Phusion Passenger + Apache (single + web/db roles)
# ---------------------------------------------------------------------------
# Uses rbenv-absolute paths throughout so a system RVM can't hijack the build.
cg_install_passenger_apache() {
  cg_section "Installing Phusion Passenger and configuring Apache"

  # Purge stale Passenger module files so the pre-flight path check can't abort.
  sudo a2dismod passenger 2>/dev/null || true
  sudo rm -f /etc/apache2/mods-available/passenger.load /etc/apache2/mods-available/passenger.conf
  sudo rm -f /etc/apache2/mods-enabled/passenger.load  /etc/apache2/mods-enabled/passenger.conf

  local rb gem_bin
  rb="$(rbenv which ruby)"; gem_bin="$(rbenv which gem)"
  "$gem_bin" install passenger --no-document
  "$gem_bin" install rack --no-document

  local installer
  installer=$("$gem_bin" contents passenger 2>/dev/null | grep "passenger-install-apache2-module$" | head -1) || true
  [ -n "$installer" ] || { echo "  ERROR: passenger-install-apache2-module not found."; exit 1; }
  "$rb" "$installer" --auto --languages ruby

  local gem_home root module_so
  gem_home="$("$rb" -e 'puts Gem.dir')"
  root=$(find "$gem_home/gems" -maxdepth 1 -name "passenger-*" -type d 2>/dev/null | sort -V | tail -1) || true
  module_so=$(find "$root" -name mod_passenger.so 2>/dev/null | head -1) || true
  [ -n "$root" ]      || { echo "  ERROR: passenger gem not found under $gem_home."; exit 1; }
  [ -n "$module_so" ] || { echo "  ERROR: mod_passenger.so not found after build."; exit 1; }

  sudo tee /etc/apache2/mods-available/passenger.load > /dev/null <<EOF
LoadModule passenger_module $module_so
EOF
  sudo tee /etc/apache2/mods-available/passenger.conf > /dev/null <<EOF
<IfModule mod_passenger.c>
  PassengerRoot $root
  PassengerDefaultRuby $rb
</IfModule>
EOF
  sudo a2enmod passenger
  sudo a2enmod xsendfile

  grep -q "^ServerName" /etc/apache2/apache2.conf || echo "ServerName 127.0.0.1" | sudo tee -a /etc/apache2/apache2.conf >/dev/null

  local server_ip; server_ip=$(cg_detect_server_ip)
  sudo a2dissite 000-default 2>/dev/null || true
  sudo tee /etc/apache2/sites-available/cafe_grader.conf > /dev/null <<EOF
<VirtualHost *:80>
  ServerName $server_ip
  DocumentRoot $APP_DIR/public

  <Directory $APP_DIR/public>
    AllowOverride all
    Options -MultiViews
    Require all granted
  </Directory>

  PassengerEnabled on
  PassengerRuby $rb
  PassengerAppEnv production

  XSendFile on
  XSendFilePath $APP_DIR/storage

  ErrorLog \${APACHE_LOG_DIR}/cafe_grader_error.log
  CustomLog \${APACHE_LOG_DIR}/cafe_grader_access.log combined
</VirtualHost>
EOF
  sudo a2ensite cafe_grader
  chmod o+x "$HOME"   # let www-data traverse into $HOME (Ubuntu home is 750)

  echo "  Validating Apache configuration..."
  if ! sudo apache2ctl configtest 2>&1; then
    echo "  ERROR: Apache config test failed (module=$module_so root=$root ruby=$rb)."
    exit 1
  fi
  sudo systemctl restart apache2
  sudo systemctl enable apache2 mysql   # explicit boot contract
  echo "  Apache + Passenger configured (apache2 + mysql enabled on boot)."
  cg_ufw_allow_if_active 80
}

# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------
_cg_unit_path_env() {   # shared PATH= line so systemd never hits an RVM login shell
  echo "Environment=PATH=$HOME/.rbenv/shims:$HOME/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

cg_write_solid_queue_service() {
  cg_section "Installing Solid Queue systemd service"
  local bundle_bin; bundle_bin="$(rbenv which bundle)"
  sudo tee /etc/systemd/system/solid_queue.service > /dev/null <<EOF
[Unit]
Description=Solid Queue for Cafe-Grader
After=network.target mysql.service
Wants=mysql.service

[Service]
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=$bundle_bin exec rails solid_queue:start
Environment=RAILS_ENV=production
$(_cg_unit_path_env)
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable solid_queue.service
}

# Oneshot that refreshes the whenever crontab on boot. $1="mysql" ties it to the DB.
cg_write_startup_service() {
  local needs_mysql="${1:-}" bundle_bin after wants=""
  bundle_bin="$(rbenv which bundle)"
  if [ "$needs_mysql" = "mysql" ]; then
    after="network.target mysql.service solid_queue.service"; wants="Wants=mysql.service"
  else
    after="network.target"
  fi
  sudo tee /etc/systemd/system/cafe_grader_startup.service > /dev/null <<EOF
[Unit]
Description=Update Cafe-Grader whenever crontab after reboot
After=$after
$wants

[Service]
Type=oneshot
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=$bundle_bin exec whenever --update-crontab
Environment=RAILS_ENV=production
$(_cg_unit_path_env)
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable cafe_grader_startup.service
}

# Grader workers. Grader.restart(N) spawns N detached children then returns;
# Type=simple + RemainAfterExit=yes keeps the unit "active". NO Restart= on purpose
# (re-firing would double-spawn); dead workers are respawned by Grader.watchdog
# (the whenever cron). $1="mysql" adds the DB dependency (single-server).
cg_write_workers_service() {
  local needs_mysql="${1:-}" bundle_bin after wants=""
  bundle_bin="$(rbenv which bundle)"
  if [ "$needs_mysql" = "mysql" ]; then
    after="network.target mysql.service solid_queue.service cafe_grader_startup.service"; wants="Wants=mysql.service"
  else
    after="network.target cafe_grader_startup.service"
  fi
  sudo tee /etc/systemd/system/cafe_grader_workers.service > /dev/null <<EOF
[Unit]
Description=Cafe-Grader grader workers
After=$after
$wants

[Service]
Type=simple
User=$LINUX_USER
WorkingDirectory=$APP_DIR
ExecStart=$bundle_bin exec rails runner "Grader.restart($WORKER_COUNT)"
Environment=RAILS_ENV=production
$(_cg_unit_path_env)
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable cafe_grader_workers.service
}

# Daily cron to purge old isolate submission dirs (worker/single grading hosts).
cg_install_isolate_cleanup_cron() {
  local job="0 2 * * * find $CAFE_DIR/judge/isolate_submission/ -maxdepth 1 -mtime +1 -exec rm -rf {} \\; 2>/dev/null"
  ( crontab -l 2>/dev/null | grep -qF "isolate_submission" ) || \
    ( crontab -l 2>/dev/null; echo "$job" ) | crontab -
  echo "  isolate_submission cleanup cron installed (daily 02:00)."
}
