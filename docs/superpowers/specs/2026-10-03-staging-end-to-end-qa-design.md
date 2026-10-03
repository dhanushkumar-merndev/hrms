# Staging End-to-End QA Design

## Objective

Validate the Internal HRMS staging environment as real staff would use it, through the Android UI on the connected
phone. Cover every implemented feature with complete role-based journeys, safe edge cases, and server-side evidence.
The result is an evidence-backed PASS/FAIL/BLOCKED report, not a claim of production readiness.

## Safety boundary

- Use only the synthetic `QA*` accounts and records created for this exercise.
- Do not modify, reset, deactivate, punch, approve for, upload to, or otherwise change existing employee accounts.
- Synthetic uploads are allowed: PDFs, employee documents, company policies, payroll spreadsheets, and archive files.
- Archive cleanup may reach eligibility checks, preview, typed confirmation, and the final confirmation screen, but the
  final destructive action must be cancelled. No Storage object or database record may be deleted.
- Do not run disposable local reset scripts against staging.
- Do not expose credentials in committed files, screenshots, logs, audit metadata, or the QA report. The ignored
  `build/QA_ACCOUNTS.txt` remains the local credential handoff.
- UI actions are the primary acceptance evidence. Read-only database/API queries may verify state, role scope,
  balances, immutable history, hashes, and audit actor attribution.
- Mutating setup through a server API is allowed only when the UI has no safe bootstrap path, and must use an actual
  QA Admin identity plus the normal audited application RPC/Edge Function. Any exception must be recorded.

## QA organization model

- One synthetic QA Admin: `QAADM01`.
- One synthetic QA HR: `QAHR01`.
- Three synthetic QA Managers: `QAMGR01`–`QAMGR03`.
- Three synthetic teams: QA Alpha, QA Beta, and QA Gamma.
- Five synthetic Members per team: 15 total.
- Each new QA Manager manages exactly one new five-Member QA team for the test flows.
- Existing users and legacy team-manager relationships remain untouched and are excluded from expected QA counts.
- The staging employee cap is 40 for this exercise.
- Main Office keeps its configured geofence and the two configured office Wi-Fi SSIDs.

## Evidence model

Every scenario records:

1. Scenario ID and related `test.md` IDs.
2. Role/account used.
3. Preconditions and synthetic fixture IDs.
4. Start state visible in the UI.
5. UI actions performed.
6. Expected end state.
7. Actual UI end state.
8. Read-only server evidence: status, counts, ledger entries, file metadata, or audit rows.
9. PASS, FAIL, or BLOCKED and the exact reason.

Screenshots and UI hierarchy captures may be stored under ignored `test_output/qa-2026-10-03/`. The final Markdown
report must not contain passwords, tokens, private signed URLs, or sensitive real-employee content.

## Execution strategy

Use a hybrid acceptance approach:

- Android UI for all primary paths, validation messages, role navigation, confirmation dialogs, and lifecycle actions.
- Existing automated SQL/Deno/Flutter suites for concurrency, forced failures, direct API attacks, file parser limits,
  and cases that cannot be safely produced through a real phone UI.
- Read-only staging verification for actor attribution, balances, request revisions, access scope, file hashes, and
  notification/audit rows.
- Network and device tests only when reversible: airplane/network-off error, unauthorized role, stale UI refresh,
  duplicate tap protection, inaccurate/outside-zone punch rejection, and office Wi-Fi absence/presence.
- The punch UI must distinguish an approved Wi-Fi connection from an approved SSID merely detected nearby, and must
  state that mobile data is allowed when nearby detection satisfies the policy. The server remains authoritative.

## Scenario suites

### 1. Authentication and account isolation

- Sign in successfully as Member, Manager, HR, and Admin; confirm each lands in the ready state without a temporary
  password gate.
- Verify bad password, employee-code normalization, generic failure copy, and rate-limit recovery without brute force.
- Sign out and switch roles on the same phone; verify no previous profile, request, file preview, notification, or
  permission remains visible.
- Confirm Member cannot deep-link or navigate to Manager/HR/Admin-only data; Manager cannot see private/salary data;
  HR cannot perform Admin-only elevation/archive cleanup; Admin receives full organization scope.
- Confirm all QA accounts are active, have expected roles, and have no credential hold.

### 2. Attendance, device, geofence, and Wi-Fi

- Show that Check in remains an entry into verification rather than proof of eligibility.
- For a QA Member, test registration prompt and precise-location permission states without displacing the existing
  employee's registered punching identity unless explicitly safe.
- Validate server rejection outside the office radius and when configured office Wi-Fi is neither connected nor seen.
- Verify the punch screen says `Connected to office Wi-Fi: <SSID>`, `Office Wi-Fi detected nearby: <SSID> — mobile
  data is allowed.`, or `Office Wi-Fi not detected. Turn on Wi-Fi and refresh.` as applicable, and reports successful
  server verification without describing nearby detection as a connection.
- At the office, validate a successful IN/OUT pair only when the phone owner can complete biometric confirmation.
- Verify duplicate/illegal sequence behavior, operation recovery, stale/inaccurate location messaging, offline denial,
  and attendance-day evidence.
- Submit an attendance correction, open it as the authorized reviewer, decide it, and confirm effective attendance plus
  immutable original event history.

### 3. Leave and request lifecycle

- Member submits a paid leave request; Admin fallback assigns it; Manager opens it, locking that revision, and approves.
- Verify balance reservation and final debit, inbox notification, request history, and actor audit rows.
- Exercise edit-before-open, return-for-changes, resubmit, reject, withdraw, approved-leave cancellation request,
  cancellation approval/denial, weekend/holiday exclusion, half-day, overlapping-slot rejection, and insufficient paid
  balance. Use separate QA Members/dates so scenarios do not collide.
- Configure normal QA team approval routes through the Admin UI so subsequent requests route automatically.

### 4. Salary, payroll, bank details, and payslips

- Admin/authorized HR records synthetic monthly salary figures for selected QA Members and verifies change history.
- Member sees only their own salary totals; Manager cannot see any team salary; HR/Admin see permitted payroll scope.
- Member submits a bank-detail change using synthetic values; authorized reviewer approves/returns/rejects variants;
  confirm masked display and immutable request history.
- Upload a valid synthetic PDF payslip, preview it, publish it for a salary month, replace it with a second revision and
  reason, and download it as the owner.
- Verify draft invisibility, wrong-owner denial, Manager denial, old/future month limits, invalid extension/MIME/magic,
  zero-byte, oversized-file rejection where safe, filename sanitization, and signed-link expiry behavior.

### 5. Employee and company documents

- Upload a valid synthetic employee document and verify owner plus HR/Admin access.
- Confirm another Member and Manager cannot access private/medical content.
- Upload/draft/publish a synthetic company policy and verify Member visibility only after publication.
- Exercise malformed file, unsafe filename, cancelled picker, duplicate/replacement, and logout/temp-preview cleanup.

### 6. People, profile, employee lifecycle, teams, and permissions

- Validate directory, own profile edit, private detail visibility, and avatar validation with synthetic values/assets.
- HR provisions a Member/Manager but cannot provision HR/Admin; Admin provisions privileged roles in a dedicated
  disposable QA case without affecting the primary matrix.
- Test duplicate employee code, required assignments, role elevation reauthentication, last-Admin protection,
  effective-dated team/office/shift changes, and deactivate/reactivate on disposable QA accounts only.
- Confirm team report scopes remain five Members per new QA team and no cross-team sensitive access is possible.

### 7. Organization configuration

- Admin verifies organization settings, office geofence, configured Wi-Fi SSIDs, shifts, leave types, entitlements,
  holidays, teams, approval routes, outside-work grants, permissions, and audit filters.
- HR verifies only its intended master-data capabilities and cannot perform Admin-only organization/security actions.
- Exercise stale-version handling using two UI reads where safe, input bounds, duplicate names, reporting-cycle rejection,
  and current-location calibration guidance without overwriting real office coordinates.

### 8. Reports, announcements, notifications, and Google Sheets

- Manager views only assigned-team hours; HR/Admin view organization reports; Member bulk/team report access is denied.
- Exercise day/week/month/custom ranges, empty results, filters, row details, and Admin XLSX export with formula-safe data.
- Publish a synthetic announcement and verify recipient inbox visibility and audit attribution.
- Verify approval, payroll, credential, and request notifications contain no private salary/file/location data.
- Verify logout/account switching does not leak push/inbox state.
- Test Google Sheets only if the configured staging sheet is explicitly synthetic; otherwise mark external-write cases
  BLOCKED and validate read-only configuration/status screens.

### 9. Archive, export, restore, and cleanup boundary

- Use a synthetic closed period if one already exists or can be created without rewriting real business history.
- Create the archive snapshot, build/download the local archive, validate manifest/hash/counts, save it, and acknowledge
  the verified local copy.
- Exercise interruption/resume, corrupt or missing local input, safe filenames/formulas, role denial, reauthentication,
  stale-manifest checks, and restore validation without overwriting live files.
- Reach cleanup preview and final typed confirmation only when all gates are genuinely met.
- Cancel at the final destructive confirmation. Verify zero cleanup rows, zero tombstones, and zero deleted objects were
  produced by this QA run.

### 10. UX, resilience, and audit

- Inspect normal, loading, empty, validation, server-error, offline, and retry states across every screen reached.
- Verify no dead buttons/endless loaders, sensible keyboard behavior, safe repeated taps, back navigation, and app resume.
- Run selected 360dp/large-text checks where device controls allow it without disturbing owner accessibility settings;
  otherwise use existing widget tests and mark native large-text evidence BLOCKED.
- Verify every mutation has the correct QA actor, target, action, time, request/revision identifier, redacted metadata,
  and append-only behavior.

## Pass criteria

- Primary Member → reviewer/Admin → Member workflows finish through the Android UI with authoritative server end states.
- Role-visible navigation matches server authorization; direct or deep-linked unauthorized access fails safely.
- Salary, bank, payslip, and document fixtures are synthetic, private, auditable, and downloadable only by permitted roles.
- Each new QA Manager's new-team scope contains exactly five Members.
- No existing employee account or existing employee business record is mutated by the QA run.
- No archive cleanup deletion occurs.
- Every executed scenario has evidence and an honest PASS/FAIL/BLOCKED result.
- Full automated suites are rerun after any code fix discovered during QA; no fix is considered complete without a
  reproducing test and fresh verification.

## Deliverables

- Ignored credential handoff: `build/QA_ACCOUNTS.txt`.
- QA scenario/evidence report: `docs/qa/staging-e2e-2026-10-03.md` with no credentials or secrets.
- Ignored screenshots/log evidence: `test_output/qa-2026-10-03/`.
- Any discovered defect gets a minimal reproduction, related `test.md` IDs, severity, affected roles, and exact next
  action. Code fixes require their own approved design when they materially change behavior.
