# Internal HRMS

One Flutter app (Android; iOS pending a Mac) for Members, Managers, HR and Admin: location-verified check-in/out,
attendance corrections, leave with Manager-or-HR approval, holidays, uploaded payslip PDFs, private documents,
hours reports, notifications, audit history, and a yearly archive with guarded cloud-file cleanup.

Backend: Supabase (PostgreSQL + PostGIS, Auth, private Storage, Edge Functions, pg_cron). All tables live in the
unexposed `hrms` schema with deny-all RLS; the app calls narrow `public.*` RPCs and Edge Functions that authorise
every request on the server.

Specifications: [agent.md](agent.md), [architecture.md](architecture.md), [design.md](design.md), [test.md](test.md).
Current status, evidence and next steps: [continue.md](continue.md).

## Layout

```text
lib/app/            bootstrap, router, theme
lib/core/           API client, session, cache, files (XLSX/save), push, widgets
lib/features/       one folder per area (attendance, leave, approvals, employees, admin, archive, ...)
supabase/migrations SQL schema, RPCs, permissions (applied in filename order)
supabase/functions  Edge Functions (auth, punch, files, archive, maintenance, ...)
supabase/tests      SQL test suites for the disposable local database
tool/               local DB, config generation, deploy, first-Admin bootstrap
```

## Local development

```sh
flutter pub get
tool/local_db.sh install && tool/local_db.sh start   # user-space Postgres 17 + PostGIS (no Docker needed)
tool/db_test.sh                                      # applies migrations to a DISPOSABLE local DB and runs SQL tests
.tools/bin/deno test -A supabase/functions/tests/   # Edge Function tests (install Deno into .tools/bin, see continue.md)
flutter analyze && flutter test
```

Never point `tool/local_db.sh` or `tool/db_test.sh` at a real database: they drop and recreate it.

## Deploying to a Supabase project

1. `cp .env.example .env` and fill it in (never commit `.env`; only `APP_*` values reach the app).
2. `tool/deploy.sh` — migrations, Edge Function secrets and functions, scheduler secrets, Auth hardening.
3. First Admin (once): `dart run tool/bootstrap_admin.dart` — prints a temporary password once; change it at first sign-in.
4. App config: `dart run tool/gen_app_config.dart` (refuses secret keys), then
   `flutter build apk --release --dart-define-from-file=build/app_config.json`.

After the first sign-in, the Admin sets up, in order: Organisation → Offices (test on site) → Shifts (publish) →
Leave types and entitlements → Holidays → Teams and approval routes → Employees.
