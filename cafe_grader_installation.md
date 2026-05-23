# Cafe-Grader Installation Guide

Target OS: **Ubuntu 22.04 LTS**. All three installation paths use the same scripts — run as a normal user with `sudo` privileges, not as root.

---

## Quick Start — Use the Scripts

The shell scripts fully automate every step. The only manual action after running a script is `sudo reboot`.

| Script | Purpose |
|---|---|
| `install_single_server.sh` | Everything on one machine |
| `install_web_db_server.sh` | Web app + database (Server 1 of 3) |
| `install_worker_server.sh <IP>` | Grader workers (Server 2 & 3) |

```bash
# Single server
bash install_single_server.sh

# 3-server: run on Server 1 first, then on each worker
bash install_web_db_server.sh
bash install_worker_server.sh <SERVER_1_IP>
```

After the script completes, run `sudo reboot`. Everything starts automatically on boot.

**Default login:** username `root`, password `ioionrails` — change immediately after first login.

---

## 1. Single-Server Installation (Manual Steps)

This section documents what `install_single_server.sh` does, step by step, for reference or if you need to run steps individually.

### Step 1 — Install System Packages

Installs Apache, MySQL, build tools, language compilers, and `libcurl4-openssl-dev` (required by Phusion Passenger to find `curl-config`).

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  apache2 apache2-dev \
  mysql-server git software-properties-common \
  libmysqlclient-dev libcap-dev libsystemd-dev libseccomp-dev pkg-config \
  apt-transport-https postgresql postgresql-server-dev-all \
  openssl unzip curl libcurl4-openssl-dev

# Language compilers / runtimes for grading
sudo apt install -y \
  ghc g++ openjdk-21-jdk fpc \
  php-cli php-readline \
  golang-go cargo python3-venv
```

### Step 2 — Install Ruby via rbenv

rbenv installs Ruby per-user without affecting system Ruby. The `~/.gem/ruby` cleanup prevents stale system gem stubs from conflicting with rbenv-managed gems.

```bash
sudo apt install -y \
  curl libssl-dev libreadline-dev zlib1g-dev \
  autoconf bison build-essential libyaml-dev \
  libncurses5-dev libffi-dev libgdbm-dev

curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash

echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc

rbenv install 3.4.4
rbenv global 3.4.4

# Remove stale system gem stubs that conflict with rbenv
rm -rf "$HOME/.gem/ruby"

gem install bundler --no-document
```

### Step 3 — Prepare MySQL

Creates two databases (`grader` and `grader_queue`) and a dedicated user. The `grader_queue` database is used by Solid Queue for background jobs.

```bash
sudo systemctl start mysql

sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`grader\`;"
sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS \`grader_queue\`;"
sudo mysql -u root -e "DROP USER IF EXISTS 'grader_user'@'localhost';"
sudo mysql -u root -e "CREATE USER 'grader_user'@'localhost' IDENTIFIED BY 'grader_pass';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`grader\`.* TO 'grader_user'@'localhost';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`grader_queue\`.* TO 'grader_user'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"
```

### Step 4 — Install ioi/isolate

`ioi/isolate` is the sandboxing tool that runs student submissions in a secure container. It must be cloned into a **permanent location** (not `/tmp`) because the `isolate.service` symlink and `/run/isolate/cgroup` socket both reference the source directory at runtime — `/tmp` is wiped on reboot.

The `isolate` system user and its `subuid`/`subgid` entries are required by isolate v2.5+ for user-namespace sandboxing. Without them every `isolate --init` call fails with "User isolate not found in /etc/subuid", causing workers to appear permanently idle.

We use the range `200000:65536` (not `100000:65536`) to avoid a silent UID collision with Ubuntu's default user namespace allocation.

```bash
git clone https://github.com/ioi/isolate.git ~/isolate
cd ~/isolate
make isolate
sudo make install

# Create isolate system user
sudo useradd --system --no-create-home --shell /usr/sbin/nologin isolate

# Register subuid/subgid for user namespace sandboxing
echo "isolate:200000:65536" | sudo tee -a /etc/subuid
echo "isolate:200000:65536" | sudo tee -a /etc/subgid

# Disable swap (isolate requires no swap for reproducible memory limits)
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^\(.*\)$/#\1/' /etc/fstab
[ -f /swap.img ] && sudo rm -f /swap.img
```

### Step 5 — Configure Isolate Kernel Settings

Three persistent kernel settings are required for isolate to function correctly across reboots:

**5a. Symlink isolate's own systemd service** (watches cgroups for the sandbox):
```bash
sudo ln -sf ~/isolate/systemd/isolate.service /etc/systemd/system/isolate.service
```

**5b. Create `set-ioi-isolate.service`** (disables transparent hugepages and sets core pattern at boot — these cannot be set in `/etc/sysctl.d` because they are not sysctl knobs):

```bash
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
```

**5c. Disable address-space randomisation** (ensures reproducible execution timing):
```bash
echo "kernel.randomize_va_space=0" | sudo tee -a /etc/sysctl.d/99-sysctl.conf
```

Enable all services:
```bash
sudo systemctl daemon-reload
sudo systemctl enable set-ioi-isolate.service
sudo systemctl enable isolate.service
```

### Step 6 — Enable cgroup Memory in GRUB

isolate uses Linux cgroups to enforce memory limits on submissions. The `cgroup_enable=memory` flag enables memory accounting in the kernel. `swapaccount=1` enables swap accounting (required on Ubuntu 22.04 when cgroup v1 is active).

```bash
sudo sed -i \
  's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 cgroup_enable=memory swapaccount=1"/' \
  /etc/default/grub
sudo update-grub
```

> **A reboot is required after this step for all kernel and swap changes to take effect.**

### Step 7 — Clone and Configure Cafe-Grader

Clones the app and initialises all config files from their `.SAMPLE` templates. Rails will not boot if any of these files is missing.

`database.yml` is always regenerated from the sample and then patched with the correct credentials so the sample's default placeholder values (`username: grader`, `password: grader`) never reach the database layer.

A `dartsass_silence_deprecations.rb` initializer is created to suppress Bootstrap's Dart Sass `@import` deprecation warnings from cluttering the log.

```bash
mkdir -p ~/cafe_grader && cd ~/cafe_grader
git clone https://github.com/MaxzyMVT/cafe-grader-web.git web
cd web

cp config/application.rb.SAMPLE config/application.rb
cp config/llm.yml.SAMPLE        config/llm.yml

# Regenerate and patch database.yml
cp config/database.yml.SAMPLE config/database.yml
sed -i "s/username:.*/username: grader_user/" config/database.yml
sed -i "s/password:.*/password: grader_pass/" config/database.yml
sed -i "s/host:.*/host: localhost/"           config/database.yml

# Regenerate and patch worker.yml
cp config/worker.yml.SAMPLE config/worker.yml
sed -i "s|web:.*|web: http://localhost|" config/worker.yml

bundle install
```

### Step 8 — Generate Rails Master Key

The master key encrypts `credentials.yml.enc`. It is generated once with `openssl` and must be backed up — if it is lost, encrypted credentials cannot be decrypted and the app cannot boot.

```bash
cp config/credentials.yml.SAMPLE config/credentials.yml.enc
openssl rand -hex 32 > config/master.key
chmod 600 config/master.key
```

> **Back up `config/master.key` immediately after generation.**

### Step 9 — Create Python Virtual Environment

The grader engine uses a dedicated Python venv at `/venv/grader` so Python submissions run in an isolated environment without affecting system Python packages.

```bash
sudo python3 -m venv /venv/grader
sudo /venv/grader/bin/pip install --upgrade pip --quiet
```

### Step 10 — Initialise Database and Compile Assets

The script checks whether the database already has tables. On a fresh install it runs `db:setup`; on a re-run it runs `db:migrate` instead, which avoids the MySQL foreign key constraint crash that occurs when `db:setup` tries to `DROP TABLE active_storage_blobs` before `active_storage_variant_records` (which has a foreign key pointing to it).

```bash
cd ~/cafe_grader/web

# Fresh install
RAILS_ENV=production bundle exec rails db:setup DISABLE_DATABASE_ENVIRONMENT_CHECK=1

# Re-run (if tables already exist)
# RAILS_ENV=production bundle exec rails db:migrate

RAILS_ENV=production bundle exec rails db:seed
RAILS_ENV=production bundle exec rails dartsass:build
RAILS_ENV=production bundle exec rails assets:precompile
```

### Step 11 — Install Phusion Passenger + Apache

Passenger is the Ruby application server that integrates with Apache. The key steps here ensure Passenger uses the correct rbenv-managed Ruby binary rather than the system Ruby shim:

- `rbenv which ruby` resolves the **absolute binary path** (e.g. `~/.rbenv/versions/3.4.4/bin/ruby`). Apache needs this exact path — using the rbenv shim at `~/.rbenv/shims/ruby` causes worker processes to fail.
- `rack` is installed via the same `gem` binary as `passenger` so Passenger's pre-flight check finds it in the correct gem home.
- `chmod o+x "$HOME"` grants Apache (`www-data`) traversal permission into the home directory. Ubuntu sets home dirs to `chmod 750` by default, causing a 403 Forbidden even with a correct vhost config.
- `apache2ctl configtest` validates the configuration before restarting Apache, surfacing errors clearly instead of crashing the service silently.

```bash
RBENV_RUBY="$(rbenv which ruby)"
RBENV_GEM="$(rbenv which gem)"

"$RBENV_GEM" install passenger --no-document
"$RBENV_GEM" install rack --no-document

# Build the Apache module (run as current user, not sudo, to inherit rbenv env)
PASSENGER_INSTALL=$("$RBENV_GEM" contents passenger | grep "passenger-install-apache2-module$" | head -1)
"$RBENV_RUBY" "$PASSENGER_INSTALL" --auto --languages ruby

PASSENGER_ROOT=$(passenger-config --root)
PASSENGER_RUBY="$RBENV_RUBY"
PASSENGER_MODULE=$(find "$PASSENGER_ROOT" -name mod_passenger.so | head -1)

# Write correct .load and .conf files (installer's versions may use wrong ruby path)
sudo tee /etc/apache2/mods-available/passenger.load <<EOF
LoadModule passenger_module $PASSENGER_MODULE
EOF
sudo tee /etc/apache2/mods-available/passenger.conf <<EOF
<IfModule mod_passenger.c>
  PassengerRoot $PASSENGER_ROOT
  PassengerDefaultRuby $PASSENGER_RUBY
</IfModule>
EOF

sudo a2enmod passenger
sudo a2dissite 000-default

sudo tee /etc/apache2/sites-available/cafe_grader.conf <<EOF
<VirtualHost *:80>
  ServerName localhost
  DocumentRoot $HOME/cafe_grader/web/public

  <Directory $HOME/cafe_grader/web/public>
    AllowOverride all
    Options -MultiViews
    Require all granted
  </Directory>

  PassengerEnabled on
  PassengerRuby $PASSENGER_RUBY
  PassengerAppEnv production

  ErrorLog \${APACHE_LOG_DIR}/cafe_grader_error.log
  CustomLog \${APACHE_LOG_DIR}/cafe_grader_access.log combined
</VirtualHost>
EOF

sudo a2ensite cafe_grader
chmod o+x "$HOME"        # allow www-data to traverse home directory

sudo apache2ctl configtest
sudo systemctl restart apache2
```

### Step 12 — Install Solid Queue as a systemd Service

Solid Queue processes background jobs (LLM requests, PDF generation, etc.). It is registered as a systemd service so it starts automatically on boot.

The `ExecStart` uses the absolute rbenv `bundle` binary path (resolved at install time via `rbenv which bundle`) rather than going through a bash login shell. This prevents RVM — if installed on the same system — from overriding rbenv and picking the wrong Ruby at service start.

```bash
RBENV_BUNDLE_BIN="$(rbenv which bundle)"

sudo tee /etc/systemd/system/solid_queue.service <<EOF
[Unit]
Description=Solid Queue for Cafe-Grader
After=network.target mysql.service
Wants=mysql.service

[Service]
User=$USER
WorkingDirectory=$HOME/cafe_grader/web
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
```

### Step 13 — Install Grader Worker Services

Two systemd services manage the grader workers:

**`cafe_grader_startup.service`** — A oneshot service that updates the `whenever` crontab on each boot. The crontab runs `Grader.watchdog` every minute to restart any crashed worker processes.

**`cafe_grader_workers.service`** — Fires `Grader.restart(N)` which spawns N detached worker processes. Each worker writes its log to `log/grader-N.txt`. The worker count is auto-detected as `CPU_cores - 2` (minimum 1) so the web server and database always have dedicated CPU headroom.

Both services use `RemainAfterExit=yes` because the forking calls return immediately after spawning the child processes — without this flag systemd would mark the services as failed the moment the Rails runner exits.

```bash
RBENV_BUNDLE_BIN="$(rbenv which bundle)"
WORKER_COUNT=$(( $(nproc) > 2 ? $(nproc) - 2 : 1 ))

# Crontab updater
sudo tee /etc/systemd/system/cafe_grader_startup.service <<EOF
[Unit]
Description=Update Cafe-Grader whenever crontab after reboot
After=network.target mysql.service solid_queue.service
Wants=mysql.service

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$HOME/cafe_grader/web
ExecStart=$RBENV_BUNDLE_BIN exec whenever --update-crontab
Environment=RAILS_ENV=production
Environment=PATH=$HOME/.rbenv/shims:$HOME/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Grader workers
sudo tee /etc/systemd/system/cafe_grader_workers.service <<EOF
[Unit]
Description=Cafe-Grader grader workers
After=network.target mysql.service solid_queue.service cafe_grader_startup.service
Wants=mysql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME/cafe_grader/web
ExecStart=$RBENV_BUNDLE_BIN exec rails runner "Grader.restart($WORKER_COUNT)"
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
sudo systemctl enable cafe_grader_workers.service
```

### Final Step — Reboot

```bash
sudo reboot
```

After reboot these services start automatically: Apache + Passenger (port 80), Solid Queue, and the grader workers.

---

## 2. Three-Server Setup (1 Web/DB + 2 Grader Workers)

Run `install_web_db_server.sh` on Server 1, then `install_worker_server.sh <SERVER_1_IP>` on each worker. After both scripts complete, reboot each server.

### Server 1 — Web and Database Node

Runs Steps 1–3 and 7–12 from the single-server guide above, with two differences:

**MySQL is configured for remote access** so worker nodes can connect:

```bash
# Allow all interfaces (restrict to worker IPs via firewall in production)
sudo sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' \
  /etc/mysql/mysql.conf.d/mysqld.cnf
sudo systemctl restart mysql

# Additional wildcard user for worker nodes
sudo mysql -u root -e "CREATE USER 'grader_user'@'%' IDENTIFIED BY 'grader_pass';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`grader\`.* TO 'grader_user'@'%';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`grader_queue\`.* TO 'grader_user'@'%';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"
```

> Ensure your firewall allows TCP port 3306 **only from the worker node IPs**.

**No grader workers or isolate setup** — Steps 4, 5, 6, and 13 are omitted. `cafe_grader_startup.service` on this server only updates the `whenever` crontab; it does not start grader workers.

### Servers 2 & 3 — Grader Worker Nodes

Run Steps 1–6 and 7–9, 12–13 from the single-server guide, with these differences:

**No Apache, no Passenger, no Solid Queue** — Steps 11 and 12 are omitted. Workers connect directly to Server 1's database and do not serve HTTP.

**`database.yml` points to Server 1's IP** instead of `localhost`:
```bash
sed -i "s/host:.*/host: <SERVER_1_IP>/" config/database.yml
```

**`worker.yml` points to Server 1's URL**:
```bash
sed -i "s|web:.*|web: http://<SERVER_1_IP>|" config/worker.yml
```

**Language compilers are installed** (same as single-server Step 1) since these machines actually compile and run student code.

After reboot, `cafe_grader_workers.service` starts the grader workers automatically. Check worker health:

```bash
sudo systemctl status cafe_grader_workers.service
tail -f ~/cafe_grader/web/log/grader-1.txt
```