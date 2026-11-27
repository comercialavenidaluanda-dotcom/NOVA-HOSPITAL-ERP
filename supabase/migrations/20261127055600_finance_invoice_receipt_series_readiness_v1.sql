-- NOVA HOSPITAL ERP
-- Return AGT-ready series independently for FT and FR, without mixing document types.

CREATE OR REPLACE FUNCTION fiscal.finance_invoice_series_internal(p_organization_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_invoice_series jsonb;
  v_receipt_series jsonb;
  v_year integer := extract(year from (now() at time zone 'Africa/Luanda'))::integer;
  v_template_enabled boolean;
BEGIN
  IF auth.uid() IS NULL
     OR NOT core.is_org_member(p_organization_id)
     OR NOT core.has_org_permission(p_organization_id,'finance.invoice.issue') THEN
    RAISE EXCEPTION 'INVOICE_ISSUE_PERMISSION_REQUIRED' USING errcode='42501';
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'code',fs.series_code,'fiscal_year',fs.fiscal_year,'next_number',fs.next_number,
    'agt_communicated_at',fs.agt_communicated_at
  ) ORDER BY fs.series_code),'[]'::jsonb)
  INTO v_invoice_series
  FROM documents.fiscal_series fs
  WHERE fs.organization_id=p_organization_id AND fs.document_type='invoice'
    AND fs.fiscal_year=v_year AND fs.active AND fs.communicated_to_agt
    AND nullif(trim(fs.agt_communication_reference),'') IS NOT NULL
    AND fs.agt_communicated_at IS NOT NULL;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'code',fs.series_code,'fiscal_year',fs.fiscal_year,'next_number',fs.next_number,
    'agt_communicated_at',fs.agt_communicated_at
  ) ORDER BY fs.series_code),'[]'::jsonb)
  INTO v_receipt_series
  FROM documents.fiscal_series fs
  WHERE fs.organization_id=p_organization_id AND fs.document_type='invoice_receipt'
    AND fs.fiscal_year=v_year AND fs.active AND fs.communicated_to_agt
    AND nullif(trim(fs.agt_communication_reference),'') IS NOT NULL
    AND fs.agt_communicated_at IS NOT NULL;

  SELECT EXISTS(
    SELECT 1 FROM documents.document_templates t
    WHERE t.organization_id=p_organization_id
      AND t.document_code='FACTURA_RECIBO'
      AND t.category='financial' AND t.enabled
  ) INTO v_template_enabled;

  RETURN jsonb_build_object(
    'series',v_invoice_series,
    'invoice_receipt_series',v_receipt_series,
    'invoice_receipt_template_enabled',v_template_enabled,
    'year',v_year
  );
END;
$function$;

COMMENT ON FUNCTION fiscal.finance_invoice_series_internal(uuid)
 IS 'Returns current-year AGT-communicated invoice and invoice-receipt series plus FR template readiness.';
