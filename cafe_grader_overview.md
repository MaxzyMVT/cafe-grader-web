# Cafe-Grader Overview

## 1. Summary of Cafe-Grader

Cafe-Grader is an online programming contest and assignment grading platform, primarily used at Chulalongkorn University. Its main capabilities include:

- **Code Evaluation**: Students submit code that is automatically compiled and evaluated against predefined test cases.
- **Role Management**: Supports user roles such as admin, TA, group editor, reporter, and student.
- **Operating Modes**: Can run in *Contest mode* (time-bound competitions) or *Group mode* (assignments organised by groups).
- **Extensive Language Support**: C, C++, Python, Java, Haskell, Ruby, Go, Rust, PHP, and Pascal.
- **Secure Sandboxing**: Uses `ioi/isolate` to run student submissions in an isolated container, protecting the host server.
- **LLM Assistance & Audit Logging**: Supports LLM-powered hints and comprehensive audit logging for all administrative actions.

---

## 2. Framework Overview

Cafe-Grader is built with **Ruby on Rails 8.0.0** (Ruby 3.4.4). Rails follows the **MVC (Model-View-Controller)** pattern:

- **Models** — Business logic and database interactions (`User`, `Problem`, `Submission`, `Contest`). Uses Active Record with MySQL.
- **Views** — Presentation layer built with HAML templates, Hotwire (Turbo + Stimulus), and Bootstrap 5.
- **Controllers** — Handle HTTP requests, coordinate models, and return views or JSON API responses.

Additional components:

- **Solid Queue** — Background job processing (LLM requests, PDF generation, etc.)
- **Solid Cache** — Database-backed caching layer
- **Propshaft + Importmap** — Asset pipeline. No Node.js or Yarn is required for production.
- **dartsass-rails** — SCSS compilation

---

## 3. Technology Stack

| Component | Technology |
|---|---|
| Operating System | Ubuntu 22.04 LTS |
| Framework | Ruby on Rails 8.0.0 |
| Language | Ruby 3.4.4 |
| Database | MySQL 8.0+ |
| Background Jobs | Solid Queue |
| Caching | Solid Cache |
| Asset Pipeline | Propshaft, Importmap |
| CSS Preprocessor | dartsass-rails |
| Sandboxing | `ioi/isolate` (requires Linux cgroups v2) |

---

## 4. File Structure

```text
cafe-grader-web/
├── .agents/          # Agent-related workflow configurations
├── .claude/          # Specific guides or configurations for Claude/AI
├── app/              # Core application code (Models, Views, Controllers)
│   ├── controllers/  # HTTP request handling and logic bridging routes, models, and views
│   ├── models/       # Database schemas and business logic
│   ├── views/        # HAML templates and frontend presentation
│   └── services/     # Complex business logic (e.g., LLM handlers)
├── bin/              # Executable scripts (rails, dev, setup)
├── config/           # Configuration files (routes, database.yml, worker.yml)
├── data/             # Local data or scripts used by the app
├── db/               # Database migrations and seed files
├── doc/              # Generated documentation
├── lib/              # Custom libraries, rake tasks, extensions
├── log/              # Application and server log files
├── public/           # Static files served directly (e.g., 404 pages)
├── script/           # Automation and utility scripts
├── spec/             # RSpec tests (API specs and Swagger)
├── swagger/          # API documentation (rswag)
├── test/             # MiniTest directory (models, controllers, system tests)
├── vendor/           # Third-party code and plugins
├── Gemfile           # Ruby gem dependencies
├── Procfile.dev      # Development process configuration (Foreman)
├── Rakefile          # Ruby task runner
└── CLAUDE.md         # Project conventions and developer guide
```

---

## 5. Deployment Options

There are three ways to deploy Cafe-Grader:

| Option | Script | Use when |
|---|---|---|
| Single server | `install_single_server.sh` | One machine runs everything — web, DB, and grading |
| 3-server split | `install_web_db_server.sh` + `install_worker_server.sh` | Scale out grading to dedicated worker machines |
| Local development | `setup_local_wsl.sh` | Running locally on Ubuntu or WSL2 for development |

For detailed installation instructions see the [Installation Guide](cafe_grader_installation.md).
For local development instructions see the [Local Setup Guide](cafe_grader_local_setup.md).

---

## 6. Administrator Credentials

After running the installation script, the system creates a default administrator account.

- **Username**: `root`
- **Password**: `ioionrails` (default — **change immediately after first login**)

The password can be customised before installation by setting `GRADER_ADMIN_PASSWORD` before running any setup script:

```bash
export GRADER_ADMIN_PASSWORD='your_secure_password_here'
bash install_single_server.sh
```