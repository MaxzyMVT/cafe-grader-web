# Changelog

All notable changes to this project are recorded here. Format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The `[Unreleased]` section at the top accumulates changes between releases.
When a release is cut: rename it to `[X.Y.Z] — YYYY-MM-DD`, bump
`APP_VERSION`, and (optionally) tag the commit in hg/git.

## [Unreleased]

## [4.4.2-cedt03.1] — 2026-07-15


Everything below is the **CEDT03 fork's delta over upstream nattee `v4.4.2`**
(fork version `4.4.2-cedt03.1`) — new gamification/reporting features, the
`GraderConfiguration` settings and DB columns that back them, and structural /
deployment changes.

### Added

#### Features

- **Realtime scoreboard** — new `scoreboard` controller + `/scoreboard` page:
  individual/group views, auto-refresh, CSV export, and bonus / first-blood display.
- **Point-hint / loot-box gimmicks** — hints (comments) gain a point cost and a
  randomised `success_rate`, so spending points is not a guaranteed reveal and a
  failure can still deduct points; hints can be time-gated with `available_after`.
- **Submission limits** — per-problem cap (`problems.max_submissions`) with the
  remaining count shown to students, a per-user override
  (`contests_users.extra_sub_limit`), and setter/admin exemption.
- **First-blood bonus** — configurable bonus for the first N solvers of a problem
  (`problems.bonus_first_blood`, `problems.first_n_bloods`), shown on the scoreboard.
- **Theme presets** — user-selectable UI themes stored in `users.theme`.
- **Extended statistics report** — `report#extended_stat`: most-effort,
  latest / first-blood counts, shortest-code, and fastest-runtime, filterable by
  language / tags / problems / time range.
- **Group scoring modes** — group total on the main list shown as a sum or the
  max-per-problem.
- **Tag sorting & colours** — tags carry a display order (`tags.number`) and a hex
  colour (`tags.color`, default `#6C757D`), with move-up/down/reorder controls.
- **Problem-setter role** — a new `problem_setter` role with its own scoping and
  admin management (`problem_setter_query`, group/contest assignment, `bulk_manage`).
- **Problem & testcase ordering** — `problems.number` plus move-up/down/reorder for
  problems, testcases, and tags; quick-add testcase; add-problem-by-tag.
- **Help page** — `help` controller + `/help` (grading legend / clarification help).
- **Group member self-rename** — opt-in per group (`groups.allow_user_change_name`).
- **Advisory RAM-headroom check** in the grading installers — warns when physical RAM
  is below `WORKER_COUNT × 1 GB + system overhead`, since isolate runs with swap off.

#### Settings (new `GraderConfiguration` keys)

- `gimmicks.enable_first_bloods`, `gimmicks.enable_submission_limits` — global toggles.
- `gimmicks.disable_penalty`, `gimmicks.disable_bonus` — scoreboard penalty/bonus display.
- `system.scoreboard_enabled`, `system.scoreboard_include_admins`,
  `system.scoreboard_view_level` (`all` / `user` / `admin`).
- `system.statistic_include_admins` — include admins in the statistics report.
- `system.group_score_type` — group score on the main list (sum / max).

#### Schema (new columns)

- `problems`: `max_submissions`, `bonus_first_blood` (decimal), `first_n_bloods`, `number`.
- `comments`: `point_cost`, `all_points`, `success_rate`, `available_after`.
- `comment_reveals`: `points_deducted`, `is_success`.
- `users.theme`; `tags.number`, `tags.color`; `contests_users.extra_sub_limit`;
  `groups.allow_user_change_name`; a seeded `problem_setter` role.

#### Structure / tooling

- New `deploy/` tree: consolidated Ubuntu installers (`install_single_server.sh`,
  `install_web_db_server.sh`, `install_worker_server.sh`, all with `--cloud`) sharing
  `deploy/lib/common.sh`; SSH-pull and Huawei OBS/CBR backups under `deploy/backup/`;
  `setup_local_wsl.sh` for dev.
- `config/initializers/dartsass_silence_deprecations.rb`; `en`/`th` locale additions;
  many new routes (move/reorder, `bulk_manage`, `extra_sub_limit_user`,
  `add_problem_by_tag`, `direct_edit_problem`, `extended_stat`).
- `.gitattributes` pins `*.sh`/`*.SAMPLE` to LF so shell scripts never reach a Linux
  deploy box with CRLF line endings.

### Changed

- **Config namespace `point_hint.*` → `gimmicks.*`** (and `system.disable_penalty` →
  `gimmicks.disable_penalty`); the boolean `system.scoreboard_public_accessible` was
  replaced by the tri-state `system.scoreboard_view_level`. (Data migrations rename the
  keys in place — no manual config edit needed on upgrade.)
- **Installer scripts consolidated** — the 6 install scripts (~2900 lines, ~90 %
  duplicated) became 3 role scripts + a shared `deploy/lib/common.sh` (~800 lines);
  cloud variants folded into a `--cloud` flag (`install_*_cloud.sh` removed); web/DB and
  grading installers now `systemctl enable apache2 mysql`; backup defaults aligned to
  the installer layout (`grader_user`, `/home/grader/cafe_grader/web`). Installation /
  setup docs trimmed to point at the scripts as the source of truth.

### Fixed

- **Cloud/WSL installers produced an unbootable install** — the cloud install scripts
  and `setup_local_wsl.sh` copied `credentials.yml.SAMPLE` alongside a fresh random
  `master.key`, a mismatched pair that crashed `db:setup` and every boot with
  `ActiveSupport::MessageEncryptor::InvalidMessage`. They now generate a matched pair
  via `credentials:edit`, like the non-cloud scripts always did.
- **Separate worker servers collided** — worker installers never set `worker_id`, so
  every worker node registered as `worker_id=1`, sharing `GraderProcess` rows and
  thrashing the watchdog. `install_worker_server.sh` now takes a validated, unique
  `WORKER_ID` argument (`bash install_worker_server.sh <WEB_DB_IP> <ID>`).

## [4.4.2] — 2026-07-01

### Fixed

- **Report filters: user-group dropdown now respects reporter scope** — on the
  report filter pages (Best Score / Submissions / User Activity / AI Assist),
  the "Only users from this group" dropdown listed **every** group in the
  system for non-admins; it now lists only the groups the user can report on
  (`@groups`), matching the problem-group dropdown. No user data leaked (results
  were already intersected with `reportable_users`), but group names no longer
  do. The `login` analytics report now sets `@groups` so its user filter renders.

### Added

- **Role-aware scope help on the report pages** — each report filter page (Best
  Score / Submissions / User Activity / AI Assist) now shows an always-visible
  line stating what *you* can see (Admin: everything; Editor: full access incl.
  archived, listing your courses; Reporter: live courses only), with a
  "What you can see" drawer detailing every course you edit/report on and the
  three visibility switches. Answers "who can see what?" at the point of use.
- **Empty-report explanation for reporters** — a non-admin reporter whose
  problems are all unavailable or whose group is archived (disabled) reaches the
  report screen but sees no data (by design — `available` is an absolute
  student-exposure switch only admins bypass). The report filter pages now show
  an info notice counting the hidden problems and explaining why, instead of a
  silent empty table.

### Changed

- **Group editors are now content curators of their groups** — an editor can
  see, edit, and report on **every** problem in a group they edit, regardless of
  the problem's `available` flag or whether the group itself is disabled
  (archived). Previously the editor scope required `available: true` **and** an
  enabled group, so editors were locked out of their own draft (unavailable)
  problems and of any finished/archived course exactly like students — only an
  admin could get in. Reporters are unchanged: they remain scoped to available
  problems in enabled groups, and editor visibility stays a strict superset of
  reporter visibility. **Operational note:** to give a non-admin access to a
  finished/archived course, make them an **editor** of its group (a reporter
  still sees only live courses).
- **Report filters are archive-aware** — the group dropdowns now list an
  archived (disabled) group only for users who can still report on it (its
  editors), and mark it with an "archived" pill; reporters no longer see
  archived groups as dead-end filter options, and a reporter left with no live
  groups is turned away at the report gate instead of shown a blank screen.
- **Config templates pruned and made consistent** — `config/application.rb`
  is now tracked directly (it was ignored behind a byte-identical sample); the
  redundant `llm.yml` / `cafe_grader.rb` `.SAMPLE` files and the dead 2016-era
  `abstract_mysql2_adapter.rb.SAMPLE` were removed (the real configs are
  tracked and secret-free), and the identifiers in `credentials.yml.SAMPLE`
  were scrubbed. Fresh clones now boot without hand-copying samples (rev 1769).

## [4.4.1] — 2026-06-13

### Added

- **Per-user activity summary report** — one row per user over a
  time / submission-id range × problem set: submission count, problems
  tried, problems solved (raw_sum-scored datasets excluded — they have
  no defined full score), first/last submission, and distinct IPs.
  Optionally lists zero-activity users for the selected filter
  (highlighted, off by default). Runs as a single `GROUP BY` pass over
  submissions without touching the scoring engine, so even an
  all-problems window stays fast (rev 1758).

### Changed

- **Profile page redesigned** as a two-column identity card + settings
  layout — left: initials avatar, name, login badge, read-only
  email / default language / member-since; right: a Preferences card and
  a Change-password card. Controller and permitted params unchanged
  (rev 1763).
- **Per-problem "my submissions" table** restyled into the carded,
  hover/condensed UI used elsewhere, with real empty states, a `#id`
  link, filename-as-download with a language badge, a compact AI-assist
  badge, and an icon-only Edit button (rev 1764).
- **Grader-processes "Recent Submissions" card** gains a whitelisted
  `?limit=` toggle (20 / 100 / 500, default 20); Refresh and the
  10-minute auto-refresh preserve the chosen limit (rev 1761).
- **Footer slimmed** from a ~41px bar to a ~30px centered watermark —
  coffee mark, cafe-grader wordmark linking to GitHub, and a monospace
  `rev X.Y.Z` (rev 1762).
- **Updated-announcement cards** keep their shadow instead of going
  flat; the "updated" state now adds a 50%-opacity red border on top of
  the standard `shadow-sm` rather than replacing it (rev 1760).

## [4.4.0] — 2026-06-11

### Added

- **Management (write) API** under `/api/v1/` — the API is no longer
  read-only. All endpoints reuse the model-layer authorization
  (`can_edit_problem?`, group-editor scope, admin role) and write
  attributed audit rows:
  - **Problems**: `POST /problems` (creates the default dataset and live
    pointer atomically), `PATCH`/`DELETE /problems/{id}`,
    `PUT /problems/{id}/statement` (PDF upload).
  - **Datasets**: list/create under the problem,
    `PATCH /datasets/{id}` (settings), `DELETE` (refused for the live or
    last dataset), `POST /datasets/{id}/set_live`,
    `POST /datasets/{id}/files` + `DELETE /datasets/{id}/files/{attachment_id}`
    (checker / managers / data files / initializers).
  - **Testcases**: `POST /datasets/{id}/testcases` (file upload or plain
    text, CRLF-normalized), `PATCH`/`DELETE /testcases/{id}`, and
    `POST /problems/{id}/testcases/import` — bulk zip import through
    `ProblemImporter` with a single consolidated `import_testcases`
    audit row.
  - **Users** (admin only): paginated/filterable index, show, create,
    update (blank password = keep), delete (self-delete refused). Role
    granting stays web-only by design.
  - Every content-affecting dataset/testcase write invalidates workers'
    cached copy of the dataset (`WorkerDataset`), so judges re-download.
- **`expires_at` in the API login response** so clients know when to
  re-authenticate.
- **`bin/rails check`** — one task running every test suite plus the
  swagger freshness check (rev 1745).

### Changed

- **API token lifetime reduced from 7 days to 12 hours**
  (`Api::V1::AuthController::TOKEN_TTL`). Bearer tokens cannot be
  revoked server-side, so the TTL is the whole exposure window for a
  leaked token. Tokens issued before the deploy keep their original
  7-day expiry.
- **Submission language authority**: the problem's permitted-language
  set is now authoritative in the new-submission UI and enforced again
  at submit time (revs 1740-1741).
- **Announcement body previews render markdown** instead of stripped
  text (rev 1742).
- **Daily cleanups moved into Solid Queue's `recurring.yml`**
  (rev 1739).
- **Database collation standardized on `utf8mb4_0900_ai_ci`** across
  every table (MySQL 8 only; MariaDB unsupported), enforced by test
  (rev 1746).

### Fixed

- **`Dataset#invalidate_worker` never invalidated anything** — it
  referenced a nil instance variable, so the worker-cache delete
  matched zero rows. Also wired the (previously missing) invalidation
  into the web `testcase_delete` action: workers no longer keep grading
  against deleted testcases.
- **Dataset edit form adapts to checker/manager/main_filename state**
  (issue #48) and the score_type / evaluation_type UI now matches the
  engine semantics (revs 1737-1738).
- **API testcase endpoints de-confused `id` vs per-problem `num`**, and
  scores are emitted as JSON numbers (BigDecimal was serialized as a
  string); problem detail exposes `last_submission_id` (revs 1743-1744).

### Security

- **API login rate limiting** — 10 attempts/minute per client IP on
  `POST /api/v1/auth/login` (was unthrottled).
- **Disabled accounts are now refused API tokens and rejected
  per-request** even with a still-valid token (previously the `enabled`
  flag was only enforced by the web session flow).
- **API mutations carry audit actors** — `Current.user`/`Current.ip`
  are set for API requests, so audit rows from API writes are
  attributed instead of anonymous.
- **Viva exam hardening**: jailbreak attempts terminate the interview
  (`[[VIVA_ALERT]]` flow); answering restricted to the submission
  owner; problem PDFs hidden from students for viva problems; stuck
  assistant turns recover instead of silently hanging (revs 1722-1736).

## [4.3.3] — 2026-05-19

### Added

- **Help drawer on `/problems/:id/edit`** — a Bootstrap offcanvas panel
  opened by a labeled `? Help` button in the page header. Documents the
  Detail-card fields, dataset structure, operations, and links out to
  the project wiki. Pattern codified in `CLAUDE.md` as
  "context-dependent help" (inline knowledge cards on index/overview
  pages; offcanvas drawers on edit/detail pages).
- **`Live` badge in the dataset selector** marking the currently-live
  dataset. The `Set as live` button is shown only on non-live ones, so
  the state is never ambiguous.
- **PDF Export sub-section** on the Description tab with an explicit
  Delete button (uses a hidden-form pattern so it can't produce
  nested `<form>` tags).
- **CU pink + KU yellow-green gradient `C` favicon and navbar brand
  mark.** Single asset (`app/assets/images/icon.svg`) serves both the
  browser-tab favicon and the in-app brand mark — single source of
  truth.
- **`CHANGELOG.md`** itself (this file).
- **Dev-environment additions**: `listen` gem with
  `ActiveSupport::EventedFileUpdateChecker` replaces polling-based file
  watching (fixed multi-second WSL2 cascading-turbo-frame slowness);
  `rack-mini-profiler` + `stackprof` for in-app perf diagnostics.
- **`doc/backlog.md`** as the project's convention for tracking
  deferred design work (linked from `CLAUDE.md`).

### Changed

- **General tab of the problem editor** reorganized into 5 labeled
  sections (Identity / Statement & Files / Categorization / Visibility
  & Listing / Grading & Compilation), with `permitted_lang` moved into
  Grading & Compilation. Column split changed from 5/7 to 6/6 to give
  the form more room.
- **Description tab**: yellow info-card removed (content moved into the
  help drawer), textarea grown to 20 monospaced rows, dead `markdown`
  / `url` fields cleaned up.
- **Hint tab**: alert-wrapped selector replaced with a flat row,
  redundant labels dropped, Add/Delete separated, body field now a
  textarea, friendlier empty state.
- **Dataset selector**: alert wrapper stripped, redundant labels
  dropped, dropdown gets select2 styling, Add + Set-as-live remain
  visible while Rejudge + Delete move behind a `⋮` dropdown (per
  CLAUDE.md's Progressive Condensation rule).
- **Section headers unified** across both the problem form column AND
  the dataset card (Settings/Testcases/Files tabs) using
  `h5 fw-bold text-body-emphasis pb-2 border-bottom`.
- **`compilation_type` field** switched from a `<select>` (with an
  off-feeling blank option) to vertically-stacked styled radio buttons.
- **Server-mutating clicks across dataset views** migrated from legacy
  `link_to … data: { turbo_method: … }` to `button_to` and
  hidden-form + HTML5 `form="..."` patterns per CLAUDE.md.
- **Per-testcase row actions** redesigned as three visible icon-only
  buttons (input / output / delete) with tooltips, sharing three
  hidden forms (Flavor B); the testcase table also picks up the
  project's standard admin-table classes.
- **Per-file row actions** in the Files tab (managers / checker /
  initializers / data files) redesigned same way.
- **Grammar / wording sweep** across the problem editor: tooltip
  rewrites, confirm-dialog standardization ("Really delete X?" →
  "Delete X? This cannot be undone."), `score_type` option text
  rephrased, sentence-case consistency, etc.
- **`finance` Material Symbol replaced with `query_stats`** wherever it
  meant Statistics — clearer metaphor.
- **`llm.yml.SAMPLE` refreshed** to mirror the real config's schema,
  documentation, and environments.

### Fixed

- **AuditLog `destroy` callback** no longer raises "Auditable must
  exist" — the polymorphic `belongs_to` is now declared
  `optional: true`, matching the helper's already-correct treatment of
  destroyed records.
- **Quick-create on `/problems`** now refreshes the list. The previous
  `turbo_stream.append` of a `datatable:reload` event had no listener
  on this page; switched to a `redirect_to` with `status: :see_other`.
- **select2 dropdowns** now reliably fire `change` events into
  Stimulus. select2 v4 dispatches events through jQuery's event system,
  which doesn't always reach native `addEventListener` listeners that
  Stimulus' `data-action` relies on. A bridge in
  `init_ui_component_controller.js` listens for the jQuery
  `select2:select` event and re-dispatches it as a native `change`.
- **`simple_form_for` data-attribute collision**: passing both a
  top-level `data:` and an `html: { data: { … } }` silently dropped the
  top-level one. The dataset and hint selectors now consolidate
  everything into `html: { data: { … } }`. Footgun documented in
  `CLAUDE.md`.
- **Tooltip data-attribute encoding**: Rails' `link_to`-and-friends
  JSON-encode nested `data: { bs: { toggle: … } }` hashes (HAML
  flattens them with hyphens). Several tooltips on problem/contest/
  dataset edit pages were silently broken because the rendered attribute
  was `data-bs='{"toggle":"tooltip"}'` instead of `data-bs-toggle="tooltip"`.
  Migrated to flat `data: { bs_toggle: … }` form across the codebase.
- **WSL2 dev-mode cascading-turbo-frame slowness** (~2 s per concurrent
  request) diagnosed and fixed: the default polling
  `FileUpdateChecker` runs `Dir.glob` on every request and concurrent
  calls serialize on WSL2 inode locks. Switched to the evented variant
  (see Added).
- **`Language` model**: `name` is now enforced unique (via DB index) and
  immutable after create (via model validator). A migration
  idempotently re-runs `Language.seed`, so newly-added entries (e.g.
  `viva`) land on existing installations via `db:migrate` without a
  manual `db:seed` step. Language seed itself uses
  `find_or_create_by!` / `update!` so partial failures raise instead
  of leaving half-created rows.

### Internal

- Convention notes added to `CLAUDE.md`: flat data-attribute form for
  Bootstrap data attrs; offcanvas help-trigger labeling exception;
  context-dependent help-pattern split; backlog pointer; development
  environment (file watcher and profiler).
- Project-history memory entries added (branch workflow, simple_form
  data-collision gotcha, grep-existing-pattern-first principle).
- `doc/backlog.md` seeded with deferred items (help-pattern
  unification, AuditLog destroy test, orphan `contests/_contest_help`
  partial, drawer-content density rewrite).
