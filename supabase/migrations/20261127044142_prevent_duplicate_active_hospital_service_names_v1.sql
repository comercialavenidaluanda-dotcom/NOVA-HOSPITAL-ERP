-- NOVA HOSPITAL ERP
-- Prevent duplicate active service names within the same organization, facility and department.
-- Archived services may be recreated; existing service rows are not modified.

CREATE UNIQUE INDEX services_org_facility_department_name_active_uidx
ON hospital.services (
  organization_id,
  facility_id,
  COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::uuid),
  lower(regexp_replace(trim(name), '\s+', ' ', 'g'))
)
WHERE status <> 'archived';
