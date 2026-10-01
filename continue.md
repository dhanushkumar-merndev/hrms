# Internal HRMS — implementation continuation and release checklist

Version 1.1 · 29 September 2026.

## Current state

- [x] Product scope and four-role permission proposal documented.
- [x] Five specification files created, including implementation-agent instructions.
- [x] Eight original UI references included and mapped in design.md.
- [x] Functional, boundary, authorization, concurrency, export and recovery test plan written.
- [x] v1.1 specification review completed; findings below corrected across the five documents.
- [x] Application repository inspected and initialised (see "Local setup" below).
- [x] Flutter source code implemented for S01–S38 (S38 simple announcements enabled).
- [ ] Supabase/FCM/platform accounts connected or configured for the NEW migrations/functions (owner action — see below).
- [x] Automated tests implemented and executed locally (DB, Deno, Flutter unit/widget). Native integration tests: not yet.
- [~] Native Android builds produced locally with placeholder config (debug + release). No signed release yet; iOS not built (needs macOS).
- [ ] Physical-device GPS/security/notification validation completed.

**Status (2026-09-30): feature-complete in code and green in every local suite; NOT production-released.** The
release gates in M9 (physical office pilot, signed builds, backups/restore drill, provider setup) still need the owner's
accounts and devices. See "Implementation status" and "Owner action items".

## Implementation status (2026-09-30, second session)

Owner decisions carried forward: internal distribution only (no Play/App Store) → Android Key Attestation +
biometric-bound punch key instead of Play Integrity/App Attest; iOS punching deferred (needs Mac/Apple account);
Calendarific dropped; holiday **suggestions** from Google's public "Holidays in India" ICS feed (no key), never
auto-published.

Environment (this machine): Flutter 3.47.5 / Dart 3.13.4, Android SDK 36 (`flutter doctor`: no issues), Postgres 17 +
PostGIS in `.tools/pgenv` (micromamba, `tool/local_db.sh install`), Deno 2.9.7 in `.tools/bin`. No Docker, no `.env`
(no provider credentials on this machine), no connected test phone was used.

### Local setup (reproducible)

```sh
flutter pub get
tool/local_db.sh install && tool/local_db.sh start      # user-space Postgres 17 + PostGIS on :54329
curl -fsSL -o .tools/deno.zip https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip \
  && python3 -c "import zipfile;zipfile.ZipFile('.tools/deno.zip').extractall('.tools/bin')" && chmod +x .tools/bin/deno
tool/db_test.sh                                          # migrations + SQL suites (disposable local DB only)
.tools/bin/deno test -A supabase/functions/tests/       # Edge Function unit tests
flutter analyze && flutter test                          # app static checks + unit/widget tests
cp .env.example .env   # fill in, then: dart run tool/gen_app_config.dart && tool/deploy.sh
flutter build apk --release --dart-define-from-file=build/app_config.json
```

### Verified results (this session, actual commands)

| Suite | Command | Result |
| --- | --- | --- |
| DB (real API roles + JWT claims) | `tool/db_test.sh` | 15 migrations; **7 suites, 368 assertions PASS** (01 grants 18, 02 hours 57, 03 punch 42, 04 leave/review 81, 05 identity 55, **06 archive 102**, **07 holiday suggestions 13**) |
| Edge Functions | `.tools/bin/deno test -A supabase/functions/tests/` + `deno check` | **18 PASS** (5 new: ICS parsing, exact-key batch deletion); all 10 functions type-check |
| Flutter static | `flutter analyze` | No issues |
| Flutter unit/widget | `flutter test` | **27 PASS** (manifest hash equals the PostgreSQL implementation, ZIP path safety, bounded archive extraction, XLSX formula-injection safety, S14/S19/S22/S27 widgets, CACHE-001) |
| Android build | `flutter build apk --debug` / `--release` with placeholder config | debug built (242 s); **release built, 65.6 MB** (R8). Placeholder-config APKs deleted afterwards — not for install |

### Built in this session

Backend
- `20260930100000_archive.sql` (M7/M8): materialised annual periods with explicit transition periods (EXP-019);
  `create_archive_export` freezes rows + immutable file inventory + canonical manifest hash in one locked transaction;
  staleness triggers (EXP-005/006); audited <=60 s export links; acknowledgment with hash/count checks and partial mode
  (EXP-010/011/017); cleanup gates, typed-label confirmation, reauth, exact inventory, persistent period write gate
  (PERIOD_BUSY), leased idempotent batches, driver takeover, abandon, tombstones (DEL-001..012); assisted restore with
  hash check (DEL-010); Admin tasks (annual archive due); HR employee file list. Also fixes two earlier gaps:
  `list_my_payslips` returned timestamps, and `internal_authorize_file_access` denied (instead of "archived — contact
  HR") for cleaned files (FILE-010). `publish_payslip` no longer tries to supersede a deleted version.
- `20260930100100_holiday_suggestions.sql` + Edge `holiday-suggestions` + maintenance kind `holidays` (daily check,
  fetches when >25 days old): suggestions only, de-duplicated, drafts only on explicit Admin/HR action (HOL-002).
- Edge `archive` function: `file_url` (export downloads) and `cleanup_batch` (claim → delete exact keys → record).

App (all screens use server authorisation; UI gates are UX only; sensitive screens re-read permissions every 30 s and
hide detail offline)
- S14 payslips, S16 profile (+ private details, photo), S17 directory, S18 documents (+ policy upload), S19 inbox,
  S20 settings (password, push toggle, punching phone, sign out), S21 workspace, S22/S23 approvals (atomic lock-on-open,
  Admin fallback reason, approve/return/reject, withdrawal/cancellation decisions, reassignment), S24 hours report
  (day/week/month/custom, team/office filters, expandable rows, Admin XLSX export), S25–S27 employees (list, full HR
  record with effective-dated team/office/shift, private details, reset with one-time password, deactivate/reactivate,
  devices, documents, leave adjustment, schedule exceptions; provisioning with one-time temporary password),
  S28 payroll uploads, S29 teams/departments/managers, S30 shifts (draft/publish, worked-hours preview), S31 offices
  (current-location capture, calibration guidance), S32 leave types/entitlements/approval routes/holidays +
  suggestions, S33 roles & permissions (reauth for elevation), S34/S35 annual archive (on-phone build: resumable
  2-way downloads with SHA-256, bounded extraction of earlier originals, streamed ZIP in an isolate, full read-back
  verification, save/share, acknowledgment, guarded cleanup with resume/abandon), assisted restore, S36 audit,
  S37 organisation (cycle-change preview, maintenance health), S38 announcements.
- Optional FCM push (Android): register/unregister per installation, unbound at sign-out, taps open in-app routes.
- CACHE-001 fix: in Riverpod 3 a provider with no listeners is paused, so the earlier listener-based cache drop would
  not fire after sign-out. Identity-scoped caches are now released directly by the session controller (test added).

### Owner action items (cannot be done from this machine)

1. DONE 2026-09-30: staging has all 15 migrations and all 10 Edge Functions (`tool/deploy.sh`; dry run reports
   "Remote database is up to date").
2. Supabase dashboard — STILL OPEN (checked 2026-09-30: sign-up enabled, minimum password length 6; the
   `.env` access token lacks `project_admin_write`, so `tool/deploy.sh` cannot set these): Authentication → turn OFF
   "Allow new users to sign up"; Email → minimum password length 12. Rotate the database password that was printed
   once in the first session and update `SUPABASE_DB_URL`.
3. Release signing: create the keystore (`.env` ANDROID_KEYSTORE_*), set `HRMS_ANDROID_CERT_SHA256` for production
   attestation, build `--release` with `HRMS_ENVIRONMENT=production` config.
4. Push: `APP_FIREBASE_*` and `HRMS_FCM_SERVICE_ACCOUNT_B64` are set and deployed (build says push=on); delivery to
   a phone not yet verified.
5. Physical checks (release gates): office pilot per office (S31 calibration), punch on 2+ Android phones, archive
   build of a realistic year on a mid-range phone (measure time/space; >1 GB not yet spiked on device), backup +
   restore drill, iOS build/signing on a Mac if iOS is needed.

### Next exact steps

1. Owner: sign in as ADMIN001 (temporary password was re-issued by an operator reset on 2026-09-30; the app forces
   a new password), complete Organisation → Offices → Shifts (publish) →
   Leave types/entitlements → Holidays → Teams/approval routes → Employees.
2. On a phone at the office: register the punching phone, check in/out, verify the distance/accuracy evidence.
3. Staging E2E of archive: close a test period (staging data), create export, build/save on phone, acknowledge,
   cleanup a test file, abandon/resume, restore. Record timings in the evidence log.
4. Add native `integration_test` journeys (login → password change → punch reconcile) once a device is attached.

## Read order and first action

Read [agent.md](agent.md) -> [architecture.md](architecture.md) -> [design.md](design.md) -> [test.md](test.md), then use this checklist. Inspect images in `docs/ui-reference/`. First implementation action: inspect the target repo/environment and document what already exists, then begin M0. This package contains no `.env`, credentials or real staff dataset.

## Decisions already resolved — do not repeatedly ask

- Flutter Android/iOS only, including HR/Admin; no desktop web panel or native Playwright UI suite.
- Member/Manager/HR/Admin; many teams, configurable Manager-or-HR approval, no self approval including Admin.
- Admin/HR provision ID + password; mandatory temporary-password change; no email/SMS OTP requirement.
- Uploaded payslip PDFs, not generated payroll calculations; <=5 MB per file, latest 12 salary-month member view.
- Supabase backend/private Storage + FCM; no initial Tigris, Brevo, Redis or separate Node service.
- Paid lunch included within 9-hour shift; Admin configures lunch, shift/grace/checkout-extension. Grace doesn't manufacture hours.
- Yearly completed-period archive + local Excel/ZIP with employee folders; file deletion gated by successful archive, acknowledgment and explicit Admin confirmation. Keep records/audit.
- Home/Action/Explore initial tabs, reference-style cards; Engage/social and tax/Helpdesk/Worklife deferred.

## Inputs for setup, not reasons to stop local implementation

Implement configuration forms and defaults while these are collected. They must be supplied/published before live use.

| Input | Selected behavior until configured | Production gate |
| --- | --- | --- |
| Company display name/logo | Neutral Internal HRMS title, generic artwork | Admin sets real brand; no screenshot identity reused |
| Office coordinates/assignment | Test coordinates only in dev | Physical pilot for each real office |
| Annual period | Draft Jan–Dec; alternate Apr–Mar | Admin picks before first annual job; frozen jobs immutable |
| Shift/lunch | Draft 10–19, paid lunch interval to be set, grace 30m, extension120m | Admin reviews/publishes; employee assignments complete |
| Leave allowance/calendar | No invented production entitlement; dev fixture12 days only | Admin sets paid leave and approved holiday dates separately |
| Approver routes | Test team routes in seed | Every employee including Admin has eligible other approver |
| Storage budget | Derived configurable alerts; provider quota recheck | Monitor bytes/egress; 5MB max may exceed free storage overall |
| Device integrity/distribution | Separate test mocks only | Real Play Integrity + iOS App Attest strategy validated |
| Credentials/APNs/signing | Document placeholders | Owner supplies through secret managers/native tooling |
| Backup/restore ownership | Checklist and helper design | Verified encrypted DB/object backups, measured restore drill |

## Milestones in dependency order

### M0 — bootstrap and tools

- [x] Inspect repo/instructions/git status, preserve existing work.
- [x] Record Flutter/Dart/Android/macOS-Xcode/Supabase/Deno tooling availability (no macOS/Xcode here).
- [x] Pin current compatible dependencies, initialize feature structure/theme/router.
- [ ] Create separate local/staging/prod configs; `.env.example` without secret values.
- [x] Set up disposable local Supabase and deterministic fake fixtures (user-space Postgres + shim; no Docker).
- [ ] Define CI format/analyze/unit/widget/API/DB tasks with actual commands.

Exit: reproducible local app and migrations; tooling blockers recorded accurately. Tests: baseline build plus SEC-001 configuration inspection.

### M1 — identity, organization and authorization

- [ ] Core employee/org/roles/team/office tables, constraints, RLS and scoped projections.
- [ ] Employee ID alias login and server-side provisioning/reset saga.
- [ ] Temporary credential gate, fail-closed credential-operation hold/reconciliation, original-session revocation checks, native Auth bypass tests, rate limits, last-Admin protection.
- [x] S01–02/16–17/20/25–27/29/33/37 real forms and permissions.
- [ ] Auth audit and current-permission guard used by all future functions.

Exit: cannot read/change other employee's protected data by direct API; no public signup or secret leak. Tests: AUTH, ROLE, EMP, API-001, SEC-002/003.

### M2 — schedules, calendar and calculation engine

- [ ] Effective-dated offices/shifts/team/office assignments and schedule instances.
- [ ] Paid lunch, grace, early entry/credit, checkout extension, overnight handling.
- [ ] Holiday draft/import/manual selection/publish; initial target 12, allowance independent.
- [ ] Exact-second duration model, half-day required intervals and label anchors, absence rules, leave/work conflict guards, partial/unknown report totals.
- [x] S13/30–32 calendar/configuration with numeric limits and previews.

Exit: deterministic unit/API fixtures match all examples; historical policies aren't rewritten. Tests: TIME, HOL, EMP-002.

### M3 — secure attendance and correction primitives

- [ ] Native foreground precise permission flow and bounded GPS acquisition.
- [ ] Challenge/proof binding; Android/iOS integrity provider adapters with actual verification path.
- [ ] Transactional idempotent punch, state sequence, server timestamps and rejected-attempt logging.
- [ ] Unknown-operation recovery before stale-proof rejection; no verified offline punches.
- [ ] Lazy overdue-session rollover allows next shift without inventing OUT; session-bound checkout.
- [ ] Original event + effective adjustment model, S03–09 attendance/home screens.
- [ ] Physical-site validation left explicitly pending until available.

Exit: concurrent/duplicate punches safe; UI success means committed server result. Tests: LOC, PUNCH, TIME and native permission flows.

### M4 — leave, review lock and approvals

- [ ] Leave policies/accounts/ledger/reservations/day-slot constraints, no negative paid balances.
- [ ] Manager/HR routing, Admin fallback/reassignment and self-approval prohibition.
- [ ] Submitted edit vs first authorized review transaction lock, safe list projection with no direct detail/attachment bypass, Edited badges/revisions.
- [ ] Returned reservation release, failed-edit rollback, resubmission, old-year cancellation credit, explicit withdrawal/cancellation/reversal states.
- [ ] Returned/rejected/withdrawn/cancellation states and exact-once ledger adjustments.
- [ ] Attendance correction approval preserves original records and recalculates effective totals.
- [x] S10–12/21–23; notification outbox event insertion.

Exit: all race recipes pass against real database. Tests: LEAVE, REVIEW, CORR, AUDIT-001.

### M5 — private documents and payslips

- [ ] Private staging/final objects, upload reservations and 5,000,000-byte validation.
- [ ] Staging promotion to server-only immutable final objects BEFORE validation/hash; bounded decoded size/parser resources, draft/publish flow.
- [ ] Protected Storage denies direct client SELECT/sign; one audited permission/window/review-checked signing endpoint.
- [ ] Explicit HR payroll grant; protected ownership and latest 12-month API access.
- [ ] Secure PDF preview/download and masked/minimal Home card; no fake payroll amounts.
- [ ] Storage budget ledger/reconciliation and abandoned-upload cleanup.
- [x] S14–15/18/28; user/account-switch cleanup of sensitive temp data.

Exit: direct Storage/API ID guessing cannot bypass permissions. Tests: FILE, CACHE-001, SEC-001.

### M6 — reports, queries, caching and notifications

- [ ] HR/team day/week/month/custom reports with intervals, expected/worked/short/extra hours.
- [ ] Query-driven indexes, bounded offset and stable cursor pagination, safe search.
- [ ] Riverpod scoped caches/invalidation, lazy lists, loading/empty/offline states.
- [ ] Supabase Cron/Vault/pg_net bounded maintenance runner, leases, health reporting and lazy correctness fallback.
- [ ] Exactly-once inbox state, best-effort/retryable push, token refresh/logout cleanup; APNs integration.
- [x] S19/24/36 and safe audit views; S38 only simple announcements if enabled.

Exit: metrics/role scope correct, performance measured, push failure doesn't affect transactions. Tests: NOTIF, AUDIT, CACHE, PAGE, PERF.

### M7 — annual archive and local file export

- [x] Immutable business-period snapshot rows/items, revision watermark, closed-year gates.
- [x] Admin report XLSX and annual nested ZIP; all eligible employee/file revisions covered.
- [ ] Prototype large streamed archive on Android/iOS, isolate ZIP/XLSX work, bounded memory/disk.
- [ ] Resumable authorized download, checksums/count verification, local Files/document save.
- [x] XLSX formula protection and safe filename/folder construction.
- [x] S34–35 export progress, annual due task, overnight provisional status, verified-save acknowledgment.
- [ ] Rebuild full annual archive from validated local originals after cloud cleanup; partial fallback cannot unlock cleanup; explicit period-transition coverage.

Exit: cutoff and as-of behavior clear; incomplete archives never cleanup-eligible. Tests: EXP plus ARCHIVE recipes in test.md.

### M8 — guarded annual file cleanup and restore

- [x] Reauthentication, current-manifest validation, exact-file preview and period confirmation.
- [x] Live-window archive warning, file exclusions, no deletion of HR/attendance/leave/audit.
- [x] Transactional period lock, immutable delete inventory, per-object resumable Storage cleanup.
- [x] Tombstones, partial-failure result, saved manifest; cross-Admin resume, worker lease and abandon-partial behavior; no false Undo/recovery promise.
- [ ] Document and test assisted restore from verified local archive.

Exit: exact-set deletion proof and interrupted cleanup recovery pass in staging. Tests: DEL, EXP-005/006, FILE-010, OPS-001.

### M9 — release validation

- [ ] Full mapped P0 and applicable P1 suites, no critical permission/accounting gaps.
- [ ] Real Android+iPhone GPS, integrity, APNs, release channel and background/resume evidence.
- [ ] S01–37 visual/accessibility review against UI refs; 360dp/large-text supported.
- [ ] Cold/warm/network-separated timing and storage/battery/memory evidence.
- [ ] Provider quotas, total-file-size forecast, egress and inactivity behavior reviewed.
- [ ] Encrypted operator backups and restore drill; measured RPO/RTO recorded.
- [ ] Migration/release/rollback plan, current secrets/credential rotation, private distribution procedure.
- [ ] User acceptance on actual offices/approver routes/policies and archive cleanup.

Exit: release report describes actual verified scope and any remaining operational limitations; no unconfigured service claimed complete.

## v1.1 review findings and corrections

This was a review of the specification against the conversation and primary provider documentation. Severity describes potential implementation impact, not a discovered live-app vulnerability. All rows below are corrected in this specification; implementation and regression execution remain pending.

| Finding | Severity | Gap found in v1.0 | Correction / regression IDs |
| --- | --- | --- | --- |
| R01 | High | Half-day leave reduced hours but did not change late/early anchors or prevent leave/work overlap | Required intervals and conflict rules; TIME-015–018, LEAVE-014 |
| R02 | High | A stale open session could keep unique-open constraint occupied next day | Rollover to needs_correction without fabricated OUT; PUNCH-011 |
| R03 | High | Payload hash was bound before acquiring sample; retry could fail after proof expiry | Nonce then canonical payload proof; committed-result-first replay; PUNCH-012–013, API-004 |
| R04 | High | Generic detail/attachment reads could bypass the first-view edit lock | Restricted projections + locking detail path; REVIEW-011–012 |
| R05 | High | Direct Storage SELECT could bypass download audit/short expiry; mutable staging could race validation | Server-only signing and hash immutable promoted bytes; FILE-016–018 |
| R06 | High | Returned requests and old-year cancellation could leak reservations or credit wrong year | Explicit ledger/state transitions and cross-account idempotency keys; LEAVE-006/011–013, REVIEW-013, CORR-007 |
| R07 | High | Full re-export after earlier cleanup could request cloud bytes that no longer exist | Validate/merge local base archive; incomplete fallback blocks cleanup; EXP-016–017 |
| R08 | High | Year-end cleanup could conflict with live overnight shift; failed cleanup lacked an abandon path | Provisional eligibility, leased resume/abandon; EXP-018, DEL-011–012 |
| R09 | High | Credential update could partially succeed before app session barrier finalized | Fail-closed operation hold + reconcile and direct Auth tests; AUTH-014–015 |
| R10 | Medium | Background jobs had no specified executor, push/cached revocation wording too strong | Supabase maintenance runner; honest delivery/cache semantics; OPS-005, NOTIF-005, CACHE-004 |
| R11 | Medium | Manager historical transfer scope and annual-period transitions were underspecified | Work-date team scope + explicit transition periods; ROLE-005, EXP-019 |

Review validation: exact archive structure, local Markdown links, table/code-fence checks, unique test/screen IDs, requirement coverage and original-image byte comparison. None of these claims that Flutter/API tests ran; there is no app code in this package.

## Deferrals

- [ ] Engage social feed, comments/reactions, Worklife, Helpdesk: outside current scope.
- [ ] Automatic salary/payslip calculation, YTD/tax declarations: outside current scope.
- [ ] Break punches and unpaid break changes: reserved extension; default paid lunch only.
- [ ] Web admin/Playwright UI tests, biometrics hardware, maps, background tracking: outside current scope.
- [ ] New storage/email services or Redis: only after a measured requirement and updated architecture.

## Evidence and handoff log

Fill with actual evidence after implementation, never inferred success.

| Date / milestone | Commit/build | Commands/device | Result and test IDs | Remaining issue | Next exact action |
| --- | --- | --- | --- | --- | --- |
| 2026-09-29 / specification | Not an app build | Document/archive validation only | Specifications and original UI references packaged | All software/provider tasks pending | Inspect target repo and execute M0 |
| 2026-09-29 / v1.1 review | Not an app build | Cross-document review and ZIP checks | R01–R11 corrected; 191 QA scenarios specified (31 new); app tests not executed | Native/API implementation and validation still pending | Read review register, then execute M0 |
| 2026-09-30 / M1–M5 partial | Release APK (uncommitted working tree) | `tool/db_test.sh`; `deno test`; `tool/deploy.sh`; `flutter analyze`; `adb -s 616bef82 install -r` | 253 DB assertions PASS; 13 Deno PASS; live login E2E PASS; APK installed on OPPO | Punch untestable until office/shift admin screens exist; many screens pending | Build S30/S31 + assignment, then punch on phone |
| 2026-09-30 / M1–M8 code complete | Working tree (uncommitted) | `tool/db_test.sh`; `deno test`/`deno check`; `flutter analyze`; `flutter test`; `flutter build apk --debug/--release` (placeholder config) | 368 DB assertions PASS (7 suites incl. EXP/DEL/HOL-002); 18 Deno PASS; 27 Flutter PASS; analyze clean; debug+release APK built | New migrations/functions not yet deployed; no device, signing, Firebase, office pilot or restore drill | Owner deploys with `tool/deploy.sh`, then staging E2E per "Next exact steps" |
| 2026-09-30 / staging deploy + device install | Working tree (uncommitted), staging project | `tool/deploy.sh`; `supabase db push --dry-run`; `flutter build apk --release --target-platform android-arm64`; `adb -s S4V8SKXS7PGIHQGI install -r` | 2 migrations applied (remote up to date); 10 functions deployed; secrets + Vault set; arm64 release APK (23.4 MB, debug-signed, push=on) installed and launched on Realme RMX2161 / Android 12, sign-in screen renders, no errors in logcat | Auth hardening refused (token lacks `project_admin_write`); no signed-in journey, punch or push delivery verified yet | Owner sets Auth settings in dashboard, signs in, runs setup and on-site punch |
| 2026-09-30/10-01 / staging setup + live E2E | Working tree (uncommitted), staging | API scripts as real users; phone over adb; `deno test`; `flutter analyze/test` | Org set up (Video Grapher/Social Media/IT teams, managers Sanjay/Pruthivi in Management, Main Office from phone GPS, General 10–19 Mon–Sat published, CL 12/PL 12/UL). 6 accounts provisioned; first sign-in/forced change 18/18; roles, access denials, leave approve/reject/withdraw/cancel, Admin fallback and override-with-reason all verified; test leave cancelled, balances restored. FIXED: device registration failed on real TEE chains (P-384 intermediate signing SHA-256 unsupported by Edge Runtime WebCrypto) — EC links now verified with @noble/curves, regression fixture added (19 Deno PASS), device-register redeployed; phone registered + IN/OUT punched (hardware, signature verified, 2.7 m). FIXED: Home kept yesterday's status when left open overnight (card date from phone clock, refresh not retried) — date now from server shift_date, Home reloads on day change / 5 min / error. Office + leave-policy form spacing fixed. FIXED (migration 20261001100000, deployed): the morning after a completed day, `hrms.current_shift` returned yesterday's closed shift (NULLS LAST ordered "no session" after "closed"), so Check in was unavailable; HOME-002 reproduces it (got 2026-09-30) and passes with the fix — 7 suites / 369 assertions PASS; phone shows today's Check in | Test-account passwords set during testing were lost with the temp folder and must be re-issued; Auth dashboard hardening still open | Re-issue temporary passwords; Dhanush check-in on 1 Oct with fixed build |

For a blocked item record: required credential/tool/device, code already completed, exact validation still needed, how to resume safely, and owner action. Do not include credential values. For a bug record minimal reproduction and affected test IDs, not just 'not working'.

At each handoff update completed tasks, actual test results and the next unblocked task. Never mark a feature complete because its UI is present while backend security/export checks are stubbed.
