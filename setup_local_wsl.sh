#!/bin/bash
# Cafe-Grader Local Web Development Setup Script (WSL/Ubuntu)
# Sets up the environment needed to run the web interface locally via `bin/dev`.
# Does NOT install Apache, compilers, or configure production databases.
#
# IMPORTANT: Run this script from your cafe-grader-web project directory.
# Do NOT clone a separate copy — use your local codebase.
#
# Usage: bash setup_local_wsl.sh

# -e: abort on error  -u: error on unset var  -o pipefail: a pipe fails if any stage fails.
set -euo pipefail

RUBY_VERSION="3.4.4"
DB_USER="grader_user"
DB_PASS="grader_pass"

echo "============================================================"
echo " Cafe-Grader Local Web Environment Setup (WSL/Ubuntu)"
echo "============================================================"

# ---------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------
echo "[1/7] Installing system dependencies..."
sudo apt update
sudo apt install -y \
  mysql-server libmysqlclient-dev \
  git curl unzip libpq-dev \
  libssl-dev libreadline-dev zlib1g-dev \
  autoconf bison build-essential libyaml-dev \
  libncurses5-dev libffi-dev libgdbm-dev \
  openssl

# ---------------------------------------------------------------
# 2. Ruby via rbenv
# ---------------------------------------------------------------
echo "[2/7] Installing rbenv and Ruby $RUBY_VERSION..."

if [ ! -d "$HOME/.rbenv" ]; then
  curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash
fi

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init -)"

if ! grep -q 'rbenv init' ~/.bashrc; then
  echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
  echo 'eval "$(rbenv init -)"' >> ~/.bashrc
fi

if ! rbenv versions | grep -q "$RUBY_VERSION"; then
  rbenv install "$RUBY_VERSION"
fi

rbenv global "$RUBY_VERSION"
rbenv shell "$RUBY_VERSION"

# Remove stale system-level gem stubs that conflict with rbenv-managed Ruby.
if [ -d "$HOME/.gem/ruby" ]; then
  rm -rf "$HOME/.gem/ruby"
fi

gem install bundler --no-document
echo "  Ruby: $(ruby --version) at $(which ruby)"

# ---------------------------------------------------------------
# 3. Move to project directory
# ---------------------------------------------------------------
echo "[3/7] Preparing project directory..."
cd "$(dirname "$0")"

# Fix Windows line endings (CRLF -> LF) on bin/* scripts — common WSL issue
echo "  Fixing CRLF line endings on bin/* scripts..."
sed -i 's/\r$//' bin/*

# ---------------------------------------------------------------
# 4. Initialise configuration files from samples
# ---------------------------------------------------------------
echo "[4/7] Copying and patching configuration files..."

for file in application.rb llm.yml worker.yml; do
  if [ ! -f "config/$file" ]; then
    echo "  Creating config/$file from sample..."
    cp "config/$file.SAMPLE" "config/$file"
  else
    echo "  config/$file already exists, skipping."
  fi
done

# Always regenerate and patch database.yml with local dev credentials.
# SAMPLE defaults to  username: grader / password: grader  which will fail db:setup.
cp config/database.yml.SAMPLE config/database.yml
sed -i "s/username:.*/username: $DB_USER/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/host:.*/host: localhost/"        config/database.yml
echo "  database.yml patched with local credentials."

# Patch worker.yml for local dev
sed -i "s|web:.*|web: http://localhost:3000|" config/worker.yml
echo "  worker.yml patched (web: http://localhost:3000)."

# Silence Dart Sass @import deprecation warnings from Bootstrap.
cat > config/initializers/dartsass_silence_deprecations.rb <<'RUBYEOF'
Rails.application.config.dartsass.build_options \
  << "--silence-deprecation=import" \
  << "--silence-deprecation=global-builtin" \
  << "--silence-deprecation=color-functions" \
  << "--silence-deprecation=mixed-decls"
RUBYEOF
echo "  Dart Sass deprecation warnings silenced."

# ---------------------------------------------------------------
# 5. MySQL: start + create user
# ---------------------------------------------------------------
echo "[5/7] Starting MySQL and creating database user..."
sudo service mysql start || sudo systemctl start mysql

sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`grader%\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"
echo "  MySQL user '$DB_USER' created."

# ---------------------------------------------------------------
# 6. Install gems + build CSS
# ---------------------------------------------------------------
echo "[6/7] Installing Ruby gems..."
bundle install

echo "  Building CSS assets..."
bundle exec rails dartsass:build

# ---------------------------------------------------------------
# 7. Rails master key + database setup
# ---------------------------------------------------------------
echo "[7/7] Generating Rails master key and setting up database..."

# Generate a MATCHED master.key + credentials.yml.enc pair. Copying
# credentials.yml.SAMPLE alongside a fresh `openssl rand` key produces a MISMATCH
# (the SAMPLE was encrypted with a different key) and crashes on boot with
# ActiveSupport::MessageEncryptor::InvalidMessage. `credentials:edit` writes a
# matched pair; EDITOR=true completes it non-interactively.
if [ ! -f config/master.key ]; then
  rm -f config/credentials.yml.enc
  EDITOR=true bundle exec rails credentials:edit
  chmod 600 config/master.key
  echo "  master.key and credentials.yml.enc generated (matched pair)."
else
  echo "  master.key already exists, skipping."
fi

# db:prepare is idempotent: it creates + loads schema + seeds on first run, and
# only runs pending migrations on subsequent runs. Unlike db:setup it does NOT
# drop/reload existing tables, so re-running this script won't crash on foreign keys.
bundle exec rails db:prepare
echo "  Database ready."

# ---------------------------------------------------------------
# Done
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Setup complete!"
echo "============================================================"
echo ""
echo "  Start the local development server:"
echo ""
echo "    bin/dev"
echo "    Then open http://localhost:3000"
echo ""
echo "  Default login  ->  username: root   password: ioionrails"
echo "  Change the password immediately after first login."
echo ""
echo "  NOTE: ioi/isolate cannot run on WSL2."
echo "  Code submission grading requires a full Ubuntu VM or staging server."
echo ""