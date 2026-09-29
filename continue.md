# Internal HRMS — implementation continuation and release checklist

Version 1.1 · 29 September 2026.

## Current state

- [x] Product scope and four-role permission proposal documented.
- [x] Five specification files created, including implementation-agent instructions.
- [x] Eight original UI references included and mapped in design.md.
- [x] Functional, boundary, authorization, concurrency, export and recovery test plan written.
- [x] v1.1 specification review completed; findings below corrected across the five documents.
- [ ] Application repository inspected or scaffolded.
- [ ] Flutter source code implemented.
- [ ] Supabase/FCM/platform accounts connected or configured.
- [ ] Automated tests implemented/executed.
- [ ] Native Android/iOS builds or deployments produced.
- [ ] Physical-device GPS/security/notification validation completed.

**Status: specification complete; software implementation has not started.** No claims of test execution or provider setup.

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

- [ ] Inspect repo/instructions/git status, preserve existing work.
- [ ] Record Flutter/Dart/Android/macOS-Xcode/Supabase/Deno tooling availability.
- [ ] Pin current compatible dependencies, initialize feature structure/theme/router.
- [ ] Create separate local/staging/prod configs; `.env.example` without secret values.
- [ ] Set up disposable local Supabase and deterministic fake fixtures.
- [ ] Define CI format/analyze/unit/widget/API/DB tasks with actual commands.

Exit: reproducible local app and migrations; tooling blockers recorded accurately. Tests: baseline build plus SEC-001 configuration inspection.

### M1 — identity, organization and authorization

- [ ] Core employee/org/roles/team/office tables, constraints, RLS and scoped projections.
- [ ] Employee ID alias login and server-side provisioning/reset saga.
- [ ] Temporary credential gate, fail-closed credential-operation hold/reconciliation, original-session revocation checks, native Auth bypass tests, rate limits, last-Admin protection.
- [ ] S01–02/16–17/20/25–27/29/33/37 real forms and permissions.
- [ ] Auth audit and current-permission guard used by all future functions.

Exit: cannot read/change other employee's protected data by direct API; no public signup or secret leak. Tests: AUTH, ROLE, EMP, API-001, SEC-002/003.

### M2 — schedules, calendar and calculation engine

- [ ] Effective-dated offices/shifts/team/office assignments and schedule instances.
- [ ] Paid lunch, grace, early entry/credit, checkout extension, overnight handling.
- [ ] Holiday draft/import/manual selection/publish; initial target 12, allowance independent.
- [ ] Exact-second duration model, half-day required intervals and label anchors, absence rules, leave/work conflict guards, partial/unknown report totals.
- [ ] S13/30–32 calendar/configuration with numeric limits and previews.

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
- [ ] S10–12/21–23; notification outbox event insertion.

Exit: all race recipes pass against real database. Tests: LEAVE, REVIEW, CORR, AUDIT-001.

### M5 — private documents and payslips

- [ ] Private staging/final objects, upload reservations and 5,000,000-byte validation.
- [ ] Staging promotion to server-only immutable final objects BEFORE validation/hash; bounded decoded size/parser resources, draft/publish flow.
- [ ] Protected Storage denies direct client SELECT/sign; one audited permission/window/review-checked signing endpoint.
- [ ] Explicit HR payroll grant; protected ownership and latest 12-month API access.
- [ ] Secure PDF preview/download and masked/minimal Home card; no fake payroll amounts.
- [ ] Storage budget ledger/reconciliation and abandoned-upload cleanup.
- [ ] S14–15/18/28; user/account-switch cleanup of sensitive temp data.

Exit: direct Storage/API ID guessing cannot bypass permissions. Tests: FILE, CACHE-001, SEC-001.

### M6 — reports, queries, caching and notifications

- [ ] HR/team day/week/month/custom reports with intervals, expected/worked/short/extra hours.
- [ ] Query-driven indexes, bounded offset and stable cursor pagination, safe search.
- [ ] Riverpod scoped caches/invalidation, lazy lists, loading/empty/offline states.
- [ ] Supabase Cron/Vault/pg_net bounded maintenance runner, leases, health reporting and lazy correctness fallback.
- [ ] Exactly-once inbox state, best-effort/retryable push, token refresh/logout cleanup; APNs integration.
- [ ] S19/24/36 and safe audit views; S38 only simple announcements if enabled.

Exit: metrics/role scope correct, performance measured, push failure doesn't affect transactions. Tests: NOTIF, AUDIT, CACHE, PAGE, PERF.

### M7 — annual archive and local file export

- [ ] Immutable business-period snapshot rows/items, revision watermark, closed-year gates.
- [ ] Admin report XLSX and annual nested ZIP; all eligible employee/file revisions covered.
- [ ] Prototype large streamed archive on Android/iOS, isolate ZIP/XLSX work, bounded memory/disk.
- [ ] Resumable authorized download, checksums/count verification, local Files/document save.
- [ ] XLSX formula protection and safe filename/folder construction.
- [ ] S34–35 export progress, annual due task, overnight provisional status, verified-save acknowledgment.
- [ ] Rebuild full annual archive from validated local originals after cloud cleanup; partial fallback cannot unlock cleanup; explicit period-transition coverage.

Exit: cutoff and as-of behavior clear; incomplete archives never cleanup-eligible. Tests: EXP plus ARCHIVE recipes in test.md.

### M8 — guarded annual file cleanup and restore

- [ ] Reauthentication, current-manifest validation, exact-file preview and period confirmation.
- [ ] Live-window archive warning, file exclusions, no deletion of HR/attendance/leave/audit.
- [ ] Transactional period lock, immutable delete inventory, per-object resumable Storage cleanup.
- [ ] Tombstones, partial-failure result, saved manifest; cross-Admin resume, worker lease and abandon-partial behavior; no false Undo/recovery promise.
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

For a blocked item record: required credential/tool/device, code already completed, exact validation still needed, how to resume safely, and owner action. Do not include credential values. For a bug record minimal reproduction and affected test IDs, not just 'not working'.

At each handoff update completed tasks, actual test results and the next unblocked task. Never mark a feature complete because its UI is present while backend security/export checks are stubbed.
