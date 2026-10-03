# Staging End-to-End QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add clear office Wi-Fi evidence to punching, then execute and document the complete synthetic-account staging acceptance matrix on the connected Android phone without touching existing users or deleting archive data.

**Architecture:** The Android UI is the primary acceptance surface. Automated local suites cover deterministic security and edge cases, while read-only staging queries corroborate UI outcomes, actor identities, balances, file metadata, and immutable history. All staging mutations use only `QA*` identities and synthetic content; archive cleanup ends by cancelling the final confirmation.

**Tech Stack:** Flutter/Dart, Riverpod, Android/ADB UIAutomator, Supabase PostgreSQL/PostGIS, Supabase Edge Functions/Deno, private Storage, Markdown evidence.

**Spec:** `docs/superpowers/specs/2026-10-03-staging-end-to-end-qa-design.md`

## Global Constraints

- Use only synthetic `QA*` accounts and records; never mutate an existing employee account or business record.
- Use the phone UI for every primary user journey and role boundary.
- Use backend queries only for read-only verification of state, audit actors, permissions, balances, hashes, and history.
- Synthetic PDFs, XLSX files, images, and data must contain no real employee information.
- Do not expose credentials, tokens, signed URLs, or private content in committed files or evidence.
- Do not clear app data, uninstall the app, or replace an existing employee's punching registration.
- Stop archive cleanup at the final confirmation and cancel it; no database row or Storage object may be deleted.
- Preserve unrelated working-tree changes and stage only files named by the active task.
- A scenario is complete only when the report contains start state, UI actions, expected result, actual result, server evidence, and PASS/FAIL/BLOCKED.

## Review Focus

- Android may return a stale nearby Wi-Fi scan; the UI must label it as an estimate and the server must remain authoritative.
- Account switching can leak cached private data; each role switch must verify the preceding user's salary, document, request, and notification data disappeared.
- Duplicate taps or stale request revisions can create double mutations; server counts and immutable history must prove a single accepted transition.
- Synthetic file names and spreadsheet cells can trigger path/formula injection; automated tests and downloaded artifacts must prove sanitization.
- Archive acknowledgement can unlock cleanup; the run must prove that final cancellation created no tombstones, cleanup rows, or deleted objects.

---

### Task 1: Wi-Fi evidence on the punch screen

**Files:**
- Create: `lib/features/attendance/wifi_evidence.dart`
- Modify: `lib/features/attendance/punch_controller.dart`
- Modify: `lib/features/attendance/punch_screen.dart`
- Create: `test/unit/wifi_evidence_test.dart`
- Modify: `test/widget/screens_test.dart`

**Interfaces:**
- Produces: `WifiEvidence classifyOfficeWifi(List<String> accepted, String? connected, List<String> nearby)` with `WifiEvidenceMode.connected`, `nearby`, `missing`, or `notRequired`, plus the matched SSID.
- Produces: `PunchState.wifiEvidence` as provisional UI evidence; `submit()` performs a fresh scan and sends that fresh evidence to the server.

- [ ] **Step 1: Write the failing unit tests**

  Add `classifyOfficeWifi` cases for case-insensitive connected match, nearby-only match, configured-but-missing, empty-policy, duplicates, blank names, and connected non-office Wi-Fi with an office SSID nearby.

- [ ] **Step 2: Run the unit test and verify it fails**

  Run: `flutter test test/unit/wifi_evidence_test.dart`

  Expected: FAIL because `wifi_evidence.dart` does not exist.

- [ ] **Step 3: Implement the pure classifier**

  Implement immutable `WifiEvidence`, `WifiEvidenceMode`, normalized exact SSID comparison, and display-safe matched-name selection in `lib/features/attendance/wifi_evidence.dart`.

- [ ] **Step 4: Run the unit test and verify it passes**

  Run: `flutter test test/unit/wifi_evidence_test.dart`

  Expected: PASS.

- [ ] **Step 5: Write failing widget tests for the exact copy**

  Assert the ready state renders exactly one of: `Connected to office Wi-Fi: <SSID>`, `Office Wi-Fi detected nearby: <SSID> — mobile data is allowed.`, or `Office Wi-Fi not detected. Turn on Wi-Fi and refresh.`; assert success says `Office location and Wi-Fi verified.` when Wi-Fi is required.

- [ ] **Step 6: Run the widget tests and verify they fail**

  Run: `flutter test test/widget/screens_test.dart`

  Expected: FAIL because the punch screen does not render Wi-Fi evidence.

- [ ] **Step 7: Wire scanning and copy into the controller and screen**

  Scan alongside location acquisition, store provisional evidence in `PunchState`, label nearby results as estimates, refresh both location and Wi-Fi together, and retain the existing fresh scan inside `submit()` so UI evidence cannot weaken server enforcement.

- [ ] **Step 8: Run targeted and full Flutter checks**

  Run: `dart format --output=none --set-exit-if-changed lib/features/attendance/wifi_evidence.dart lib/features/attendance/punch_controller.dart lib/features/attendance/punch_screen.dart test/unit/wifi_evidence_test.dart test/widget/screens_test.dart && flutter analyze && flutter test`

  Expected: formatter, analyzer, and all Flutter tests pass.

- [ ] **Step 9: Commit the isolated UI change**

  Run: `git add lib/features/attendance/wifi_evidence.dart lib/features/attendance/punch_controller.dart lib/features/attendance/punch_screen.dart test/unit/wifi_evidence_test.dart test/widget/screens_test.dart && git commit -m "feat: show office Wi-Fi punch evidence"`

### Task 2: Baseline automated security and edge coverage

**Files:**
- Create: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/automated/`

**Interfaces:**
- Produces: baseline build commit, tool versions, suite counts, failures, and mapping to `test.md` IDs for later phone scenarios.

- [ ] **Step 1: Create the report headings and safety ledger**

  Add environment/build, account matrix without passwords, scenario table, defect table, mutation ledger, archive deletion guard, and final summary headings.

- [ ] **Step 2: Capture tool/device versions and connected-device identity**

  Run: `flutter --version && dart --version && .tools/bin/deno --version && java -version && /home/dhanushkr/Android/Sdk/platform-tools/adb --version && /home/dhanushkr/Android/Sdk/platform-tools/adb -s S4V8SKXS7PGIHQGI shell getprop ro.product.model && /home/dhanushkr/Android/Sdk/platform-tools/adb -s S4V8SKXS7PGIHQGI shell getprop ro.build.version.release`

  Store sanitized output under the ignored evidence directory.

- [ ] **Step 3: Run the disposable local database suites**

  Run: `tool/db_test.sh`

  Expected: every SQL suite passes; this command must target only the disposable local database.

- [ ] **Step 4: Run Edge Function tests and type checks**

  Run: `.tools/bin/deno test -A supabase/functions/tests/ && for entry in supabase/functions/*/index.ts; do .tools/bin/deno check "$entry"; done`

  Expected: all tests and checks pass.

- [ ] **Step 5: Run Flutter analyzer and tests**

  Run: `flutter analyze && flutter test`

  Expected: analyzer clean and all tests pass.

- [ ] **Step 6: Record honest baseline results**

  Write exact commands, counts, failing test names, and PASS/FAIL/BLOCKED status; do not summarize a failing suite as passing.

### Task 3: Build, update, and smoke-test the phone

**Files:**
- Read: `build/app_config.json`
- Evidence only: `test_output/qa-2026-10-03/device/`
- Modify: `docs/qa/staging-e2e-2026-10-03.md`

**Interfaces:**
- Produces: installed build/version evidence and a stable UI automation baseline on serial `S4V8SKXS7PGIHQGI`.

- [ ] **Step 1: Validate app config without printing secrets**

  Verify required public keys exist, no service-role/access token is present, and the configured organization/staging endpoint is expected.

- [ ] **Step 2: Build the Android arm64 release APK**

  Run: `flutter build apk --release --target-platform android-arm64 --dart-define-from-file=build/app_config.json`

  Expected: `build/app/outputs/flutter-apk/app-release.apk` is created.

- [ ] **Step 3: Update the existing installation without clearing data**

  Run: `/home/dhanushkr/Android/Sdk/platform-tools/adb -s S4V8SKXS7PGIHQGI install -r build/app/outputs/flutter-apk/app-release.apk`

  Expected: `Success`; do not uninstall on a signature mismatch.

- [ ] **Step 4: Launch and capture the initial hierarchy/logs**

  Confirm the app opens, no crash/ANR appears, and the currently signed-in QA identity remains consistent.

- [ ] **Step 5: Verify provisional Wi-Fi messaging on the phone**

  Confirm the screen distinguishes connected, nearby-only, and missing states where safely reproducible, and that a successful punch never describes nearby-only detection as a connection.

### Task 4: Authentication, role boundaries, and cache isolation

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/auth-roles/`

**Interfaces:**
- Consumes: installed Task 3 build and `build/QA_ACCOUNTS.txt` locally.
- Produces: verified role-navigation matrix and account-switch isolation evidence.

- [ ] **Step 1: Exercise safe authentication failures**

  Test one bad password, employee-code normalization, generic failure copy, and recovery with the correct password without triggering brute-force protection.

- [ ] **Step 2: Sign in and record navigation for Member, Manager, HR, and Admin**

  Use `QAM101`, `QAMGR01`, `QAHR01`, and `QAADM01`; verify expected screens and server session roles.

- [ ] **Step 3: Test role-boundary UI and deep links**

  Verify Member denial for reviewer/admin data, Manager denial for salary/private documents, HR denial for Admin-only privilege/archive cleanup, and Admin organization scope.

- [ ] **Step 4: Verify cache isolation after every sign-out**

  Confirm the next role cannot see the previous user's profile, salary, document preview, requests, or notifications before or after refresh.

- [ ] **Step 5: Corroborate roles and denials read-only**

  Query expected `QA*` roles, permissions, active state, and recent access/security audit rows; record only IDs/codes and sanitized outcomes.

### Task 5: Attendance and correction lifecycle

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/attendance/`

**Interfaces:**
- Produces: closed synthetic attendance session, rejection evidence, correction lifecycle, and immutable-event verification.

- [ ] **Step 1: Close the current `QAHR01` open attendance session through UI**

  Use biometric confirmation supplied by the phone owner; verify OUT, closed session, IN/OUT events, Wi-Fi evidence, GPS distance, and actor identity.

- [ ] **Step 2: Exercise reversible device/location/network gates**

  Verify registration prompt on a disposable QA identity only if it will not displace an existing user's phone; test location permission, inaccurate/outside-zone evidence, office-Wi-Fi missing rejection, offline response, and retry.

- [ ] **Step 3: Verify duplicate and illegal punch handling**

  Use UI repeated-tap protection and automated server tests to prove one event, idempotent recovery, and rejected duplicate/illegal sequence.

- [ ] **Step 4: Submit a correction through the Member UI**

  Use an eligible past QA date and synthetic reason, then open and decide it through the authorized reviewer UI.

- [ ] **Step 5: Verify effective attendance and immutable history**

  Query the correction request, adjustment, session, original events, notifications, and audit actor IDs read-only.

### Task 6: Leave lifecycle and balances

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/leave/`

**Interfaces:**
- Consumes: existing approved QAM101 leave scenario as evidence, without rewriting it.
- Produces: all remaining leave lifecycle and balance-edge outcomes on separate QA Members/dates.

- [ ] **Step 1: Verify the completed submit/assign/open/approve flow**

  Corroborate request status, locked revision, balance ledger, notification, and the Member/Admin/Manager audit actors.

- [ ] **Step 2: Exercise edit-before-open and stale/locked revision behavior**

  Submit and edit as a Member, open as reviewer, then confirm further stale edits fail safely.

- [ ] **Step 3: Exercise return, resubmit, reject, and withdraw**

  Use distinct QA requests and verify each start/end state plus notifications/history.

- [ ] **Step 4: Exercise approved-leave cancellation approval and denial**

  Verify approved cancellation restores balance exactly once and denied cancellation preserves the debit.

- [ ] **Step 5: Exercise calculation edge cases**

  Test half-day, weekend/holiday exclusion, overlap rejection, insufficient paid balance, attendance conflict, and empty/invalid reasons using safe dates.

### Task 7: Salary, payroll, bank details, and payslips

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/payroll/`

**Interfaces:**
- Produces: synthetic salary revisions, bank-detail request outcomes, valid PDF payslip lifecycle, and privacy-denial evidence.

- [ ] **Step 1: Generate synthetic payroll fixtures**

  Create small valid PDFs and XLSX data containing only QA identities, plus invalid MIME/magic, empty, oversized-boundary, unsafe-name, and formula-prefix fixtures.

- [ ] **Step 2: Create and inspect salary history through authorized UI**

  Record a synthetic salary revision for selected QA Members and verify Member-own, Manager-denied, and HR/Admin-authorized visibility.

- [ ] **Step 3: Exercise bank-detail request outcomes**

  Submit synthetic masked details as Member; approve, return/resubmit, and reject separate requests as authorized reviewers; verify history and actor attribution.

- [ ] **Step 4: Exercise payslip draft/publish/replace/download**

  Upload a valid synthetic PDF, verify draft invisibility, publish it, download as owner, replace with a reason, and verify revision/file hashes.

- [ ] **Step 5: Exercise payslip denials and validation**

  Verify wrong-owner and Manager denial, month bounds, invalid extension/MIME/magic, zero-byte, size boundary, sanitized filename, and signed-link expiry through UI where possible and automated tests otherwise.

### Task 8: Documents, people, organization administration, reports, and notifications

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/workspace/`

**Interfaces:**
- Produces: employee/private document and policy lifecycle, employee/admin validations, reporting scope, notification privacy, and audit attribution evidence.

- [ ] **Step 1: Exercise employee document upload and access**

  Upload a synthetic employee document, preview/download as owner and HR/Admin, and verify another Member plus Manager are denied.

- [ ] **Step 2: Exercise company policy lifecycle**

  Upload as draft, verify Member invisibility, publish, verify Member visibility, then test replacement and malformed/unsafe files.

- [ ] **Step 3: Exercise profile, people, employee, and team boundaries**

  Test own-profile edit, private-field visibility, avatar validation, duplicate code, required assignments, effective-dated changes, disposable-account deactivate/reactivate, and five-Member team scopes.

- [ ] **Step 4: Exercise organization configuration validation**

  Inspect offices/Wi-Fi, shifts, leave types, holidays, teams, approval routes, outside-work, and permissions; use only reversible QA-scoped changes and do not overwrite real office coordinates.

- [ ] **Step 5: Exercise reports and XLSX export**

  Verify Manager team-only, HR/Admin organization, and Member-denied scopes across date ranges, empty states, filters, row details, and formula-safe export.

- [ ] **Step 6: Exercise announcements and notifications**

  Publish a synthetic announcement; verify intended recipients, approval/payroll/request notifications, no sensitive payload leakage, account-switch isolation, and actor audit rows.

- [ ] **Step 7: Handle Google Sheets safely**

  Write only if the configured staging sheet is explicitly synthetic; otherwise record external-write scenarios as BLOCKED and test configuration/status read-only.

- [ ] **Step 8: Inspect shared UX and resilience states**

  Across every reached screen, record loading, empty, validation, server-error, offline, retry, repeated-tap, back-navigation, keyboard, and app-resume behavior; use widget evidence for large-text/360dp cases that cannot be changed safely on the owner's phone.

### Task 9: Archive/export/restore lifecycle without deletion

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/archive/`

**Interfaces:**
- Produces: verified local archive, acknowledgement, restore validation, and proof of zero cleanup mutation.

- [ ] **Step 1: Establish pre-run deletion counters**

  Read-only query cleanup jobs, tombstones, archived file inventory, and Storage object counts for the synthetic period; record exact baseline IDs/counts.

- [ ] **Step 2: Generate and download a synthetic closed-period archive**

  Use Admin UI, record manifest/counts/hash, download locally, and verify safe entry paths and spreadsheet cells.

- [ ] **Step 3: Verify and acknowledge the saved archive**

  Complete the UI verification/acknowledgement gates and corroborate state and audit actor read-only.

- [ ] **Step 4: Exercise interruption and invalid restore inputs**

  Test resume, missing/corrupt archive, stale manifest, role denial, reauthentication, and restore validation without overwriting live files.

- [ ] **Step 5: Reach cleanup preview and final confirmation**

  Inspect exact candidate counts, complete typed confirmation if required, then cancel the final destructive dialog without invoking cleanup.

- [ ] **Step 6: Prove zero deletion after cancellation**

  Repeat baseline queries and verify no new cleanup job, tombstone, deleted object, or deleted business row was produced.

### Task 10: Evidence reconciliation, defects, and final verification

**Files:**
- Modify: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/`

**Interfaces:**
- Produces: final scenario-by-scenario PASS/FAIL/BLOCKED report and a release-risk summary; does not claim production readiness.

- [ ] **Step 1: Reconcile every spec bullet to a scenario row**

  Ensure attendance, leave, payroll, files, roles, Admin, reports, notifications, archive, offline, duplicate, stale, empty, and validation coverage each has evidence or a precise BLOCKED reason.

- [ ] **Step 2: Record every defect with a minimal reproduction**

  Include severity, affected roles, `test.md` IDs, expected/actual behavior, request/record IDs, evidence path, and next action without secrets.

- [ ] **Step 3: Fix only approved defects using TDD**

  For each code defect, invoke `superpowers:test-driven-development`, add a failing regression test, implement one root-cause fix, and commit it separately; do not combine unrelated fixes.

- [ ] **Step 4: Run fresh full verification**

  Run: `tool/db_test.sh && .tools/bin/deno test -A supabase/functions/tests/ && flutter analyze && flutter test`

  Expected: all suites pass after any fixes; otherwise the final result remains FAIL/BLOCKED.

- [ ] **Step 5: Verify repository and safety state**

  Confirm no credentials/evidence are staged, no unrelated change was committed, existing accounts remain untouched, `QAHR01` has no unintended open session, and archive deletion counters remain unchanged.

- [ ] **Step 6: Commit the sanitized QA report**

  Run: `git add docs/qa/staging-e2e-2026-10-03.md && git commit -m "docs: record staging end-to-end QA results"`
