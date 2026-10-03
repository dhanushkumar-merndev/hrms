# Employee Data Approvals and QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement dynamic signed-out HR phone support, initiator-based employee-data approvals, and clear punch Wi-Fi evidence, then deploy to the connected Android phone and complete the synthetic staging QA matrix.

**Architecture:** Extend the existing immutable request/revision/event engine for approval-controlled employee and payroll changes. Domain-specific apply functions remain responsible for validation and mutation, with a central routing policy selecting HR/Admin or Admin-only review based on the initiator's effective role; Admin-direct changes invoke the same validators and append audit/domain history without fake self-approval. A narrow signed-out Edge Function exposes only the Admin-configured HR phone, and Flutter renders provisional Wi-Fi scan evidence while leaving punch acceptance authoritative on the server.

**Tech Stack:** PostgreSQL/PostGIS migrations and SQL tests, Supabase Edge Functions/Deno, Flutter/Dart/Riverpod, private Storage, Android/ADB UIAutomator.

**Spec:** `docs/superpowers/specs/2026-10-03-employee-data-approvals-design.md`

**QA Spec:** `docs/superpowers/specs/2026-10-03-staging-end-to-end-qa-design.md`

## Global Constraints

- Member/Manager employee-data changes require active HR or Admin approval; HR-initiated changes require Admin approval; Admin changes apply immediately and are audited.
- The initiator's effective role, not the target employee's role, determines the route; role precedence is Admin, HR, then other.
- No actor can approve their own request, and HR cannot approve an HR-initiated request through UI, deep link, or direct RPC.
- Approved values remain authoritative until the reviewed revision applies transactionally.
- Audit and notification payloads must not contain private profile values, bank values, salary amounts, phone numbers, signed URLs, or document contents.
- Bank account numbers persist only as last four digits; proofs and payslip drafts must be validated, owned, and current at decision time.
- Passwords, credentials, role elevation, device registration, leave, attendance corrections, organization configuration, and archive cleanup retain their dedicated workflows.
- Use only synthetic `QA*` staging records; preserve every existing employee and stop archive cleanup before deletion.
- Work in `codex/employee-data-approvals`; do not stage unrelated changes or secrets.
- Every production behavior change follows RED → GREEN TDD and each task ends with its full named verification command.

## Review Focus

- A multi-role HR/Manager or Admin/HR account must route by the highest role and never obtain self-approval.
- Target values can change while a request waits; approval must fail stale rather than overwrite a newer approved value.
- HR-uploaded payslip drafts must remain invisible until Admin publication approval and must not leak through signed file access.
- Returned/resubmitted sensitive requests must expose only authorized revisions and keep notifications/audits redacted.
- A stale Android Wi-Fi scan is provisional UI evidence only; the fresh submit scan and server policy remain authoritative.

---

### Task 1: Restore a clean baseline

**Files:**
- Modify: `lib/features/approvals/approval_detail_screen.dart`
- Modify: `lib/features/employees/employee_import.dart`
- Modify: `lib/features/salary/employee_salary_section.dart`
- Modify: `test/widget/skeleton_test.dart`

**Interfaces:**
- Produces: analyzer-clean baseline without behavior changes for all later tasks.

- [ ] **Step 1: Capture the failing analyzer baseline**

  Run: `flutter analyze`

  Expected: FAIL with the 10 pre-existing `curly_braces_in_flow_control_structures` / `unnecessary_import` findings recorded during worktree setup.

- [ ] **Step 2: Apply only mechanical lint fixes**

  Add braces around the reported single-statement branches and remove only the reported redundant import. Do not refactor logic.

- [ ] **Step 3: Verify analyzer and existing Flutter tests**

  Run: `flutter analyze && flutter test`

  Expected: analyzer clean and all existing Flutter tests pass.

- [ ] **Step 4: Commit the baseline cleanup**

  Run: `git add lib/features/approvals/approval_detail_screen.dart lib/features/employees/employee_import.dart lib/features/salary/employee_salary_section.dart test/widget/skeleton_test.dart && git commit -m "chore: clear Flutter analyzer baseline"`

### Task 2: Dynamic Admin-configured HR support phone

**Files:**
- Create: `supabase/migrations/20261003130000_support_phone.sql`
- Create: `supabase/functions/public-config/index.ts`
- Create: `supabase/functions/tests/public_config_test.ts`
- Create: `test/unit/support_phone_test.dart`
- Create: `test/widget/login_support_test.dart`
- Create: `lib/features/auth/support_phone.dart`
- Modify: `lib/features/auth/login_screen.dart`
- Modify: `lib/features/admin/organization_screen.dart`
- Modify: `lib/core/auth/session_controller.dart`
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Modify: `supabase/tests/database/01_grants.sql`

**Interfaces:**
- Produces: `SupportPhone.parse(String?)`, `loginSupportProvider`, `public-config` action `login-support`, `organizations.support_phone`, and Admin settings read/write support.
- Consumes: `AppConfig.orgCode`, existing `hrms.ip_hash`/rate-limit conventions, `ApiClient.function(..., authenticated: false)`.

- [ ] **Step 1: Write failing SQL and Deno tests**

  Add tests proving only Admin can set a normalized international phone, invalid input is rejected, the internal signed-out lookup returns only `display_phone` and `tel_uri`, missing values return null, unknown organizations are indistinguishable, IP limits apply, and no employee/HR identity is returned.

- [ ] **Step 2: Run backend tests and verify RED**

  Run: `tool/db_test.sh '01_grants.sql' && .tools/bin/deno test -A supabase/functions/tests/public_config_test.ts`

  Expected: FAIL because the column, RPC, and Edge Function do not exist.

- [ ] **Step 3: Implement support-phone storage and signed-out endpoint**

  Add `support_phone`, Admin settings projection/update validation, an ungranted `internal_login_support(p_org_code, p_ip_hash)` RPC with bounded rate limiting, and the `public-config` Edge Function returning only its safe projection.

- [ ] **Step 4: Run backend tests and verify GREEN**

  Run: `tool/db_test.sh '01_grants.sql' && .tools/bin/deno test -A supabase/functions/tests/public_config_test.ts && .tools/bin/deno check supabase/functions/public-config/index.ts`

  Expected: all targeted tests/checks pass.

- [ ] **Step 5: Write failing Dart unit/widget tests**

  Test normalization/display for `+91 98765 43210`, rejection of arbitrary text/URI injection, login loading/success/fallback/link-failure copy behavior, copy-to-clipboard fallback, and Admin Organization editor binding.

- [ ] **Step 6: Run Flutter tests and verify RED**

  Run: `flutter test test/unit/support_phone_test.dart test/widget/login_support_test.dart`

  Expected: FAIL because support-phone parsing/provider/widgets do not exist.

- [ ] **Step 7: Implement the Flutter support link**

  Add `url_launcher`, load public support once on the signed-out screen, make only the number tappable as `tel:`, keep sign-in independent of lookup failure, and preserve a copy action when launching fails.

- [ ] **Step 8: Run Flutter tests and verify GREEN**

  Run: `flutter analyze && flutter test test/unit/support_phone_test.dart test/widget/login_support_test.dart && flutter test`

  Expected: analyzer clean and all Flutter tests pass.

- [ ] **Step 9: Commit support phone**

  Run: `git add supabase/migrations/20261003130000_support_phone.sql supabase/functions/public-config supabase/functions/tests/public_config_test.ts supabase/tests/database/01_grants.sql lib/features/auth/support_phone.dart lib/features/auth/login_screen.dart lib/features/admin/organization_screen.dart lib/core/auth/session_controller.dart test/unit/support_phone_test.dart test/widget/login_support_test.dart pubspec.yaml pubspec.lock && git commit -m "feat: add dynamic HR support phone"`

### Task 3: Initiator-based request engine

**Files:**
- Create: `supabase/migrations/20261003131000_employee_data_approvals.sql`
- Create: `supabase/tests/database/15_employee_data_approvals.sql`

**Interfaces:**
- Produces: request kinds `profile_details`, `employee_details`, `employee_assignment`, `employee_status`, `salary_change`, `payslip_publish`; helpers `hrms.change_initiator_class`, `hrms.change_reviewer`, `hrms.change_review_authority`, `hrms.assert_change_target_version`, and `hrms.apply_employee_change`.
- Consumes: existing `hrms.requests`, `request_revisions`, `request_events`, idempotency, notification, audit, open/decide/reassign framework.

- [ ] **Step 1: Write failing routing and lifecycle SQL tests**

  Cover Member/Manager → HR-preferred/Admin-fallback, HR/multi-role-HR → Admin-only, Admin-direct marker, missing reviewer, self-approval denial, HR-on-HR-initiation denial, Admin override, allowed reassignments, lock-on-open, return/resubmit/reject/withdraw, stale revision, and idempotent duplicate operations.

- [ ] **Step 2: Run the new database suite and verify RED**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: FAIL because the kinds and helpers do not exist.

- [ ] **Step 3: Implement request kinds, routing, authorization, and safe projections**

  Extend constraints and generic request summary/detail/title support; route by initiator role snapshot; keep sensitive payloads out of list/notification/audit projections; extend open, decide, reassign, and withdrawal handlers without changing leave/correction semantics.

- [ ] **Step 4: Run routing/lifecycle tests and verify GREEN**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: all assertions pass.

- [ ] **Step 5: Run the complete database suite**

  Run: `tool/db_test.sh`

  Expected: every existing and new database suite passes.

- [ ] **Step 6: Commit the approval engine**

  Run: `git add supabase/migrations/20261003131000_employee_data_approvals.sql supabase/tests/database/15_employee_data_approvals.sql && git commit -m "feat: add employee change approval engine"`

### Task 4: Profile and bank-detail approval flows

**Files:**
- Modify: `supabase/migrations/20261003131000_employee_data_approvals.sql`
- Modify: `supabase/tests/database/15_employee_data_approvals.sql`
- Modify: `lib/features/people/profile_screen.dart`
- Modify: `lib/features/salary/bank_details_request_screen.dart`
- Modify: `lib/features/salary/my_salary_screen.dart`
- Modify: `lib/features/requests/request_widgets.dart`
- Create: `test/widget/profile_approval_test.dart`
- Modify: `test/widget/salary_test.dart`

**Interfaces:**
- Produces: `save_profile_details_request`, initiator-based `save_bank_details_request`, Admin-direct validated profile/bank application, pending request summaries in own profile/salary responses.
- Consumes: Task 3 request engine and existing bank proof/file validation.

- [ ] **Step 1: Add failing profile/bank SQL cases**

  Prove approved values stay unchanged while pending; Member/Manager routes HR/Admin; HR routes Admin; Admin applies immediately; returned revision resubmits; stale target fails; duplicate active category fails; full bank number is discarded; proof ownership/state is rechecked; audit/notifications contain no sensitive values.

- [ ] **Step 2: Run database suite and verify RED**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: FAIL on missing profile request and old bank-routing behavior.

- [ ] **Step 3: Implement profile/bank backend flows**

  Replace self-service immediate profile mutation with request creation for non-Admins, keep Admin direct through the shared validator, adjust bank routing by initiator class, and return pending/history metadata only to authorized callers.

- [ ] **Step 4: Run database suite and verify GREEN**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: all profile/bank assertions pass.

- [ ] **Step 5: Write failing Flutter widget tests**

  Assert `Submit for verification` for Member/Manager/HR, `Save now` plus audited copy for Admin, approved-versus-pending display, duplicate pending link, returned edit/resubmit, masked bank values, and no cross-account pending cache.

- [ ] **Step 6: Run Flutter tests and verify RED**

  Run: `flutter test test/widget/profile_approval_test.dart test/widget/salary_test.dart`

  Expected: FAIL on old immediate-save/profile and bank UI behavior.

- [ ] **Step 7: Implement profile/bank UI**

  Bind role-aware copy and pending/history states to server responses; never optimistically replace approved values; invalidate only identity-scoped providers after submit/direct apply.

- [ ] **Step 8: Run Flutter tests and verify GREEN**

  Run: `flutter analyze && flutter test test/widget/profile_approval_test.dart test/widget/salary_test.dart && flutter test`

  Expected: analyzer clean and all Flutter tests pass.

- [ ] **Step 9: Commit profile/bank approvals**

  Run: `git add supabase/migrations/20261003131000_employee_data_approvals.sql supabase/tests/database/15_employee_data_approvals.sql lib/features/people/profile_screen.dart lib/features/salary/bank_details_request_screen.dart lib/features/salary/my_salary_screen.dart lib/features/requests/request_widgets.dart test/widget/profile_approval_test.dart test/widget/salary_test.dart && git commit -m "feat: require profile and bank verification"`

### Task 5: Employee details, assignments, and status approvals

**Files:**
- Modify: `supabase/migrations/20261003131000_employee_data_approvals.sql`
- Modify: `supabase/tests/database/15_employee_data_approvals.sql`
- Modify: `lib/features/employees/employee_detail_screen.dart`
- Modify: `lib/features/employees/employee_import.dart`
- Modify: `lib/features/employees/employee_import_screen.dart`
- Modify: `lib/features/requests/request_widgets.dart`
- Create: `test/widget/employee_change_approval_test.dart`

**Interfaces:**
- Produces: HR-request/Admin-direct behavior for `update_employee`, `update_private_details`, `set_employee_team`, `set_employee_office`, `set_employee_shift`, and `set_employee_status` while keeping original function names as client compatibility boundaries.
- Consumes: Task 3 request engine; original domain validators and effective-dated mutation rules.

- [ ] **Step 1: Add failing employee-domain SQL cases**

  Cover HR proposal versus Admin immediate apply for work/private fields, team/office/shift assignments, activate/deactivate, current/future assignment history, last-Admin and active-cap recheck at approval, cycle detection, stale target, unauthorized Member calls, and redacted audit/notifications.

- [ ] **Step 2: Run database suite and verify RED**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: FAIL because current HR calls mutate immediately.

- [ ] **Step 3: Wrap domain mutations with maker-checker behavior**

  Extract private apply helpers from current functions, preserve Admin semantics, and make authorized HR calls create requests whose reviewed revisions invoke those helpers transactionally.

- [ ] **Step 4: Run database suite and verify GREEN**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: all employee-domain assertions pass.

- [ ] **Step 5: Write failing employee UI/import tests**

  Verify HR sees submit-for-approval results and pending status, Admin sees immediate confirmation, imports report requested versus applied rows separately, duplicates do not create extra requests, and approval detail renders before/proposed assignment values.

- [ ] **Step 6: Run Flutter tests and verify RED**

  Run: `flutter test test/widget/employee_change_approval_test.dart test/unit/employee_import_test.dart`

  Expected: FAIL on immediate-save assumptions.

- [ ] **Step 7: Implement employee UI/import status handling**

  Render server-returned `applied` or `submitted` outcome, link pending requests, and keep bulk-import row results explicit without claiming unapproved changes are active.

- [ ] **Step 8: Run Flutter tests and verify GREEN**

  Run: `flutter analyze && flutter test test/widget/employee_change_approval_test.dart test/unit/employee_import_test.dart && flutter test`

  Expected: analyzer clean and all Flutter tests pass.

- [ ] **Step 9: Commit employee approvals**

  Run: `git add supabase/migrations/20261003131000_employee_data_approvals.sql supabase/tests/database/15_employee_data_approvals.sql lib/features/employees/employee_detail_screen.dart lib/features/employees/employee_import.dart lib/features/employees/employee_import_screen.dart lib/features/requests/request_widgets.dart test/widget/employee_change_approval_test.dart test/unit/employee_import_test.dart && git commit -m "feat: approve HR employee changes"`

### Task 6: Salary and payslip publication approvals

**Files:**
- Modify: `supabase/migrations/20261003131000_employee_data_approvals.sql`
- Modify: `supabase/tests/database/15_employee_data_approvals.sql`
- Modify: `lib/features/salary/employee_salary_section.dart`
- Modify: `lib/features/payroll/payroll_uploads_screen.dart`
- Modify: `lib/features/requests/request_widgets.dart`
- Modify: `lib/features/approvals/approval_detail_screen.dart`
- Modify: `test/widget/salary_test.dart`
- Create: `test/widget/payroll_approval_test.dart`

**Interfaces:**
- Produces: HR-request/Admin-direct behavior for `set_employee_salary` and `publish_payslip`; draft owner/request binding; salary/payslip comparison rendering.
- Consumes: Task 3 request engine, validated private Storage files, salary revision and payslip/file revision history.

- [ ] **Step 1: Add failing payroll SQL cases**

  Prove HR salary changes remain pending and amount-redacted outside detail, HR payslip draft stays invisible, Admin approval publishes exactly the reviewed validated version, replacement reason/history persists, stale/replaced/deleted/wrong-owner draft fails, Admin direct applies once, and notifications contain no amount or URL.

- [ ] **Step 2: Run database suite and verify RED**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: FAIL because current HR salary/payslip operations apply immediately.

- [ ] **Step 3: Implement payroll request/apply flows**

  Extract current salary and payslip mutation bodies behind validated apply helpers; return `submitted` for HR and `applied` for Admin; bind reviewed file version and target versions in the request revision.

- [ ] **Step 4: Run database suite and verify GREEN**

  Run: `tool/db_test.sh '15_employee_data_approvals.sql'`

  Expected: all payroll assertions pass.

- [ ] **Step 5: Write failing Flutter payroll tests**

  Assert role-aware submit/publish copy, pending draft visibility only to initiator/reviewer, masked list rows, explicit comparison on review, Admin-direct confirmation, and no Member/Manager payroll navigation.

- [ ] **Step 6: Run Flutter tests and verify RED**

  Run: `flutter test test/widget/salary_test.dart test/widget/payroll_approval_test.dart`

  Expected: FAIL on immediate salary/publish behavior.

- [ ] **Step 7: Implement payroll UI outcomes**

  Preserve preview/upload, show the server's submitted/applied outcome, link pending request, and refresh owner-visible payslips only after actual publication.

- [ ] **Step 8: Run Flutter tests and verify GREEN**

  Run: `flutter analyze && flutter test test/widget/salary_test.dart test/widget/payroll_approval_test.dart && flutter test`

  Expected: analyzer clean and all Flutter tests pass.

- [ ] **Step 9: Commit payroll approvals**

  Run: `git add supabase/migrations/20261003131000_employee_data_approvals.sql supabase/tests/database/15_employee_data_approvals.sql lib/features/salary/employee_salary_section.dart lib/features/payroll/payroll_uploads_screen.dart lib/features/requests/request_widgets.dart lib/features/approvals/approval_detail_screen.dart test/widget/salary_test.dart test/widget/payroll_approval_test.dart && git commit -m "feat: approve HR payroll changes"`

### Task 7: Complete approval queue, history, and authorization UI

**Files:**
- Modify: `lib/features/approvals/approval_detail_screen.dart`
- Modify: `lib/features/approvals/approvals_screen.dart`
- Modify: `lib/features/requests/request_widgets.dart`
- Modify: `lib/app/app_routes.dart`
- Modify: `test/widget/screens_test.dart`
- Create: `test/widget/change_request_review_test.dart`

**Interfaces:**
- Produces: category-aware request tiles, approved-versus-proposed detail, return/reject/approve actions, role-safe reassign options, requester history links, and deep-link denial states for every new request kind.
- Consumes: Tasks 3–6 request/detail projections.

- [ ] **Step 1: Write failing reviewer/requester widget tests**

  Cover each new category title/detail, sensitive masking, Member/Manager/HR/Admin actions, HR denial on HR-initiated request, Admin reassignment rules, returned/resubmitted history, stale refresh, empty/loading/error states, and account-switch cache isolation.

- [ ] **Step 2: Run widget tests and verify RED**

  Run: `flutter test test/widget/change_request_review_test.dart test/widget/screens_test.dart`

  Expected: FAIL because the existing widgets only understand leave/correction/bank details.

- [ ] **Step 3: Implement category-aware approval and history UI**

  Render server-provided authority and comparisons without client-side authorization assumptions; use generic field-label metadata for non-sensitive fields and explicit masked widgets for profile/bank/salary.

- [ ] **Step 4: Run widget tests and verify GREEN**

  Run: `flutter analyze && flutter test test/widget/change_request_review_test.dart test/widget/screens_test.dart && flutter test`

  Expected: analyzer clean and all Flutter tests pass.

- [ ] **Step 5: Commit approval UI**

  Run: `git add lib/features/approvals/approval_detail_screen.dart lib/features/approvals/approvals_screen.dart lib/features/requests/request_widgets.dart lib/app/app_routes.dart test/widget/screens_test.dart test/widget/change_request_review_test.dart && git commit -m "feat: review employee data requests"`

### Task 8: Connected-versus-nearby Wi-Fi punch evidence

**Files:**
- Create: `lib/features/attendance/wifi_evidence.dart`
- Modify: `lib/features/attendance/punch_controller.dart`
- Modify: `lib/features/attendance/punch_screen.dart`
- Create: `test/unit/wifi_evidence_test.dart`
- Modify: `test/widget/screens_test.dart`

**Interfaces:**
- Produces: `WifiEvidence classifyOfficeWifi(List<String> accepted, String? connected, List<String> nearby)` and `PunchState.wifiEvidence`.
- Consumes: office `wifi_ssids`, `network_info_plus`, `wifi_scan`, and the unchanged server punch rule.

- [ ] **Step 1: Write failing classifier tests**

  Cover case-insensitive connected match, nearby-only match, missing configured SSID, empty policy, blanks/duplicates, and non-office connected Wi-Fi plus office nearby.

- [ ] **Step 2: Run unit tests and verify RED**

  Run: `flutter test test/unit/wifi_evidence_test.dart`

  Expected: FAIL because the classifier does not exist.

- [ ] **Step 3: Implement the pure classifier**

  Add immutable evidence mode/matched-name values using normalized exact SSID matching.

- [ ] **Step 4: Run unit tests and verify GREEN**

  Run: `flutter test test/unit/wifi_evidence_test.dart`

  Expected: all classifier tests pass.

- [ ] **Step 5: Write failing punch widget tests**

  Assert connected, nearby/mobile-data, missing/refresh, no-policy, provisional/stale wording, and successful `Office location and Wi-Fi verified.` copy without calling nearby evidence a connection.

- [ ] **Step 6: Run widget tests and verify RED**

  Run: `flutter test test/widget/screens_test.dart`

  Expected: FAIL because punch UI has no Wi-Fi evidence.

- [ ] **Step 7: Wire provisional scanning into punch state/UI**

  Scan alongside location acquisition, refresh together, and keep a separate fresh submit scan so displayed evidence cannot weaken server validation.

- [ ] **Step 8: Run Flutter checks and verify GREEN**

  Run: `dart format --output=none --set-exit-if-changed lib/features/attendance/wifi_evidence.dart lib/features/attendance/punch_controller.dart lib/features/attendance/punch_screen.dart test/unit/wifi_evidence_test.dart test/widget/screens_test.dart && flutter analyze && flutter test`

  Expected: format clean, analyzer clean, and all Flutter tests pass.

- [ ] **Step 9: Commit Wi-Fi evidence**

  Run: `git add lib/features/attendance/wifi_evidence.dart lib/features/attendance/punch_controller.dart lib/features/attendance/punch_screen.dart test/unit/wifi_evidence_test.dart test/widget/screens_test.dart && git commit -m "feat: show office Wi-Fi punch evidence"`

### Task 9: Full verification, staging deployment, phone update, and QA matrix

**Files:**
- Create: `docs/qa/staging-e2e-2026-10-03.md`
- Evidence only: `test_output/qa-2026-10-03/`
- Read local only: `.env`, `build/app_config.json`, `build/QA_ACCOUNTS.txt`

**Interfaces:**
- Produces: deployed migrations/functions, installed Android build, closed `QAHR01` attendance session, synthetic end-to-end evidence, zero-deletion archive proof, and sanitized PASS/FAIL/BLOCKED report.
- Consumes: Tasks 1–8 and `docs/superpowers/plans/2026-10-03-staging-end-to-end-qa.md` Tasks 2–10.

- [ ] **Step 1: Run complete local verification**

  Run: `tool/db_test.sh && .tools/bin/deno test -A supabase/functions/tests/ && for entry in supabase/functions/*/index.ts; do .tools/bin/deno check "$entry"; done && flutter analyze && flutter test`

  Expected: every database, Deno, and Flutter check passes.

- [ ] **Step 2: Review migration/deployment diff and secret boundaries**

  Confirm only intended migrations/functions deploy, generated app config has no service/access tokens, report/evidence contain no credentials, and existing employee rows are not migration targets.

- [ ] **Step 3: Deploy staging backend**

  Run the repository deployment workflow from the primary checkout's existing `.env`, record exact applied migrations/functions, and stop on any project/organization mismatch.

- [ ] **Step 4: Build and update the existing phone installation**

  Build arm64 release with the existing public app config and run `adb -s S4V8SKXS7PGIHQGI install -r`; never uninstall or clear app data.

- [ ] **Step 5: Execute approval smoke matrix through phone UI**

  Complete Member → HR approval, Manager → HR/Admin approval, HR → Admin approval, Admin-direct profile/bank/employee assignment/salary/payslip cases; verify approved values remain unchanged while pending and every actor/revision/audit result read-only.

- [ ] **Step 6: Execute dynamic support and Wi-Fi phone cases**

  Set a synthetic official support phone through Admin UI, sign out, verify telephone-link/fallback/copy behavior, then verify connected/nearby/missing Wi-Fi text and close the existing `QAHR01` IN session through biometric UI.

- [ ] **Step 7: Execute the remaining full QA plan**

  Complete authentication/cache isolation, attendance corrections, leave variants, uploads/documents/policies, roles/Admin configuration, reports/notifications, offline/duplicate/stale/empty/validation states, and archive generate/download/verify/acknowledge/restore/cleanup-preview scenarios from `2026-10-03-staging-end-to-end-qa.md`.

- [ ] **Step 8: Cancel archive cleanup before deletion and prove zero mutation**

  Record pre/post cleanup-job, tombstone, database-row, and Storage-object counts; cancel the final destructive confirmation and verify all deletion counters are unchanged.

- [ ] **Step 9: Reconcile and commit the sanitized report**

  Give every scenario PASS/FAIL/BLOCKED with start state, UI actions, expected/actual, read-only server evidence, request/record IDs, defects, and exact blockers; commit only `docs/qa/staging-e2e-2026-10-03.md`.

- [ ] **Step 10: Run final safety and regression gate**

  Re-run the complete Step 1 command; verify existing employee/account business rows remain untouched, QA sessions are intentional/closed, no credentials/evidence are tracked, and archive deletion counters remain unchanged.
