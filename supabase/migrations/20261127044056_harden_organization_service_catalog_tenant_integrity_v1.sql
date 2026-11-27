-- NOVA HOSPITAL ERP
-- Harden organization service catalog tenant/facility/department integrity.
-- Additive and reversible: no existing catalog rows are modified or removed.

ALTER TABLE core.departments
  ADD CONSTRAINT departments_id_facility_organization_key
  UNIQUE (id, facility_id, organization_id);

ALTER TABLE hospital.organization_service_catalog
  ADD CONSTRAINT organization_service_catalog_facility_org_fkey
  FOREIGN KEY (facility_id, organization_id)
  REFERENCES core.facilities (id, organization_id)
  ON DELETE CASCADE
  NOT VALID;

ALTER TABLE hospital.organization_service_catalog
  ADD CONSTRAINT organization_service_catalog_department_facility_org_fkey
  FOREIGN KEY (department_id, facility_id, organization_id)
  REFERENCES core.departments (id, facility_id, organization_id)
  NOT VALID;

ALTER TABLE hospital.organization_service_catalog
  VALIDATE CONSTRAINT organization_service_catalog_facility_org_fkey;

ALTER TABLE hospital.organization_service_catalog
  VALIDATE CONSTRAINT organization_service_catalog_department_facility_org_fkey;

DROP POLICY IF EXISTS organization_service_catalog_insert
  ON hospital.organization_service_catalog;

CREATE POLICY organization_service_catalog_insert
  ON hospital.organization_service_catalog
  FOR INSERT
  TO authenticated
  WITH CHECK (
    core.has_org_permission(organization_id, 'services.manage')
    AND EXISTS (
      SELECT 1
      FROM core.facilities AS f
      WHERE f.id = organization_service_catalog.facility_id
        AND f.organization_id = organization_service_catalog.organization_id
    )
    AND (
      organization_service_catalog.department_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM core.departments AS d
        WHERE d.id = organization_service_catalog.department_id
          AND d.organization_id = organization_service_catalog.organization_id
          AND d.facility_id = organization_service_catalog.facility_id
      )
    )
  );

DROP POLICY IF EXISTS organization_service_catalog_update
  ON hospital.organization_service_catalog;

CREATE POLICY organization_service_catalog_update
  ON hospital.organization_service_catalog
  FOR UPDATE
  TO authenticated
  USING (
    core.has_org_permission(organization_id, 'services.manage')
  )
  WITH CHECK (
    core.has_org_permission(organization_id, 'services.manage')
    AND EXISTS (
      SELECT 1
      FROM core.facilities AS f
      WHERE f.id = organization_service_catalog.facility_id
        AND f.organization_id = organization_service_catalog.organization_id
    )
    AND (
      organization_service_catalog.department_id IS NULL
      OR EXISTS (
        SELECT 1
        FROM core.departments AS d
        WHERE d.id = organization_service_catalog.department_id
          AND d.organization_id = organization_service_catalog.organization_id
          AND d.facility_id = organization_service_catalog.facility_id
      )
    )
  );
