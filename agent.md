# Implementation agent instructions — Internal HRMS

Version 1.1 · 29 September 2026.

This file tells a coding agent how to implement this specification. It is **not** an installed skill or a claim that an application already exists. The package is documentation plus visual references; source code, cloud projects, credentials, apps and automated tests still need implementation.

## 1. Start prompt

Paste this into your coding tool after extracting the ZIP in your project:

> Read `agent.md`, `architecture.md`, `design.md`, `test.md`, and `continue.md` completely as one project specification. Inspect the eight images under `docs/ui-reference/`. Implement the Flutter Android/iOS HRMS in the order defined in `continue.md`, preserving the confirmed requirements and server-side security. Start with repository/environment inspection, then build each feature end to end with its database, RLS, APIs, Flutter screens and relevant tests. Update `continue.md` after each verified milestone with actual results, remaining work and the next exact step. Do not claim unrun tests, unconfigured providers or production readiness. Use deterministic defaults in the documents; do not add a web portal, payroll calculation or extra services. Keep working through unblocked implementation tasks; when external credentials or native device/signing access is missing, complete local code/tests and clearly record the specific remaining setup.

If the tool supports file mentions, use `@agent.md implement this project`. Some coding tools auto-read `AGENTS.md` rather than `agent.md`; explicitly attach/read this supplied filename so it is not overlooked. Do not duplicate/rename the package silently.

## 2. Mandatory reading and precedence

1. Read all five Markdown files before implementation; inspect UI references at full useful scale. Long screenshots are scroll captures.
2. Treat latest explicit user instruction as the controlling product requirement. Respect applicable repository `AGENTS.md` and tool safety rules; do not override permissions or secret boundaries to satisfy a document.
3. Within this package: `architecture.md` controls business/security/data rules, `design.md` controls screen layout/state, `test.md` controls acceptance evidence, `continue.md` controls sequencing/status. If a real contradiction exists, fix documentation together or ask one focused question only when materially necessary; never silently pick an insecure interpretation.
4. Values in the decision register are selected defaults, not claimed supplied company policy. Make them configurable as stated; Admin onboarding publishes real office/shift/leave values. Never seed unprovided real company coordinates, names, salaries, leave entitlement or credentials.
5. Additional functionality seen in reference screenshots is not in scope automatically. Initial tabs are Home/Action/Explore; Engage and other deferred modules remain hidden until explicitly approved.

## 3. Non-negotiable product rules

- One Flutter Android/iOS app for Member, Manager, HR, Admin; all roles have own attendance/leave. No desktop/web portal.
- Multiple teams; Admin assigns Manager OR HR as approver per team/request type and eligible fallback. No self approval, including Admin leave.
- ID/password login; Admin/authorized HR provisions accounts. Supabase stores auth secrets; temporary passwords one-time display and mandatory first change. Backend, not navigation, enforces account gates and checks original Auth session validity after credential reset; a refreshed JWT must not revive an old session.
- Requests editable only before authorized reviewer detail-open; queue list does not lock. Edited badge + immutable revisions. After review, return-for-changes reopens a new revision. Resolve view/edit and decision races transactionally.
- Server-calculated location/attendance, fresh sample, integrity checks, server timestamp, idempotency, valid punch sequence. No verified offline attendance; no guarantee of perfect GPS/anti-spoofing.
- 10–7 is 9 hours including Admin-configured paid lunch. Grace affects late label, not actual hours. 10:30–7 is 8.5 hours; 10:30–7:30 is 9 hours only with extension enabled.
- Annual holidays and paid-leave entitlement are separate. 12 holidays is initial target; Admin may add. No assumed legal holiday list or silent leave conversion to unpaid.
- Admin/authorized HR uploads payslip PDFs; no automatic payroll/tax engine. 5,000,000-byte cap; latest 12 salary months by business month, not upload timestamp.
- Private file access enforced server-side. Manager doesn't see salary/medical documents via team membership. Don't expose storage keys or signed links broadly.
- Admin annual export after configured year-end; report export can be interim. Snapshot business cutoff remains fixed when downloaded later. Local XLSX/streamed ZIP includes verified employee-folder files and revisions.
- Cleanup is separate, Admin-only, acknowledged local archive + recent reauth + current manifest + explicit confirmation. Delete only inventory file versions; keep HR/attendance/leave records, tombstones and audit. No automatic bulk deletion or blanket bucket prefix wipe.
- Protected request detail must not leak through generic SELECT/Realtime before review lock. Protected Storage objects have no client SELECT/sign route; only audited server-issued short links. Validate/hash immutable final file bytes after staging promotion.
- Expired previous-day open sessions become needs_correction without fabricated OUT, then allow today's IN. Half-day leave changes attendance obligations and late/early anchors. Returned leave releases reservations until resubmission.
- Committed punch retries return the original result before rechecking stale nonce/proof; new uncommitted punches still require all verification.
- Re-export after prior cloud cleanup requires the previous local archive to reconstruct deleted originals. Partial archives never unlock cleanup. Provide safe resume/abandon for partial cleanup.
- All relevant business actions and sensitive access logged with minimal safe metadata. No plaintext passwords, tokens or salary document contents in audit/logs.

## 4. Repository and environment inspection

- Inspect existing code, git status, applicable instructions and available runtimes. Preserve unrelated user work. Never rewrite an existing app blindly.
- Record actual `flutter --version`, Dart, Java/Android SDK, Xcode/macOS availability, Supabase CLI/container runtime and Deno/Node if used. Check `flutter doctor`; Linux Android work can proceed, iOS signing/build requires suitable macOS/Xcode.
- Check current official package/platform documentation before selecting versions. Pin compatible dependencies/lockfiles. No fictitious future version requirements from chat history.
- Check available provider configuration by non-secret status; don't print credential values. Do not claim a CLI/account is connected without evidence. Use placeholders in `.env.example`, never commit secrets. Flutter public Supabase config is distinct from service credentials.
- Set up local disposable Supabase, deterministic synthetic data and platform mocks only in test builds. Production secrets, release attestation and APNs cannot be faked as completed.
- Respect an existing external git repository as source of truth; no copies of production credentials in ZIP exports or documentation.

## 5. Build structure and coding rules

Suggested structure after implementation begins:

```text
lib/
  app/                       # bootstrap, router, theme
  core/                      # errors, time, secure storage, networking, access projection
  features/
    auth/
    home/
    attendance/
    leave/
    approvals/
    employees/
    offices_shifts/
    payroll_files/
    reports/
    archive/
    notifications/
    settings_audit/
supabase/
  migrations/
  functions/
  tests/
test/
integration_test/
docs/ui-reference/
```

Feature folders separate presentation, application, domain and data only as complexity justifies. Avoid ceremonial wrappers for every value. Typed models, normalized errors, versioned payloads, injectable clock and bounded query parameters. Riverpod provides state/async caching; no Redux/Redis by analogy alone. go_router uses UX guards plus server authorization.

Read the v1.1 findings in continue.md before coding. Implement the credential-change fail-closed saga and actual Supabase maintenance runner; do not leave correctness dependent on an unspecified background worker.

DB first for invariants: constraints, FK/indexes, RLS, narrow RPC grants and transaction boundaries. Never place balance/punch/approval permission logic solely in Flutter. Use safe search paths and qualified SQL in definer functions. Direct role writes and accepted event edits denied. Service functions explicitly authorize actor before bypassing RLS. Include adversarial API tests with real normal-user tokens.

Build vertically: database + API + DTO/repository + UI states + meaningful tests together. Do not finish only mocked screens and call feature done. Lazy lists, bounded server pagination/filtering, debounced search and cache invalidation must be implemented where specified. Avoid adding every optimization when data is tiny; measure bottlenecks and keep basic query design correct.

Use foreground-only location and integrity verification behind provider interfaces; production implementations must validate actual proofs, not a client boolean. Implement the nonce-before-sample canonical payload protocol exactly; bind proof after sample collection, then verify at the server. Emulator/mocked providers are compile/environment isolated from production. Never suppress a real integration failure with an unconditional success stub.

For archive files, evaluate a maintained mobile ZIP/XLSX library with file-stream output, incremental hashing and safe limits. Spike >1GB on device before promising the maximum. Do not use an all-in-memory byte-array ZIP or an Edge Function to aggregate the entire archive. If library limitation remains, record a concrete blocker and supported approach; don't drop files from export to make tests pass.

## 6. Verification workflow

For each milestone:

1. Implement its normal, empty/loading/error/offline and permission states from design.
2. Map changed behavior to `test.md` IDs; implement high-risk API/DB tests first.
3. Run smallest relevant suite, inspect actual results, fix regressions. Run wider suites only for concrete shared risk/release gates.
4. Inspect rendered Flutter UI on representative phone dimensions; real screenshots are evidence, static mockups are not functionality tests.
5. Update `continue.md` with actual commands, pass/fail/blocked counts, environment, evidence paths and next step. Mark integration pending where credentials/device access absent.
6. Before release run all P0/applicable P1, build signed native versions with correct attestation, physical office GPS pilot, archive/deletion recovery and backup/restore evidence.

Use Flutter native integration tests, not Playwright for native screens. API tests may use Deno/TypeScript or another lightweight runner. Never run DB resets, deletion fixtures, brute force/security probes against production or real staff data. Report performance measured by build/device/network; don't state 'super fast' without evidence.

## 7. How to resume and finish

At each resume read `continue.md` current status and inspect repository diff; do not redo completed verified work or assume previous checks still apply after schema changes. Address the next unblocked task. Record blocker details without exposing secrets. Do not ask the user to approve every routine reversible implementation decision already specified.

Completion means all core screens, backend permissions, reporting, private file lifecycle and archive/cleanup flows work and tests pass in stated environments. If native signing, provider attestation, APNs, actual office calibration or restore drills remain, state exactly which and keep the release status blocked. Never fabricate deployment or claim this specification ZIP itself is the finished app.
