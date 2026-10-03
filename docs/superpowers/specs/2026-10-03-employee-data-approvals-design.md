# Employee Data Approval and Login Support Design

## Objective

Introduce one consistent maker-checker policy for employee information while preserving the dedicated attendance,
leave, credential, and archive controls. Add an Admin-configured HR support phone to the signed-out login screen as a
safe telephone link.

## Approval policy

The initiator's effective role determines the reviewer, even when the initiator edits another employee:

| Initiator | Allowed scope | Required approval |
| --- | --- | --- |
| Member | Own personal profile and bank details | Active HR or Admin |
| Manager | Own personal profile and bank details | Active HR or Admin |
| HR | Own personal/bank details and authorized employee/payroll records | Admin only |
| Admin | Authorized employee, payroll, and own personal/bank records | No approval; apply immediately and audit |

An initiator can never approve their own request. Admin can review any pending employee-data request. For a Member or
Manager request, routing prefers an active HR account and falls back to an active Admin. An HR-initiated request routes
only to an active Admin. Missing-reviewer requests remain submitted, alert Admins, and never apply automatically.

Role precedence is `admin`, then `hr`, then other roles. Therefore an employee holding both HR and Manager roles is
treated as HR, and an employee holding Admin plus another role is treated as Admin.

## Included data

### Employee self-service

- Personal email and phone.
- Address.
- Emergency-contact name and phone.
- Date of birth.
- Bank name, account holder, masked account number, IFSC, and bank-proof file.

### HR-managed employee data

- Full name, designation, department, business email, business phone, and join date.
- Effective-dated team, office, and shift assignments.
- Activation/deactivation remains a distinct security-sensitive action, but an HR initiation becomes an Admin approval
  request; Admin initiation remains immediate and retains last-Admin and employee-cap protections.

### Payroll-managed data

- Monthly salary revisions.
- Payslip publication and replacement. HR may upload a private draft, but publication/replacement requires Admin
  approval. Admin publication/replacement is immediate.

## Explicit exclusions

- Password changes, credential reset, role elevation, device registration, and session revocation retain their current
  security and reauthentication paths. Role elevation remains Admin-only and is never auto-approved.
- Leave, attendance corrections, bank-proof upload validation, announcements, policies, organization settings, office
  geofences/Wi-Fi, shifts, holidays, and archive cleanup retain their purpose-built workflows.
- Ordinary employee documents keep their existing owner/HR/Admin access rules; upload does not change an approved
  employee field by itself.
- Team/office/shift configuration is not the same as assigning an employee. Configuration remains direct for its
  authorized role; HR-originated employee assignments require Admin approval.

## Request model

Extend the existing request/revision/event framework instead of adding an unrelated approval engine. Add request kinds
for `profile_details`, `employee_details`, `employee_assignment`, `employee_status`, `salary_change`, and
`payslip_publish`; retain `bank_details`.

Every request has:

- An immutable revision containing the normalized proposed data and a reason where the change is consequential.
- A route snapshot containing initiator class, reviewer rule, target employee, and change category.
- The standard submitted, under-review, returned, resubmitted, rejected, approved, and withdrawn lifecycle where the
  operation safely supports it.
- Optimistic versions and lock-on-open so an approval always applies the reviewed revision.
- A single transactional apply function that rechecks current authorization, target version, referenced assignment or
  file IDs, uniqueness, date bounds, employee cap, and last-Admin protections immediately before applying.
- Notifications containing only category/status text, never personal values, salary amounts, bank fields, phone
  numbers, signed URLs, or document contents.

Sensitive personal values remain in the protected `hrms` schema and are returned only to the requester and eligible
reviewer. Audit metadata stores field names, target, request/revision, actor, decision, and reason—not personal values,
bank values, salary amounts, or file URLs. Bank account numbers continue to discard all but the last four digits before
persistence.

## Admin-direct changes

Admin changes apply immediately without manufacturing a self-approved request. The normal domain history remains
authoritative (salary revisions, assignment history, file revisions, status history), and an append-only audit event
records the Admin actor, target, changed field names, reason where required, and resulting version. Admin-direct bank
changes use the same validation and proof requirements as employee requests.

## User experience

### Requester

- Editing an approval-controlled record shows `Submit for verification`, not `Save`, unless the current actor is Admin.
- The approved value stays active while a request is pending.
- The screen shows pending category, submitted time, reviewer status, and request history.
- A returned request can be edited and resubmitted; rejected/withdrawn requests remain in history.
- Duplicate active requests for the same employee/category are rejected with a link to the pending request.

### Reviewer

- Approval cards identify the category and employee but do not reveal sensitive values in notifications or list rows.
- Opening the request shows an explicit approved-versus-proposed comparison, masked where appropriate.
- Approve, reject, and return require the existing lock/version rules. Reject/return and Admin override require a reason.
- HR never sees an approve action for an HR-initiated request. Direct/deep-linked attempts fail on the server.

### Admin

- Admin edit screens keep `Save`/`Publish`; confirmation copy states that the action applies immediately and is audited.
- Admin can reassign eligible Member/Manager requests, but an HR-initiated request can only be assigned to another
  active Admin who is not the requester.

## Dynamic HR support phone

Add `organizations.support_phone` as a separately validated, Admin-managed value rather than interpreting the existing
free-form `support_contact` field as a telephone number.

- Organization settings expose `HR support phone` with international-number guidance.
- A narrow signed-out endpoint accepts the configured organization code and returns only the display phone and a
  normalized `tel:` value. It returns no employee identity or private HR profile data and applies IP rate limiting.
- Login displays `Forgot your password? Contact HR: <number>` and makes only the number a telephone link.
- Missing or invalid configuration falls back to the non-clickable `Forgot your password? Contact HR to reset it.`
- Link-launch failure keeps the number visible and offers copy-to-clipboard; it never blocks sign-in.

## Concurrency and failure handling

- Applying an approved request and marking it approved occur in one transaction.
- A target-version mismatch produces `STALE_VERSION`; the reviewer must return the request or the requester must create
  a revision against the new approved value.
- Repeated submit/decision operations use idempotency keys and cannot create duplicate revisions, salary rows,
  assignments, file publications, notifications, or audits.
- Referenced drafts/proofs must still exist, belong to the target employee/request, and pass file validation at apply
  time.
- Deactivation invalidates credentials only after Admin approval; rejecting or returning has no access side effect.

## Migration and compatibility

- Existing approved values remain approved and unchanged.
- Existing active bank requests retain their route snapshot; new bank requests use the new initiator-based matrix.
- Existing HR/Admin direct employee/payroll actions remain readable in domain/audit history.
- No backfill creates fake approvals or changes existing actors.
- Mobile clients that predate these request kinds receive safe server errors rather than bypassing approval.

## Verification

Automated database tests cover every initiator/category combination, self-approval denial, HR-on-HR denial, Admin-direct
application, missing reviewer, lock/stale/idempotency behavior, sensitive audit/notification redaction, last-Admin and
employee-cap rechecks, and unchanged approved values before approval.

Flutter tests cover role-specific button copy, pending/history states, approved-versus-proposed views, masking, deep-link
denials, dynamic phone/fallback/copy behavior, and account-switch cache isolation.

Physical-phone QA executes at least one complete Member → HR approval, HR → Admin approval, and Admin-direct flow,
plus bank, profile, assignment, salary, and payslip variants using only synthetic QA accounts and files. Backend queries
are read-only corroboration for actor IDs, revisions, resulting values, and immutable history.

