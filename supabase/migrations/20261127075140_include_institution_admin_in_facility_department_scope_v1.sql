
-- Allows institutional administrators to manage/read all departments in their own institution.
-- Other roles remain restricted to explicitly assigned facilities and departments.
CREATE OR REPLACE FUNCTION core.has_facility_department_access(
  p_organization_id uuid,
  p_facility_id uuid,
  p_department_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'core'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM core.organization_memberships m
    JOIN core.roles r
      ON r.id = m.role_id
     AND r.organization_id = m.organization_id
    WHERE m.organization_id = p_organization_id
      AND m.user_id = auth.uid()
      AND m.membership_status = 'active'
      AND (
        r.role_key IN ('group_owner', 'institution_admin')
        OR (
          EXISTS (
            SELECT 1
            FROM core.user_facilities uf
            WHERE uf.organization_id = p_organization_id
              AND uf.user_id = auth.uid()
              AND uf.facility_id = p_facility_id
          )
          AND EXISTS (
            SELECT 1
            FROM core.user_departments ud
            WHERE ud.organization_id = p_organization_id
              AND ud.user_id = auth.uid()
              AND ud.department_id = p_department_id
          )
        )
      )
  );
$function$;
