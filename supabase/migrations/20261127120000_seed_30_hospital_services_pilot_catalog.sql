-- NOVA Hospital ERP
-- Adds 30 starter hospital services to the existing pilot institution catalogue.
-- No prices or fiscal classifications are assumed. Entries remain inactive until
-- the institution confirms tariffs and an accountant validates the AGT treatment.
-- Idempotent: existing organization/service_code rows are not overwritten.

with service_seed(catalog_code, department_code, category, duration_minutes, requires_appointment) as (
  values
  ('INT_CAR','CEX','consultation',30,true),
  ('INT_MED','CEX','consultation',30,true),
  ('INT_NEU','CEX','consultation',30,true),
  ('INT_ORT','CEX','consultation',30,true),
  ('INT_PED','CEX','consultation',30,true),
  ('INT_GIN','CEX','consultation',30,true),
  ('BLO_ANE','BLO','surgery',60,false),
  ('BLO_CGE','BLO','surgery',120,false),
  ('BLO_NCR','BLO','surgery',180,false),
  ('BLO_ORT','BLO','surgery',120,false),
  ('BLO_PED','BLO','surgery',120,false),
  ('BLO_URO','BLO','surgery',90,false),
  ('DIA_APA','LAB','laboratory',60,false),
  ('DIA_ECG','IMG','imaging',20,false),
  ('DIA_ECO','IMG','imaging',30,false),
  ('DIA_END','IMG','imaging',45,false),
  ('DIA_HEM','LAB','laboratory',45,false),
  ('DIA_IMG','IMG','imaging',30,false),
  ('DIA_LAB','LAB','laboratory',45,false),
  ('DIA_TAC','IMG','imaging',45,false),
  ('URG_CIR','URG','emergency',60,false),
  ('URG_GER','URG','emergency',30,false),
  ('URG_OBS','URG','emergency',60,false),
  ('URG_PED','URG','emergency',30,false),
  ('URG_TRA','URG','emergency',60,false),
  ('URG_TRI','URG','emergency',15,false),
  ('MAT_NEO','MAT','maternity',60,false),
  ('MAT_MAT','MAT','maternity',60,false),
  ('MAT_REA','MAT','therapy',45,true),
  ('MAT_FIS','MAT','therapy',45,true)
)
insert into hospital.services (
  organization_id, facility_id, department_id, service_code, name, description,
  service_category, duration_minutes, price_amount, currency, requires_appointment,
  status, tax_type, tax_code, tax_percentage, tax_exemption_code,
  tax_exemption_reason, tax_legal_reference, tax_classification_status,
  catalog_reference_code
)
select
  o.id, f.id, d.id, 'CAT-' || s.catalog_code, r.name,
  coalesce(r.description, 'Serviço hospitalar. Preço e enquadramento fiscal carecem de validação institucional.'),
  s.category, s.duration_minutes, null, 'AOA', s.requires_appointment,
  'inactive', null, null, null, null, null, null, 'pending', r.code
from service_seed s
join hospital.service_catalog_reference r
  on r.code=s.catalog_code and r.entry_type='service' and r.is_active
join core.organizations o on o.slug='nova-hospital-teste'
join core.facilities f
  on f.organization_id=o.id and f.facility_code='NOVA-TEST-001'
join core.departments d
  on d.organization_id=o.id and d.facility_id=f.id and d.department_code=s.department_code
on conflict (organization_id, service_code) do nothing;
