#!/bin/bash
# Cafe-Grader Local Web Development Setup Script (WSL/Ubuntu)
# Sets up the environment needed to run the web interface locally via `bin/dev`.
# Does NOT install Apache, compilers, or configure production remote databases.
#
# IMPORTANT: Run this script from your existing cafe-grader-web project directory.
# Do NOT clone a separate copy — use your local codebase.
#
# Usage: bash setup_local_wsl.sh

set -e

RUBY_VERSION="3.4.4"
DB_USER="grader_user"
DB_PASS="grader_pass"

echo "============================================================"
echo " Cafe-Grader Local Web Environment Setup (WSL/Ubuntu)"
echo "============================================================"

# ---------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------
echo "[1/6] Installing system dependencies..."
sudo apt update
sudo apt install -y \
  mysql-server libmysqlclient-dev \
  git curl unzip libpq-dev \
  libssl-dev libreadline-dev zlib1g-dev \
  autoconf bison build-essential libyaml-dev \
  libncurses5-dev libffi-dev libgdbm-dev

# ---------------------------------------------------------------
# 2. rbenv and Ruby
# ---------------------------------------------------------------
echo "[2/6] Installing rbenv and Ruby $RUBY_VERSION..."

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
gem install bundler --no-document

echo "  Ruby: $(ruby --version) at $(which ruby)"

# ---------------------------------------------------------------
# 3. Move to project directory
# ---------------------------------------------------------------
echo "[3/6] Preparing project directory..."
cd "$(dirname "$0")"

# Fix Windows line endings (CRLF → LF) on bin/* scripts — common WSL issue
echo "  Fixing CRLF line endings on bin/* scripts..."
sed -i 's/\r$//' bin/*

# ---------------------------------------------------------------
# 4. Initialise configuration files from samples
# ---------------------------------------------------------------
echo "[4/6] Copying sample configuration files..."

for file in application.rb database.yml llm.yml worker.yml; do
  if [ ! -f "config/$file" ]; then
    echo "  Creating config/$file from sample..."
    cp "config/$file.SAMPLE" "config/$file"
  else
    echo "  config/$file already exists, skipping."
  fi
done

# Patch database.yml for local dev credentials
echo "  Patching config/database.yml with local credentials..."
sed -i "s/username:.*/username: $DB_USER/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/host:.*/host: localhost/"        config/database.yml

# ---------------------------------------------------------------
# 5. Install gems and build CSS
# ---------------------------------------------------------------
echo "[5/6] Installing Ruby gems..."
bundle install

echo "  Building CSS assets..."
bundle exec rails dartsass:build

# ---------------------------------------------------------------
# 6. Start MySQL and create the database user
# ---------------------------------------------------------------
echo "[6/6] Starting MySQL and creating database user..."
sudo service mysql start || sudo systemctl start mysql

sudo mysql -u root -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
sudo mysql -u root -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON \`grader%\`.* TO '$DB_USER'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"
echo "  MySQL user '$DB_USER' created."

# ---------------------------------------------------------------
# Print remaining manual steps
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " Setup complete! Manual steps remaining:"
echo "============================================================"
echo ""
echo "STEP 1 — Create Rails master key (run once):"
echo "  export EDITOR=nano"
echo "  bundle exec rails credentials:edit"
echo ""
echo "STEP 2 — Set up the database (creates schema + seeds data):"
echo "  bundle exec rails db:setup"
echo ""
echo "STEP 3 — Start the local development server:"
echo "  bin/dev"
echo "  Then open http://localhost:3000"
echo ""
echo "Default login: username=root, password=<value in db/seeds.rb or GRADER_ADMIN_PASSWORD>"
echo ""
echo "NOTE: config/worker.yml — if you need LLM features locally,"
echo "  set the 'web:' key to http://localhost:3000."
echo ""
echo "NOTE: The grader sandboxing tool (ioi/isolate) cannot run on WSL2."
echo "  Code submission grading requires a full Ubuntu VM or staging server."