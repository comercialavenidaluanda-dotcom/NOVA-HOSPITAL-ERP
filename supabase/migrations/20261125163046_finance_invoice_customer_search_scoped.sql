-- Scoped patient lookup for invoice customers.
-- Finance users may search only the minimum patient identity fields needed
-- to associate an invoice; clinical directory access remains separately governed.

CREATE OR REPLACE FUNCTION public.api_finance_search_invoice_customer(
  p_organization_id uuid,
  p_query text,
  p_limit integer DEFAULT 20
)
RETURNS TABLE (
  patient_id uuid,
  patient_number text,
  full_name text,
  preferred_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, auth, core, patient
AS $function$
DECLARE
  v_query text := lower(btrim(coalesce(p_query, '')));
  v_digits text := regexp_replace(coalesce(p_query, ''), '[^0-9]', '', 'g');
BEGIN
  IF auth.uid() IS NULL
     OR p_organization_id IS NULL
     OR NOT core.is_org_member(p_organization_id)
     OR NOT core.has_org_permission(p_organization_id, 'finance.invoice.issue') THEN
    RAISE EXCEPTION 'FINANCE_INVOICE_CUSTOMER_SEARCH_FORBIDDEN'
      USING errcode = '42501';
  END IF;

  IF length(v_query) < 2 AND length(v_digits) < 4 THEN
    RAISE EXCEPTION 'SEARCH_QUERY_TOO_SHORT' USING errcode = '22023';
  END IF;

  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 20 THEN
    RAISE EXCEPTION 'INVALID_PAGE_SIZE' USING errcode = '22023';
  END IF;

  RETURN QUERY
  SELECT r.id, r.patient_number, r.full_name, r.preferred_name
  FROM patient.records AS r
  WHERE r.organization_id = p_organization_id
    AND r.record_status <> 'merged'
    AND (
      position(v_query IN lower(r.full_name)) > 0
      OR position(v_query IN lower(coalesce(r.preferred_name, ''))) > 0
      OR position(v_query IN lower(coalesce(r.patient_number, ''))) > 0
      OR (
        length(v_digits) >= 4
        AND position(v_digits IN regexp_replace(coalesce(r.contact_phone, ''), '[^0-9]', '', 'g')) > 0
      )
    )
  ORDER BY
    CASE
      WHEN lower(coalesce(r.patient_number, '')) = v_query THEN 0
      WHEN lower(r.full_name) = v_query THEN 1
      ELSE 2
    END,
    r.full_name,
    r.id
  LIMIT p_limit;
END;
$function$;

REVOKE ALL ON FUNCTION public.api_finance_search_invoice_customer(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_finance_search_invoice_customer(uuid, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.api_finance_search_invoice_customer(uuid, text, integer) TO authenticated;
