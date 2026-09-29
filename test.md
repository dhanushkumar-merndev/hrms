# Internal HRMS — QA blueprint

Version 1.1 · 29 September 2026. Review regressions are included in the existing feature sections. **Specification only: tests below are not claimed executed.** Implements acceptance for [architecture.md](architecture.md) and [design.md](design.md). Track real evidence in [continue.md](continue.md).

This is a risk-based release suite covering defined flows, alternate states, negative/boundary cases, security and recovery. It is not a claim that every possible defect can be enumerated. A feature change requires corresponding cases and fixture updates.

## 1. Layers, priorities and execution rules

- `U`: Dart/domain unit tests with fake clocks and deterministic input.
- `W`: Flutter widget/navigation/accessibility tests.
- `N`: Flutter `integration_test` on Android and iOS; device/OS/native checks marked physical where needed.
- `A`: API contract/integration tests against isolated local/staging Supabase, exercising real Auth claims, RPC/Edge paths and storage.
- `D`: SQL/pgTAP or equivalent transaction/RLS/constraint tests against disposable database.
- `O`: operational, load, security/manual device evidence.
- P0 blocks release (authorization, payroll privacy, accounting, punch integrity, destructive export/cleanup); P1 blocks affected feature release; P2 usability/refinement may be explicitly scheduled if no critical impact.

**Playwright: not applicable to native app journeys.** There is no web UI in this scope. Do not add a fake web app to get Playwright coverage. A Playwright APIRequestContext could run HTTP checks, but standard Deno/TypeScript tests or another lightweight HTTP runner are sufficient. Use Flutter native integration tests, real API tests and physical devices. Native permission dialogs can require documented device automation/manual steps beyond `integration_test`.

Test schema for implementation: ID, requirement/screen, priority, layer, fixtures/preconditions, numbered steps, expected UI/API/DB/file effects, cleanup, execution status, evidence link/build/device. Matrix rows below provide test-specific preconditions/steps/assertions; inherit common setup only where stated. Never mark pass from code review alone.

## 2. Deterministic fixtures

Disposable organization `TEST_ORG` with timezone Asia/Kolkata, Admin A, HR H with payroll grant, HR H2 without payroll grant, Managers M1/M2, employees E1/E2 in Team1 managed by M1, E3 in Team2 managed by M2, and inactive E4. All roles have own employee records and leave accounts. Second organization `OTHER_ORG` with E9 exists solely for isolation attacks.

Office O1=(12.9716,77.5946), test radius=20 m, max accuracy=15 m, freshness=10 s; synthetic points generated geodesically with a trusted test fixture. These are test coordinates, not actual user office location. Office O2 active but unassigned; O3 inactive. Test shift 10:00–19:00, paid lunch 13:00–14:00, grace 30 min, extension 120 min; overnight shift 22:00–07:00. Monday–Friday fixture calendar, holiday 2 October 2026. Clock controllable in test environment only, never client override in production.

Default paid-leave fixture grants 24 half-day units (12 days); this is a test allowance, not a confirmed production entitlement. Reserve/debit fixtures start empty. Route Team1 to M1; separate runs route to H. Admin A's requests route to H. Failed or self-only route is a separate negative fixture.

Files: valid 1 KB and exactly 5,000,000-byte PDFs, 5,000,001-byte PDF, 0-byte file, mismatched MIME, malformed/encrypted PDF, image samples, duplicate names, ZIP traversal names, a staged corrupt hash, and historical revisions. Fake employee data only. Valid PDFs must be structurally valid even in boundary fixtures, not random bytes with PDF extension.

Year fixtures: closed Jan–Dec 2025, current 2026, closed Apr 2025–Mar 2026, Sep 2026 report with Oct 1/2/3 export clocks; Sep payslip uploaded Oct 2; future Oct event; overnight shift crossing September cutoff. Include inactive employee and archive revision r1/r2. Each test seeds only its named conditions and rolls back or uses isolated IDs.

## 3. Authentication, roles and employee lifecycle

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| AUTH-001 | P0 A/N | Provision E1 with Admin, sign in using code + temporary password, open business endpoint before change | Restricted session; PASSWORD_CHANGE_REQUIRED, no private business data |
| AUTH-002 | P0 A/N | Complete first password change then fresh login | Gate cleared only after Auth success; new password works, old fails |
| AUTH-003 | P0 A/D | Force Auth password update failure, then DB gate-update failure on retry | No falsely cleared gate; safe retry/reconciliation, no partial privileged session |
| AUTH-004 | P0 A | H provisions Member/Manager; attempts Admin/HR assignment or self payroll grant | Allowed scope succeeds; elevation denied without partial record/grant |
| AUTH-005 | P0 A/D | Duplicate code with case/space variations; simultaneous provisioning same code | One identity; canonical uniqueness; second conflicts, no orphan Auth user |
| AUTH-006 | P0 A | Unknown ID, wrong password, deactivated ID, repeated brute force | Generic failure; bounded account/IP rate limit; no existence/private email leak |
| AUTH-007 | P0 A/N | HR resets E1, replay prior access and refresh sessions for business API | Old session rejected even after refresh produces a new JWT; new temporary login restricted |
| AUTH-008 | P0 A/D | HR attempts reset Admin; deactivate/delete last Admin; public signup call | All denied; at least one active Admin remains; no signup-created privileges |
| AUTH-009 | P0 A | Tamper JWT role/employee_id; call anonymous, expired and cross-org | Invalid token denied; valid foreign identity sees no rows; no trusting client role |
| AUTH-010 | P1 W/N | ID normalization, password spaces/paste, keyboard, bad network, failed refresh | Code normalized, password preserved, generic error, no endless loader or lost input |
| AUTH-011 | P0 A/N | E1 logout/account switch to E2 on same phone | Tokens/sensitive caches/temp previews cleared; E2 never sees E1 details |
| AUTH-012 | P1 A/D | Provision Auth succeeds and employee linking fails; retry same operation ID | Reconciles one account; remains inactive/restricted until linked; audit exact once |
| AUTH-013 | P0 A/D | Call sensitive action with forged recent timestamp, refreshed token, wrong-target/expired/used reauth grant | Denied; only server password-verified unexpired actor/session/action grant works |
| AUTH-014 | P0 A/D | Force an existing-user password reset/change to succeed in Auth but fail app finalization; replay prior sessions | Business-operation hold remains; old access and refreshed tokens denied; only restricted recovery allowed; correct reconciliation clears hold last |
| AUTH-015 | P0 A | Use direct Auth updateUser/password/metadata/email-recovery calls outside app UI | No role/employee relinking or bootstrap-gate bypass; native password policy holds; alias anomaly flagged and recoverable; no deliverable reset to synthetic inbox |
| ROLE-001 | P0 A/D | Exercise every table/read RPC as E1/M1/H/H2/A/E9 | Matches architecture permission matrix; direct URL/ID cannot bypass scope |
| ROLE-002 | P0 A/D | M1 requests E3/E9 attendance, E1 payslip, private profile or medical attachment | Denied even though directory may expose E1 name; no sensitive fields sent |
| ROLE-003 | P0 A | Demote reviewer/disable employee after app loads queue | New action denied; cached permissions not accepted |
| ROLE-004 | P1 A/D | Change employee team/manager effective next month; query old/new shifts | Effective dates respected; no silent reroute of submitted request |
| ROLE-005 | P0 A/D | Move E1 Team1 to Team2; M1 still manages Team1, M2 Team2; query both periods and retained single approval | Report access uses work-date membership plus current team authority; approval grant only opens its one request, not all historical records |
| EMP-001 | P1 A/N | Create employee with all required fields, assign office/team/shift, edit personal details | Valid profile/directory projections; versions/audit; no accidental salary fields |
| EMP-002 | P0 A/D | Set join>end, overlapping assignments, manager cycle, foreign-org team/office | Validation/constraints reject transaction completely |
| EMP-003 | P1 A/N | Deactivate with pending approvals/open attendance; view historical reports | Access/punch/approval disabled; records retained; Admin sees reassignment/exception task |
| EMP-004 | P1 W/N | Long/multiscript name, no photo, avatar error, duplicate visible names | Layout usable; code distinguishes people; fallback avatar; no crash |
| EMP-005 | P1 A/D | Submit 20th then two concurrent 21st active employees when configured cap=20 | Cap enforced transactionally; inactive history doesn't consume active allowance |

## 4. Location, device security and punches

Every GPS boundary uses deterministic server-distance fixtures; supplement with physical indoor/outdoor evidence. Simulated success cannot certify actual office accuracy.

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| LOC-001 | P0 U/A/N | Active E1, valid proof, fresh 5 m-accuracy point 10 m from O1; punch | One accepted IN, official server time, correct session and evidence |
| LOC-002 | P0 U/A | Unit comparison at exactly20m; geodesic fixtures19.999 and20.001m with fixture error <=0.000001m | <=20 accepted and >20 rejected using defined geodesic comparison; no client bool authority |
| LOC-003 | P0 A | Accuracy 15, 15.001, 0, negative, NaN, infinity/missing | 15 valid; others fail appropriately; malformed JSON number rejected before SQL |
| LOC-004 | P0 U/A | Sample age 10 s, 10.001 s; future 2 s and 2.001 s under controlled server time | Bounds match <=10s and <=2s at trusted edge receipt; no stale/future accepted beyond limits |
| LOC-005 | P0 A | Invalid lat/lon, swapped coordinates, client inside=true while outside | Reject range/zone; server computes meters independently |
| LOC-006 | P1 W/N | Permission denied/permanently denied, Location Services off, iOS approximate only | Clear actionable state/settings link; no success; no repeated permission spam |
| LOC-007 | P1 N/O | Indoor GPS drift/acquisition timeout, move to open area and retry | Bounded wait, accuracy status; no fabricated precision; site pilot evidence recorded |
| LOC-008 | P0 A | O1 deactivated or unassigned after screen ready; coordinates/radius changes | Server rechecks latest active policy; reject/re-evaluate, record policy version |
| LOC-009 | P0 A | Valid proof replayed with new action/location/actor/device; expired challenge | Bound request rejected; no event; restricted security log |
| LOC-010 | P0 A/O | Mock flag, invalid Play Integrity, invalid App Attest cert/assertion/counter | Fail according to explicit policy; generic user error; proof not trusted from client |
| LOC-011 | P0 A/N | Integrity provider timeout/unsupported device/revoked installation | No verified punch under default fail policy; correction path available |
| LOC-012 | P0 A/O | Production request using emulator development bypass/forged environment flag | Rejected; no production test bypass exists |
| LOC-013 | P1 N/O | Punch permission journey + leave app idle for one hour | Foreground permission only; no background GPS access, bounded battery activity |
| LOC-014 | P1 A/U | Strict uncertainty mode on: distance 10+accuracy 10 vs 11+10 with radius20 | First <=20 passes, second fails; UI explains precision; mode version recorded |
| PUNCH-001 | P0 A/D/N | IN then valid OUT; repeated IN/OUT without sequence | Normal pair stored once; illegal transitions rejected without partial changes |
| PUNCH-002 | P0 A/D | Two concurrent IN requests different keys at same employee/shift | One succeeds; other sees state conflict; one open session/event only |
| PUNCH-003 | P0 A | Repeat same key+payload then same key+different payload | Same result reused; payload mismatch rejected; original timestamp unchanged |
| PUNCH-004 | P0 A/N | Commit IN but drop response; restart app and query operation status | Reconciles committed IN, no second punch or false failure retry |
| PUNCH-005 | P0 A/D | Fail after event write before session/outbox commit | Entire transaction rolls back; retry produces one complete state |
| PUNCH-006 | P0 A/N | No network; change phone clock/timezone and retry with connection | No offline verified record; server time authoritative, UI error correct |
| PUNCH-007 | P1 A | Spam valid/invalid punches/challenges beyond rate budget | 429/retry hint, bounded logs; legitimate retry after cooldown works |
| PUNCH-008 | P0 A/D | Direct REST INSERT/UPDATE/DELETE accepted attendance tables | Denied for all app roles including Admin; approved adjustment path required |
| PUNCH-009 | P1 A | No shift, weekly off, inactive employee, active unassigned office | Explicit invalid/inactive policy result; no ambiguous attendance |
| PUNCH-010 | P1 N | Background/kill app during GPS and verification, resume | GPS stopped, operation reconciled, no stuck button or phantom success |
| PUNCH-011 | P0 A/D/N | Leave yesterday IN open past last checkout cutoff; maintenance unavailable; submit today IN then stale yesterday OUT | Next-IN transaction marks old session needs_correction without OUT, accepts new IN once; stale OUT cannot close new session |
| PUNCH-012 | P0 A/D | Commit punch then lose response; retry same key/body after challenge/proof/sample expires; also race two same-key requests | Authorized replay returns original result before freshness/counter checks; row-lock recheck avoids second event; differing body conflicts |
| PUNCH-013 | P0 A | Request nonce before GPS sample, bind canonical payload after sample; tamper location/device/action/nonce and numeric encoding | Valid ordered protocol passes; proof must match server-reconstructed exact versioned payload; altered payload fails |

## 5. Hours, calendars and policy calculations

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| TIME-001 | P0 U/A/D | 10:00–19:00 shift/punch with paid lunch 13–14 | Presence=32,400s, credited=32,400s, required=32,400s, short=0 |
| TIME-002 | P0 U/A | Punch10:30–19:00, grace 30 | Credited30,600s, short1,800s; not late; lunch not deducted |
| TIME-003 | P0 U/A | Punch10:30–19:30 with extension enabled | Credited32,400s, short0; no automatic overtime pay |
| TIME-004 | P0 U/A | 10:30:00 vs10:30:01 arrival; 19:00 OUT | First within grace; second late and seconds retained in math |
| TIME-005 | P0 U/A | Early9:30 IN,19 OUT under no early credit | Presence9:30 but credited9:00; raw interval retained |
| TIME-006 | P0 U/A | Extension disabled, OUT after19; enabled120m OUT21 vs21:00:01 | Normal boundary accepted as configured; beyond window rejected, needs correction |
| TIME-007 | P0 U/A | Overnight22–07, IN22:15 OUT07 next date | Shift-start date grouping, credited8:45, short0:15; duration nonnegative |
| TIME-008 | P1 U/A | Open shift before cutoff; missing OUT after cutoff | In-progress provisional totals then Needs correction; no fake final zero/full hours |
| TIME-009 | P0 U/A | Full leave, AM half leave, published holiday, weekly off | Adjusted required0,4:30,0,0; leave credit distinct from worked hours |
| TIME-010 | P0 U/A | Day1 short30m,day2 extra30m | Weekly short30m and extra30m separately; no unconfigured netting |
| TIME-011 | P1 U/A | Lunch outside shift/negative/overnight range; prospective shift change | Invalid rejected; historical policy snapshot unchanged |
| TIME-012 | P1 A/D | Calendar query last day, leap Feb29, month31, custom366-day boundary | Half-open query boundaries correct; 367 rejected or routed to explicit export |
| TIME-013 | P1 U/A | Office timezone differs from device; daylight-saving sample test office | UTC duration correct, local shift date preserved; ambiguous local times explicitly resolved |
| TIME-014 | P1 A | Manager reports team vs HR all; change filters while request pending | Scoped rows/totals correct; old response cannot replace new filter result |
| TIME-015 | P0 U/A | AM leave10:00–14:30, IN14:30 OUT19:00, paid lunch and30m grace | Required/credited4:30, no late/early/short; 15:00 IN stays within grace but short30m |
| TIME-016 | P0 U/A | PM leave14:30–19:00, IN10:00 OUT14:30; then raw presence extends into approved leave | No early label for14:30 OUT; partial-leave credit limited4:30; overlapping extra presence flagged, not silently credited |
| TIME-017 | P1 U/A | No punches on required day after cutoff, future hire, ended employment, full leave/holiday, incomplete partial session | Absent only for eligible required no-punch day; incomplete session unknown; totals disclose unresolved count instead of false complete hours |
| TIME-018 | P0 A/D | Approved full leave vs ordinary IN; pending/retroactive leave overlaps accepted punches or effective corrections | Full-leave IN blocked until approved cancellation; holiday work needs separate schedule exception; overlapping leave approval makes no debit change |
| HOL-001 | P1 A/N | Admin enters 12 company holidays, publishes, then adds 13th | Allowed with visible target update; not confused with paid-leave allowance |
| HOL-002 | P1 A | API import duplicate/regional/observance; API unavailable | Suggestions only, de-duplicate scoped date; manual operation works offline from provider |
| HOL-003 | P0 A/D | Add future holiday inside approved leave interval and rerun reconciliation | Units credited/released exactly once; history + notification; no silent duplicate credit |
| HOL-004 | P0 A/D | Change past holiday/shift or annual start with closed reports | Requires versioned audited correction; old snapshots intact; no retroactive silent rewrite |

## 6. Leave, review locks and correction workflow

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| LEAVE-001 | P0 A/N | E1 requests2 eligible full days, Manager opens and approves | Reserve4 units then debit4 once; balance20 units; request/audit/notification correct |
| LEAVE-002 | P0 U/A | Date range includes weekend/holiday; AM/PM half days | Server counts eligible units; reserved slot correct; no holiday deduction |
| LEAVE-003 | P0 A/D | Insufficient paid balance, submit; explicitly select enabled unpaid instead | Paid request rejects, unpaid accepted only by explicit choice |
| LEAVE-004 | P0 A/D | Two simultaneous requests jointly exceed available balance | Lock prevents overdraw; only affordable reservation succeeds |
| LEAVE-005 | P0 A/D | Overlap same full/half-day slot; different non-overlapping half slots | Conflict rejected; complementary half slots allowed if policy permits |
| LEAVE-006 | P0 A/D | Cross leave-year request, insufficient balance only in second year | Atomic all-or-nothing; no debit/reservation only in first year |
| LEAVE-007 | P1 A | Backdating7-day boundary vs8; advance/max-consecutive limits | Server-configured inclusive boundaries applied; field errors useful |
| LEAVE-008 | P0 A/D | Approve after balance/policy change; cancellation/rejection repeated | Revalidate, no overdraft; release/credit exactly once via ledger references |
| LEAVE-009 | P0 A/N | Cancel approved leave then approve cancellation vs deny | Pending cancellation retains debit; accepted credits once; denied remains approved |
| LEAVE-010 | P1 U/D | Carry cap/expiry, prorata/leap-year/accrual if enabled; disabled default | Configured math exact in half-day units; disabled feature has no effect |
| LEAVE-011 | P0 A/D/N | Submit leave, reviewer returns it, employee uses released balance elsewhere then edits/resubmits returned request | Return releases reservation/slots once; edit reserves none; resubmit revalidates and rejects insufficient available balance without negative units |
| LEAVE-012 | P0 A/D | Edit unviewed request from1 to2 days with insufficient balance or occupied day; inject mid-transaction failure | Old request/version/reservation intact on failed edit; successful exchange atomic, no duplicate day locks |
| LEAVE-013 | P0 U/A/D | Cancel approved previous-year leave after carry expiry; accept twice; inspect both year/type ledgers | One credit to original allocation; expiry/carry reconciliation cannot create fresh current-year units accidentally |
| LEAVE-014 | P1 A | Request range all holidays/offs, before joining or after employment end | Zero/invalid requests rejected with field explanation; no reservation or request affecting balance |
| REVIEW-001 | P0 A/N | Submit, reviewer lists queue, owner edits | Listing does not lock; version increments, Edited badge and revision saved |
| REVIEW-002 | P0 A/D | Reviewer opens detail; owner edits using prior/current version | REQUEST_LOCKED after first authorized open; no overwritten fields |
| REVIEW-003 | P0 A/D | Barrier race: owner edit and first reviewer open launched concurrently | Either updated version is reviewed or edit denied; no stale unseen approval |
| REVIEW-004 | P0 A | Unauthorized employee opens reviewer URL; owner views own detail | Unauthorized read denied and no lock; owner view doesn't lock |
| REVIEW-005 | P0 A/N | Reviewer returns with reason; owner edits and resubmits | New revision editable until new review; prior lock/action preserved |
| REVIEW-006 | P0 A/D | HR/Admin concurrent approve vs reject same version | Exactly one state/ledger decision, loser conflict; no double notification |
| REVIEW-007 | P0 A/D | All roles submit own leave, including Admin and HR; try self approve | Request recorded; self decision denied; designated other reviewer succeeds |
| REVIEW-008 | P0 A | Approver inactive, route self-only/missing; Admin reassigns | Pending exception, no auto approval; reassignment reason/audit; old actor loses rights |
| REVIEW-009 | P0 A | Admin switches team route Manager to HR while old request pending | Old snapshot remains until explicit reassignment; new requests use new route |
| REVIEW-010 | P1 A/N | Reject/return/reassign without reason; stale decision version | Required reason/stale version errors; no partial effects; refresh prompt |
| REVIEW-011 | P0 A/D | Assigned reviewer requests raw detail/revisions using REST/GraphQL/Realtime/queue/export before opening | Detailed payload denied/absent; only minimal summary available; no bypass around atomic detail-open lock |
| REVIEW-012 | P0 A/D | Assigned reviewer attempts direct attachment signing before detail review; owner previews same attachment | Reviewer path acquires/checks current revision lock or denies; owner path never marks reviewed; storage direct signing denied |
| REVIEW-013 | P0 A/N | Request withdrawal during review, decline then accept on retry; decline an approved-leave cancellation | WithdrawalPending disallows approve/reject until resolved; declined cancellation restores Approved unchanged; no duplicate ledger event |
| CORR-001 | P0 A/D/N | E1 missed checkout, request valid OUT, eligible HR approves | Original events unchanged; append adjustment, recalc effective session/totals, audit |
| CORR-002 | P0 A/D | Correction OUT<IN without next-day flag, outside assignment, foreign session | Reject invalid interval/ownership; no change |
| CORR-003 | P0 A/D | Two correction approvals for same session revision concurrently | One effective revision, second conflicts/re-review; no lost update |
| CORR-004 | P1 A/N | Correction evidence attachment replaced before vs after review | Before creates revision/hash; after locked; authorized private review only |
| CORR-005 | P0 A/D | Correction approved for exported closed period | Archive becomes stale for cleanup; re-export required; audit retained |
| CORR-006 | P0 A/D | Both punches missing on scheduled workday; HR approves proposed interval | New effective manual session/adjustment, no fabricated GPS events; original empty evidence preserved |
| CORR-007 | P0 A/D | Attempt to cancel/delete already approved attendance correction; submit separately approved reversal instead | Raw erase denied; new adjustment references current revision, original history retained and effective totals recalculated |

## 7. File privacy, payslips and storage quotas

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| FILE-001 | P0 A/N | H with payroll grant uploads valid PDF, preview/publish for E1/month | Verified size/MIME/hash; E1 sees after publish only; E2/M1 cannot read |
| FILE-002 | P0 A | H2/no payroll grant and Member invoke upload/publish/download for E1 | Denied by API/storage even if guessed object ID |
| FILE-003 | P0 A/D | Boundary valid PDFs size0,5,000,000,5,000,001 bytes | Zero/too-large rejected; exact max accepted; actual storage length checked |
| FILE-004 | P0 A | MIME extension mismatch, malformed/encrypted PDF, script name, bad magic | Quarantine/reject; never publicly serve or execute; sanitized display |
| FILE-005 | P0 A/D | Employee changed in finish/publish; foreign path; overwrite UUID | Reauthorize immutable owner/month, reject object substitution/overwrite |
| FILE-006 | P0 A | Direct bucket list/download anonymous/member/expired URL | No direct protected-object read/list/sign; checked endpoint only; expired signed URL fails |
| FILE-007 | P0 A/N | Role revoked after URL issued; before next download | New access denied; <=60s bearer expiry limitation documented/tested; no permanence claim |
| FILE-008 | P1 A/N | Upload same employee/month; publish replacement with reason | One current version; original retained for audit/export; one publish notification |
| FILE-009 | P0 A/N | Current month Sep2026; files Sep25,Oct25,Sep26,Oct26; query directly as Member | Only Oct25–Sep26 period slots eligible; API enforces same window as UI; future/older denied |
| FILE-010 | P0 A/N | Delete cloud files via completed annual cleanup within visible window | Metadata shows archived/contact HR; no dead download; cannot bypass with old metadata |
| FILE-011 | P1 A/D | Abort upload, duplicate finish, timeout hash computation | Idempotent retry; stale staging reconciled; quota reservation released once |
| FILE-012 | P0 A/D | Concurrent uploads near budget and actual usage exceeds ledger | Reservations prevent planned overrun; reconcile/provider error handled; never auto-delete |
| FILE-013 | P1 N/O | Preview valid PDF, background/logout/app crash then relaunch | Mask/reset; sensitive temp files cleaned/excluded from backup as supported |
| FILE-014 | P1 A/N | Avatar malformed/oversized; private profile edit unauthorized fields | Image processing safe and bounded; role/team changes denied in self endpoint |
| FILE-015 | P0 A | Request medical document from Manager without separate grant | No content/signed URL; useful leave decision fields only |
| FILE-016 | P0 A | Owner Member calls generic Storage download/list/createSignedUrl with604800s TTL on own payslip; then app access endpoint | Generic calls denied; checked endpoint audits grant and returns <=60s URL; role/window restrictions remain server enforced |
| FILE-017 | P0 A/D | Race/replay staging upload replacement during and after finish_upload, then publish/export | Validated hash belongs to immutable server-only final bytes; mutable staging cannot swap published content; quota accounts temporary copies |
| FILE-018 | P0 A/O | Small compressed PDF/image expands beyond parser dimensions/object/memory bounds or exceeds CPU deadline | Rejected/quarantined safely, never published unvalidated; no unbounded runtime or quota leak |

## 8. Export, cutoff, local archive and deletion

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| EXP-001 | P0 U/A/N | Annual archive before/at start of day after year-end in org timezone | Disabled before closure; enabled at next midnight; no device-clock bypass |
| EXP-002 | P1 A/N | Current-year date-range XLSX report | Allowed as interim report; does not unlock annual cleanup |
| EXP-003 | P0 U/A | Sep report exported Oct1,Oct2,Oct3 with Sep/Oct business dates | Always through Sep30; excludes Oct work dates; includes Sep payslip uploaded Oct2 if in snapshot |
| EXP-004 | P0 U/A/D | Jan–Dec and Apr–Mar jobs, leap years and midnight/overnight intervals | Frozen exact bounds/timezone; no 30-day assumption; shift start date grouping |
| EXP-005 | P0 A/D | Create snapshot then mutate a September correction/file | Snapshot stays immutable; cleanup stale; new r2 includes changes |
| EXP-006 | P0 A/D | Create Sep snapshot then add October attendance only | Sep job remains valid; out-of-period additions cannot expand inventory |
| EXP-007 | P0 A/N | Export inactive employee, multiple same names, all period revisions | Correct employee-code folders and full file inventory; no omitted deletion-target version |
| EXP-008 | P0 A/O | Values start=,+,-,@; filename../absolute/reserved names | XLSX values inert text; safe relative ZIP paths; no formula/path execution |
| EXP-009 | P1 N/O | Download interruption after n/N, app killed, permission revoked, resume | Verified files reused; fresh authorized URLs; cursor/progress intact; revoked actor denied |
| EXP-010 | P0 N/O | Corrupt file bytes/hash, missing object, sheet row-count mismatch | Archive verification fails, cleanup disabled; no false success acknowledgment |
| EXP-011 | P0 N/O | Disk full/save picker cancelled/Files permission denied | Incomplete status, recoverable retry; never records local-save success |
| EXP-012 | P1 N/O | Maximum-size annual inventory >1GB representative fixture | Bounded memory, disk estimate, streaming/no UI freeze; no single Edge ZIP build |
| EXP-013 | P0 A | Member/Manager/HR request bulk export or another Admin's forged job | Non-Admin denied; authorized Admin scope and recent-auth checks enforced |
| EXP-014 | P1 A/N | Year rollover, dismiss reminder/reopen; export later completes | Admin due task persists until completion; staff attendance unaffected |
| EXP-015 | P0 A/N | Archive includes profile snapshot, cross-year leave and pending requests | Labels as-of/profile state; leave days intersect period, pending never approved |
| EXP-016 | P0 A/N/O | After annual cleanup, add late old-year file; select correct prior local archive and rebuild complete annual revision | Validate prior manifest and each required trusted hash; include original/revision bytes plus new file and refreshed XLSX; no omitted tombstones |
| EXP-017 | P0 A/N | Same old-year re-export with missing/corrupt/foreign prior ZIP or traversal/decompression-bomb entry | No complete status/cleanup eligibility; bounded validation; partial export visibly lists missing files and cannot unlock cleanup |
| EXP-018 | P0 U/A | At Jan1 00:05 a Dec31 overnight shift remains punchable until09:00; export then attempt cleanup and valid OUT | Export allowed but provisional; cleanup denied until no live prior-period schedule; OUT works and snapshot becomes stale if changed |
| EXP-019 | P1 U/A | Switch annual cycle Jan–Dec to Apr–Mar after existing jobs; create transition and next period | Explicit Jan–Mar transition plus following Apr–Mar cover each month once; existing period IDs/bounds immutable |
| DEL-001 | P0 A/D | Call cleanup before closure/export verification/save ack/reauth | Server rejects each missing gate; UI cannot bypass via direct request |
| DEL-002 | P0 A/N | Eligible closed-year archive; review preview and confirm period | Deletes only immutable verified file-version IDs; retained records and audit unchanged |
| DEL-003 | P0 A/D | Add late file before begin-cleanup transaction vs after period lock | Before invalidates manifest; after returns period-busy; no unexported bytes deleted |
| DEL-004 | P0 A/D | Manifest tampered hash/item/count; request broader prefix deletion | Reject; no arbitrary paths/bucket-wide delete |
| DEL-005 | P0 A/O | Fail Storage deletion midway; crash after deletion before DB mark; resume | Idempotent per-item reconciliation; partial status truthful; no retry of unrelated objects |
| DEL-006 | P0 A/D | Include avatar/undated contract/company policy/active review attachment | Excluded; no accidental deletion; preview manifest explains exclusions |
| DEL-007 | P0 A/D | Cleanup overlaps another active pinned export | Denied/queued until pins release/expire safely; no corrupt active archive |
| DEL-008 | P0 A/N | Admin cancels confirmation; then attempts duplicate completed job | Cancel has zero mutation; repeat returns completed summary, no new delete |
| DEL-009 | P0 A/D | Check employees/events/leave ledger/audit/manifests after cleanup | Counts unchanged; file tombstones/archive IDs retained; balances/reports still work |
| DEL-010 | P1 A/O | Assisted restore from local ZIP with valid vs mismatched hashes | Valid files restored as audited versions; corrupt/foreign records denied; no silent old-version overwrite |
| DEL-011 | P0 A/D/O | Crash worker during cleanup; demote initiating Admin; second Admin with new reauth resumes while stale worker returns | Exclusive lease prevents concurrent batches; stale worker cannot dispatch new deletes; authorized takeover inventory unchanged; in-flight result reconciled |
| DEL-012 | P0 A/N | Partial cleanup then Abandon; edit period and attempt old job resume/new cleanup | Deleted files remain tombstones, remaining preserved; period gate cleared, old worker/resume rejected; new cleanup needs new verified full archive |

## 9. Notifications, audit, caches, API and nonfunctional behavior

| ID | P / layer | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| NOTIF-001 | P1 A/D | Commit approval/punch; simulate FCM failure then retry | Main transaction succeeds, outbox retries, exactly one inbox event; provider push may duplicate and carries stable event ID |
| NOTIF-002 | P0 A/N | Token refresh, logout then different employee login on device | Token reassigned/revoked securely; no prior employee private notification |
| NOTIF-003 | P1 N/O | Android/iOS permission denied, APNs unavailable, app closed | Core app works; no false delivery claim; inbox authoritative on resume |
| NOTIF-004 | P0 A/N | Salary/medical leave event push payload inspected | No salary amount/medical reason/GPS/private document URL |
| NOTIF-005 | P1 A/N | FCM accepts event but response lost; worker retries same event ID | Exactly one in-app row; duplicate push tolerated/de-duplicated where app controls it; no false exactly-once OS-delivery claim |
| AUDIT-001 | P0 A/D | Provision/edit/view-review/approve/upload/publish/export/delete actions | Actor, target, time, action, request ID/revision recorded with appropriate redaction |
| AUDIT-002 | P0 A/D | All app roles attempt UPDATE/DELETE audit; inspect ordinary HR audit | Write/delete denied; HR sees scoped fields only; no passwords/tokens |
| AUDIT-003 | P1 A | Issue signed link without opening, then app reports open | Separate events; do not claim human read merely from URL issuance |
| CACHE-001 | P0 W/N/A | E1 loads, switch E2; role/team downgrade while cached list present | Clears or restricts state; requests always reauthorized; no cross-user content leak |
| CACHE-002 | P1 W/A | Approve leave/change holiday/upload payslip; revisit dashboard/list | Relevant cache invalidated/refreshed; no stale balance used for submit |
| CACHE-003 | P1 W/N | Offline with cached history then online resume | Visible stale/offline indicator; no mutating offline success; refresh on resume |
| CACHE-004 | P1 W/N/A | Revoke payroll/team permission while visible; refresh within30s or take device offline | New API denied immediately; refreshed UI removes protected scope within stated bound, offline hides privileged detail; no claim to erase saved copies |
| PAGE-001 | P1 A/D | Same timestamp rows, multiple pages, new insertion while cursor scrolling | Stable timestamp+ID cursor without duplicate boundary row; documented snapshot/live semantics |
| PAGE-002 | P1 A | Negative/oversized limits/offset, forged cursor/filter mismatch, >366-day query | Validation/caps enforced; no arbitrary SQL; cursor bound to filters/actor |
| PAGE-003 | P1 W/N | Type quick searches and change team/date filter with out-of-order replies | 300ms debounce, stale response ignored; cursor reset; correct visible scope |
| API-001 | P0 A | All write endpoints anonymous/inactive/cross-org/forged actor ID | Denied before business effects; schema-consistent error code |
| API-002 | P1 A | Unknown fields, bad enum, nulls, long strings, invalid dates/UUIDs, injection text | Bounded validation; prepared SQL; no stack/secret leaks or server crash |
| API-003 | P0 A/D | Replay mutation, optimistic-version conflicts and timeout retries | Idempotency/version contract preserved; exactly one intended state mutation |
| API-004 | P0 A/D | Client spoofs authoritative receipt_at, delays new commit beyond30s or verifies fresh-at-receipt sample after processing latency | Client authoritative timestamp ignored/denied; trusted edge receipt used, new late commit rejected; committed replay remains available |
| PERF-001 | P1 O | 20 users burst punch/approval with production-like seeded history | No lost/duplicate data; p95 targets reported with cold/warm/network split |
| PERF-002 | P1 A/O | 10k attendance rows +50k audit rows, scoped report/page EXPLAIN | Bounded result/query time; inspect plans; no N+1/deep-offset scans in selected path |
| PERF-003 | P1 N/O | Scroll long lazy lists, big names, large-text, 60Hz devices | Frame timing recorded; bounded widget count/memory; no nested unbounded list |
| PERF-004 | P1 N/O | Dashboard first/warm navigation at RTT<=150ms | Warm shell<=300ms, p95 dashboard<=1.5s/list<=800ms target; report actual measurements |
| SEC-001 | P0 O/A | Extract release config/bundle/logs, inspect traffic and server errors | No service keys/passwords/signed URLs; TLS only; secure token storage; safe messages |
| SEC-002 | P0 A/D | SQL policy recursion/search_path attack, direct definer/internal RPC execution | Narrow execution grants; no owner escalation or arbitrary code/schema resolution |
| SEC-003 | P0 A | Stale JWT after demotion/password reset/deactivation | Authoritative current permission/credential gate rejects protected operations |
| UX-001 | P1 W/N | S01–S37 loading/empty/error/offline and large-text at360dp | Layout usable, messages distinct, no endless spinner/dead tap; screen semantics valid |
| UX-002 | P1 W/N | TalkBack/VoiceOver, keyboard traversal, contrast check, reduced motion | Logical focus, labels/status read, >=48dp targets and contrast thresholds |
| UX-003 | P2 N | Back gesture with unsaved form, phone rotation, background/resume | Prompt only when needed; input/filter preserved; no private stale preview |
| OPS-001 | P0 O | Restore operator DB backup + sampled object backup into isolated instance | Schema/roles/data/hash validation; record achieved RPO/RTO and missing capabilities |
| OPS-002 | P0 O | Release Android integrity + physical iOS App Attest/APNs/signing | Real release-channel evidence; no simulator-only claim or production bypass |
| OPS-003 | P1 O | Migration staging failure, incompatible app version, rollback drill | No destructive accidental data loss; backward compatibility or explicit maintenance plan |
| OPS-004 | P1 A/O | Storage70/85/95%/cap, quota rejection, provider pause/outage | Alerts/protective behavior correct, useful recovery; no automatic deletion or zero-cost guarantee |
| OPS-005 | P1 A/D/O | Stop Cron, accumulate outbox/expired sessions/staging jobs, restart and invoke two workers | Bounded leased batches, no double ledger effects, retries/health visible; next punch lazily rolls old session even before worker recovery |

## 10. Detailed race and recovery recipes

### REVIEW-003: edit versus first authorized view

1. Seed E1 request R version1 Submitted, no opened timestamp, known reservation.
2. Create two authenticated clients: E1 and assigned M1. Synchronize a barrier; run E1 edit expected_version1 and M1 open-review concurrently, repeat with each forced lock order.
3. If edit wins: version2 and revision history commit; M1 sees/locks version2. If review wins: E1 gets REQUEST_LOCKED, stored version1 unchanged. No response returns a version that wasn't locked for its decision.
4. Approve from M1 with received version; assert one decision and ledger reservation/debit reconciliation. Attempt approval with stale version and another team client; both fail.
5. Assert no private request history exposed in coworker directory/audit view. Cleanup isolated IDs.

### LEAVE-004 / REVIEW-006: accounting concurrency

1. Set available=2 half-day units. Submit two concurrent full-day requests on different dates; assert only one reservation succeeds, available>=0.
2. Set eligible reviewer to HR H, establish review lock, then race HR approval and Admin fallback rejection against the same request/version. Exactly one wins; expected ledger is either debit2 or reservation released, never both.
3. Repeat winner action with same key and then a fresh key; state remains final and no second debit/credit.
4. Inject transaction failure before outbox insert; everything rolls back including request state and ledger. Retry and assert one notification event.

### EXP-003 / DEL-003: cutoff and late changes

1. Freeze clock Oct3 2026; seed Sep30 shift with overnight OUT Oct1, Oct1 new shift, Sep payslip uploaded Oct2 and October payslip uploaded Oct2.
2. Create Sep report snapshot. Expected: Sep-started shift fully represented, October new shift excluded, Sep payslip included, October payslip excluded. Store generation-as-of separately.
3. For cleanup use a closed annual-period fixture (not this monthly report). Verify/save its archive, then add a file for that same old year; begin cleanup must return ARCHIVE_STALE with zero deletion.
4. Re-export r2, verify/save, begin cleanup. While period busy try late replacement; it must fail retryably. Inject failure after first object removal; resume and verify tombstones and undeleted unrelated objects.
5. Assert exact set equality between deleted version IDs and verified eligible manifest IDs. Attendance/leave/audit rows unchanged.

### FILE-009 / DEL-010: member window and restore

1. At Sep2026 seed 14 months with published/draft/superseded versions. Member list/endpoint only exposes published Oct2025–Sep2026 slots; unauthorized direct file fetch fails too.
2. Perform approved annual cleanup for a closed year whose files intersect window; member sees archived badge, no active download.
3. Assisted restore valid local hash as a new audited restored file version; only restore to original owner/period. Check window again; restored old months do not become visible merely because upload date is recent.

### EXP-016 / DEL-012: recovery after files are already gone

1. Complete a closed-year archive, verify/save it and delete some or all inventoried cloud files. Keep original ZIP available locally and server tombstones/hashes intact.
2. If cleanup is partial, Abandon with confirmation. Assert the persistent period gate is released, old workers cannot continue, remaining files exist and removed files remain tombstoned.
3. Add a late payslip revision for that year. A full re-export must ask for local originals, validate prior manifest/path/hash, and merge them with the new cloud version and refreshed reports. A missing local base cannot be reported as a complete archive.
4. Supply a corrupt/foreign ZIP then the genuine one. First fails safely, second yields the full exact inventory. The new acknowledgment authorizes only its newly inventoried remaining cloud versions; never delete unrelated paths.
5. Count expected files, hashes and report rows against the server manifest; do not treat a share-picker callback alone as verified saved bytes.

### PUNCH-004: uncertain network result

1. Use valid challenge/proof and operation K. Allow DB commit, drop network response.
2. Kill/reopen app, load saved non-secret operation identifier, query result as E1. Receive original server timestamp and IN state.
3. Replay K identical payload; no new row. Replay altered payload; conflict. E2 querying K receives no data. Verify outbox/event count remains1.

## 11. Automation structure and evidence

Suggested future repository layout (not included executable tests in this specification ZIP):

```text
test/unit/                 # duration, policies, state machines, cursor parsing
test/widget/               # screen states, roles, navigation, accessibility
integration_test/          # native Android/iOS primary and recovery journeys
supabase/tests/database/   # RLS, ledger constraints, concurrency, migration checks
supabase/functions/tests/  # real Auth/API/storage contracts and mocks only for providers
test/fixtures/             # artificial coordinates, valid PDFs and fake identities
```

Per CI change: formatter/analyzer, deterministic unit/widget, DB migrations + RLS tests, affected API flows. Nightly/staging: full API, concurrent state transitions, archive/cleanup recovery, native integration matrix. Release: physical Android and iPhone precise GPS/site pilot, attestation, notification and signed release distribution, full P0/P1 evidence. API assertions must cover response AND database side effects; only UI screenshots cannot verify security.

Example commands after project exists: `flutter analyze`, `flutter test`, `flutter test integration_test -d <device>`, `supabase start`, `supabase db reset`, `supabase test db`; function tests use the repository's selected Deno test tasks. Validate tool versions and actual commands in environment; never imply these ran merely because listed. DB reset is only for disposable local/staging targets. Never run destructive fixtures against production or real employee files.

Coverage mapping: S01–02 AUTH; S03–04 LOC/PUNCH/TIME; S05–13 LEAVE/REVIEW/CORR/HOL; S14–18 FILE/EMP/ROLE; S19–20 NOTIF/AUTH; S21–24 TIME/REVIEW/PAGE; S25–33 EMP/ROLE/FILE/TIME/HOL; S34–35 EXP/DEL; S36 AUDIT; S37 OPS/ROLE; optional S38 NOTIF/ROLE. Every screen also runs UX-001/002 and applicable API-001.

Release gates: all P0 and applicable P1 pass; zero known cross-user leakage, double accounting or unverified destructive cleanup; no production mock-attestation bypass; restore drill and actual device geofence evidence; measured performance versus targets; optional/deferred modules remain explicitly disabled. Record each failure, actual/expected, minimal reproduction, build/commit, device/OS, relevant request IDs and evidence path. Never attach real salaries/tokens in shared test reports.
