-- Links seeded payslip files: current version on the record, then the
-- published payslip row with its paid amount (separate statements so each
-- sees the previous one's rows). Safe to re-run.
update hrms.file_records r set current_version_id = v.id
from hrms.file_versions v, hrms.organizations o
where v.file_record_id = r.id and o.id = r.org_id and o.code = 'QATEST' and r.class = 'payslip'
  and r.current_version_id is null and v.object_key like '%/seed-%';

insert into hrms.payslips (org_id, employee_id, salary_month, file_record_id, current_file_version_id,
                           published_at, published_by, net_amount)
select r.org_id, r.owner_employee_id, r.period_start, r.id, r.current_version_id,
       least(r.period_start + interval '1 month 4 days', now()), v.uploaded_by,
       (coalesce(sp.monthly_salary, 25000) * 0.88 - 200)::numeric(12, 2)
from hrms.file_records r
join hrms.organizations o on o.id = r.org_id and o.code = 'QATEST'
join hrms.file_versions v on v.id = r.current_version_id and v.object_key like '%/seed-%'
left join hrms.salary_profiles sp on sp.employee_id = r.owner_employee_id
where r.class = 'payslip'
on conflict (employee_id, salary_month) do nothing;

select count(*) as payslips from hrms.payslips p join hrms.organizations o on o.id = p.org_id where o.code = 'QATEST';
