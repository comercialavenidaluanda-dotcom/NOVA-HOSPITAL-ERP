-- NOVA HOSPITAL ERP: finalize credit/debit notes against the original issued document.
CREATE OR REPLACE FUNCTION finance.finalize_invoice_correction_internal(p_organization_id uuid, p_correction_invoice_id uuid, p_fiscal_series_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_correction finance.invoices%rowtype;
 v_original finance.invoices%rowtype;
 v_original_doc documents.issued_documents%rowtype;
 v_settings documents.organization_document_settings%rowtype;
 v_series documents.fiscal_series%rowtype;
 v_line finance.invoice_items%rowtype;
 v_source finance.invoice_items%rowtype;
 v_document jsonb;
 v_content jsonb;
 v_items jsonb;
 v_template_code text;
 v_doc_type text;
 v_year integer;
 v_subtotal numeric:=0;
 v_discount numeric:=0;
 v_tax numeric:=0;
 v_total numeric:=0;
 v_line_subtotal numeric;
 v_line_discount numeric;
 v_line_tax numeric;
 v_line_total numeric;
 v_existing_credit_qty numeric;
BEGIN
 IF auth.uid() IS NULL OR NOT core.is_org_member(p_organization_id)
    OR NOT core.has_org_permission(p_organization_id,'finance.invoice.issue') THEN
  RAISE EXCEPTION 'INVOICE_ISSUE_PERMISSION_REQUIRED' USING errcode='42501';
 END IF;

 SELECT * INTO v_correction FROM finance.invoices
 WHERE id=p_correction_invoice_id AND organization_id=p_organization_id
   AND status='draft' AND invoice_type IN ('credit_note','debit_note')
 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'CORRECTION_DRAFT_NOT_FOUND'; END IF;
 IF v_correction.original_invoice_id IS NULL OR v_correction.original_document_id IS NULL
    OR length(trim(coalesce(v_correction.correction_reason,'')))<10 THEN
  RAISE EXCEPTION 'CORRECTION_ORIGINAL_AND_REASON_REQUIRED';
 END IF;

 SELECT * INTO v_original FROM finance.invoices
 WHERE id=v_correction.original_invoice_id AND organization_id=p_organization_id
 FOR UPDATE;
 IF NOT FOUND OR v_original.issued_document_id IS DISTINCT FROM v_correction.original_document_id THEN
  RAISE EXCEPTION 'CORRECTION_ORIGINAL_DOCUMENT_MISMATCH';
 END IF;
 IF v_original.status NOT IN ('issued','partially_paid','paid') THEN
  RAISE EXCEPTION 'ORIGINAL_INVOICE_NOT_CORRECTABLE';
 END IF;

 SELECT * INTO v_original_doc FROM documents.issued_documents
 WHERE id=v_correction.original_document_id AND organization_id=p_organization_id
   AND document_status='issued';
 IF NOT FOUND THEN RAISE EXCEPTION 'ORIGINAL_FISCAL_DOCUMENT_NOT_FOUND'; END IF;

 v_template_code:=CASE WHEN v_correction.invoice_type='credit_note' THEN 'NOTA_CREDITO' ELSE 'NOTA_DEBITO' END;
 v_doc_type:=CASE WHEN v_correction.invoice_type='credit_note' THEN 'credit_note' ELSE 'debit_note' END;

 IF NOT EXISTS(SELECT 1 FROM documents.document_templates
   WHERE organization_id=p_organization_id AND document_code=v_template_code
     AND category='financial' AND enabled) THEN
  RAISE EXCEPTION 'CORRECTION_TEMPLATE_DISABLED';
 END IF;

 SELECT * INTO v_settings FROM documents.organization_document_settings
 WHERE organization_id=p_organization_id;
 IF NOT FOUND OR nullif(trim(v_settings.legal_name),'') IS NULL
    OR nullif(trim(v_settings.tax_identifier),'') IS NULL
    OR v_settings.tax_regime_code IS NULL
    OR v_settings.vat_registration_status IS NULL THEN
  RAISE EXCEPTION 'FISCAL_PROFILE_INCOMPLETE_CONFIGURE_ISSUER';
 END IF;
 IF v_settings.invoice_tax_enabled AND (
   v_settings.tax_regime_code NOT IN ('general','simplified')
   OR v_settings.vat_registration_status IS DISTINCT FROM 'registered'
   OR v_settings.tax_rate IS NULL OR v_settings.tax_rate<0 OR v_settings.tax_rate>100
 ) THEN RAISE EXCEPTION 'FISCAL_TAX_CONFIGURATION_INCOMPLETE'; END IF;
 IF v_settings.fiscal_electronic_invoicing AND (
   v_settings.agt_validation_status IS DISTINCT FROM 'validated'
   OR nullif(trim(v_settings.agt_validation_reference),'') IS NULL
   OR v_settings.agt_validation_date IS NULL
   OR nullif(trim(v_settings.fiscal_software_name),'') IS NULL
   OR nullif(trim(v_settings.fiscal_software_version),'') IS NULL
 ) THEN RAISE EXCEPTION 'AGT_FISCAL_SOFTWARE_VALIDATION_REQUIRED'; END IF;

 v_year:=extract(year from(now() at time zone coalesce(v_settings.timezone_name,'Africa/Luanda')))::integer;
 SELECT * INTO v_series FROM documents.fiscal_series
 WHERE organization_id=p_organization_id AND document_type=v_doc_type
   AND series_code=upper(trim(coalesce(p_fiscal_series_code,'')))
   AND fiscal_year=v_year AND active
 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_CORRECTION_FISCAL_SERIES_NOT_FOUND'; END IF;
 IF NOT v_series.communicated_to_agt
    OR nullif(trim(v_series.agt_communication_reference),'') IS NULL
    OR v_series.agt_communicated_at IS NULL THEN
  RAISE EXCEPTION 'CORRECTION_FISCAL_SERIES_AGT_COMMUNICATION_REQUIRED';
 END IF;

 FOR v_line IN SELECT * FROM finance.invoice_items
  WHERE organization_id=p_organization_id AND invoice_id=v_correction.id
  ORDER BY created_at,id FOR UPDATE
 LOOP
  SELECT * INTO v_source FROM finance.invoice_items
  WHERE id=v_line.source_invoice_item_id
    AND organization_id=p_organization_id AND invoice_id=v_original.id
  FOR UPDATE;
  IF NOT FOUND OR v_line.quantity IS NULL OR v_line.quantity<=0 THEN
   RAISE EXCEPTION 'CORRECTION_SOURCE_LINE_INVALID';
  END IF;
  IF v_correction.invoice_type='credit_note' THEN
   SELECT coalesce(sum(ci.quantity),0) INTO v_existing_credit_qty
   FROM finance.invoice_items ci JOIN finance.invoices cn
    ON cn.id=ci.invoice_id AND cn.organization_id=ci.organization_id
   WHERE cn.organization_id=p_organization_id AND cn.original_invoice_id=v_original.id
     AND cn.invoice_type='credit_note' AND cn.status IN ('draft','issued')
     AND cn.id<>v_correction.id AND ci.source_invoice_item_id=v_source.id;
   IF v_line.quantity+v_existing_credit_qty>v_source.quantity THEN
    RAISE EXCEPTION 'CREDIT_NOTE_QUANTITY_EXCEEDS_REMAINING_ORIGINAL_LINE';
   END IF;
  END IF;

  v_line_subtotal:=round(v_source.unit_price*v_line.quantity,2);
  v_line_discount:=round((v_source.discount_amount/v_source.quantity)*v_line.quantity,2);
  v_line_tax:=round((v_line_subtotal-v_line_discount)*v_source.tax_rate/100,2);
  v_line_total:=v_line_subtotal-v_line_discount+v_line_tax;
  UPDATE finance.invoice_items SET unit_price=v_source.unit_price,
   discount_amount=v_line_discount,tax_type=v_source.tax_type,tax_code=v_source.tax_code,
   tax_rate=v_source.tax_rate,tax_exemption_code=v_source.tax_exemption_code,
   tax_exemption_reason=v_source.tax_exemption_reason,tax_legal_reference=v_source.tax_legal_reference,
   tax_snapshot=v_source.tax_snapshot,service_snapshot=v_source.service_snapshot,
   line_subtotal=v_line_subtotal,line_tax=v_line_tax,line_total=v_line_total
  WHERE id=v_line.id AND organization_id=p_organization_id;
  v_subtotal:=v_subtotal+v_line_subtotal;
  v_discount:=v_discount+v_line_discount;
  v_tax:=v_tax+v_line_tax;
  v_total:=v_total+v_line_total;
 END LOOP;
 IF v_total<=0 THEN RAISE EXCEPTION 'CORRECTION_TOTAL_MUST_BE_POSITIVE'; END IF;
 IF v_correction.invoice_type='credit_note' AND v_total>v_original.balance_due THEN
  RAISE EXCEPTION 'CREDIT_NOTE_EXCEEDS_CURRENT_OUTSTANDING_BALANCE';
 END IF;

 UPDATE finance.invoices SET subtotal=v_subtotal,discount_total=v_discount,tax_total=v_tax,
  total_amount=v_total,balance_due=0,updated_at=now()
 WHERE id=v_correction.id AND organization_id=p_organization_id
 RETURNING * INTO v_correction;

 SELECT coalesce(jsonb_agg(jsonb_build_object(
  'description',i.description,'quantity',i.quantity,'unit_price',i.unit_price,
  'discount',i.discount_amount,'tax_type',i.tax_type,'tax_code',i.tax_code,
  'tax_rate',i.tax_rate,'tax_exemption_code',i.tax_exemption_code,
  'tax_exemption_reason',i.tax_exemption_reason,'tax_legal_reference',i.tax_legal_reference,
  'subtotal',i.line_subtotal,'tax',i.line_tax,'total',i.line_total,
  'original_invoice_item_id',i.source_invoice_item_id
 ) ORDER BY i.created_at,i.id),'[]'::jsonb) INTO v_items
 FROM finance.invoice_items i WHERE i.organization_id=p_organization_id AND i.invoice_id=v_correction.id;

 v_content:=jsonb_build_object(
  'fiscal_document_type',v_doc_type,'fiscal_series_code',upper(trim(p_fiscal_series_code)),
  'fiscal_year',v_year,'customer_name',v_correction.customer_name,
  'customer_nif',v_correction.customer_tax_id,'currency',v_correction.currency_code,
  'subtotal',v_correction.subtotal,'discount_total',v_correction.discount_total,
  'tax_total',v_correction.tax_total,'total_amount',v_correction.total_amount,
  'items',v_items,'reason',v_correction.correction_reason,
  'correction_of_document_id',v_original_doc.id,
  'original_document_number',v_original_doc.document_number,
  'original_finance_invoice_id',v_original.id,
  'calculation_source','original_invoice_line_tax_snapshot'
 );

 v_document:=documents.issue_document_internal(
  p_organization_id,v_template_code,v_correction.patient_id,
  'finance_invoice_correction',v_correction.id,v_content
 );

 UPDATE documents.issued_documents SET
  correction_of_document_id=v_original_doc.id,
  original_document_number=v_original_doc.document_number
 WHERE id=(v_document->>'id')::uuid AND organization_id=p_organization_id;

 UPDATE finance.invoices SET issued_document_id=(v_document->>'id')::uuid,
  invoice_number=v_document->>'document_number',status='issued',
  issue_date=(now() at time zone coalesce(v_settings.timezone_name,'Africa/Luanda'))::date,
  updated_at=now()
 WHERE id=v_correction.id AND organization_id=p_organization_id
 RETURNING * INTO v_correction;

 UPDATE finance.invoices SET
  balance_due=CASE WHEN v_correction.invoice_type='credit_note'
    THEN greatest(balance_due-v_total,0) ELSE balance_due+v_total END,
  status=CASE
    WHEN v_correction.invoice_type='credit_note' AND greatest(balance_due-v_total,0)=0 THEN 'paid'
    WHEN amount_paid>0 THEN 'partially_paid'
    ELSE 'issued' END,
  updated_at=now()
 WHERE id=v_original.id AND organization_id=p_organization_id
 RETURNING * INTO v_original;

 RETURN jsonb_build_object('invoice',to_jsonb(v_correction),
  'original_invoice',to_jsonb(v_original),'document',v_document,
  'calculation_source','original_invoice_line_tax_snapshot');
END;
$function$


REVOKE ALL ON FUNCTION finance.finalize_invoice_correction_internal(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION finance.finalize_invoice_correction_internal(uuid,uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.api_finance_finalize_invoice_correction(p_organization_id uuid, p_correction_invoice_id uuid, p_fiscal_series_code text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 SELECT finance.finalize_invoice_correction_internal($1,$2,$3);
$function$

REVOKE ALL ON FUNCTION public.api_finance_finalize_invoice_correction(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_finance_finalize_invoice_correction(uuid,uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION finance.guard_non_invoice_fiscal_issue()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
BEGIN
 IF NEW.status='issued' AND OLD.status IS DISTINCT FROM NEW.status
    AND NEW.invoice_type NOT IN ('invoice','invoice_receipt','credit_note','debit_note') THEN
  RAISE EXCEPTION 'NON_FISCAL_DOCUMENT_CANNOT_BE_ISSUED_AS_INVOICE';
 END IF;
 RETURN NEW;
END;
$function$

