-- NOVA HOSPITAL ERP
-- Align database duplicate-name normalization with the catalogue UI.
-- Rebuilds only the supporting index; service data is unchanged.

DROP INDEX hospital.services_org_facility_department_name_active_uidx;

CREATE UNIQUE INDEX services_org_facility_department_name_active_uidx
ON hospital.services (
  organization_id,
  facility_id,
  COALESCE(department_id, '00000000-0000-0000-0000-000000000000'::uuid),
  lower(regexp_replace(trim(name), '[[:space:]]+', ' ', 'g'))
)
WHERE status <> 'archived';
