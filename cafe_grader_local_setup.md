# Cafe-Grader Local Setup & Testing

Testing and running the application locally without deploying it to a full production server is straightforward. You can start all development services simultaneously using the provided `Procfile.dev`.

## 1. Quick Setup Script (Recommended)

The easiest way to set up the development environment is to use the provided setup script. The script automatically initializes required configuration files from their `.SAMPLE` templates to prevent boot errors, and installs all prerequisites.

**Run this from your `cafe-grader-web` project directory**:

```bash
./setup_local_wsl.sh
```

This script will:
- Install all system dependencies (MySQL, etc.)
- Install rbenv and Ruby 3.4.4
- Install Ruby gems
- Start MySQL and prepare the database

After running the script, complete the manual steps it outputs (credentials, database config, seeds).

## 2. Manual Setup (Alternative)

If you prefer to run the steps yourself instead of the script, `setup_local_wsl.sh` is
the authoritative reference — read it top-to-bottom. In short it: installs MySQL + build
deps, installs rbenv + Ruby 3.4.4 + bundler, copies the `config/*.SAMPLE` templates and
patches `database.yml` for local dev, creates the `grader_user` MySQL account, runs
`bundle install`, generates a matched `master.key` via `credentials:edit`, and runs
`bin/rails db:prepare` (idempotent — safe to re-run). Do **not** copy
`credentials.yml.SAMPLE` over a random `master.key`; that mismatches and crashes boot.

## 3. Start the Dev Server
Open a terminal in the root folder and run:
```bash
bin/dev
```

This command uses Foreman (or similar) to concurrently start:
- The Puma web server on port `3000` (accessible at `http://localhost:3000`).
- The CSS watcher (`bundle exec rails dartsass:watch`) to automatically compile SCSS on changes.
- The background job queue (`bin/rails solid_queue:start`).

If you wish to run automated tests:
- **All tests**: `bin/rails test`
- **System tests** (UI tests): `bin/rails test:system`
- **API Specs**: `bundle exec rspec spec/requests/api/v1/`

## 4. Web App vs. Grader Worker Testing (WSL Limitation)
*Important Note:* The core grader sandboxing tool (`ioi/isolate`) relies on strict Linux kernel features (cgroups) and **cannot easily run on WSL2** without compiling a custom WSL kernel. 
Because of this, local development is usually split:
1. **Web App & UI Testing**: You can run the web server, database, and background queues perfectly inside WSL. This allows you to build features, manage problems, and test the UI.
2. **Actual Code Grading**: To test the actual compilation and execution of student code, it is highly recommended to use a full Ubuntu Virtual Machine (e.g., VirtualBox, VMware) or a dedicated staging server rather than WSL.
