-- NOVA HOSPITAL ERP
-- Atomic invoice-receipt support (FR). Existing invoice records are preserved.

ALTER TABLE finance.invoices DROP CONSTRAINT IF EXISTS invoices_invoice_type_check;
ALTER TABLE finance.invoices ADD CONSTRAINT invoices_invoice_type_check
CHECK (invoice_type = ANY (ARRAY['invoice','invoice_receipt','proforma','quote','credit_note','debit_note']::text[]));

CREATE OR REPLACE FUNCTION finance.guard_non_invoice_fiscal_issue()
RETURNS trigger LANGUAGE plpgsql SET search_path TO ''
AS $function$
BEGIN
 IF NEW.status='issued' AND OLD.status IS DISTINCT FROM NEW.status
    AND NEW.invoice_type NOT IN ('invoice','invoice_receipt') THEN
   RAISE EXCEPTION 'NON_FISCAL_DOCUMENT_CANNOT_BE_ISSUED_AS_INVOICE';
 END IF;
 RETURN NEW;
END;
$function$;

DO $migration$
DECLARE
 v_def text;
 v_old text := 'IF v_type NOT IN (''invoice'',''proforma'',''quote'') THEN';
 v_new text := 'IF v_type NOT IN (''invoice'',''invoice_receipt'',''proforma'',''quote'') THEN';
 v_balance_old text := 'CASE WHEN v_type=''invoice'' THEN (v_quote->>''total'')::numeric ELSE 0 END';
 v_balance_new text := 'CASE WHEN v_type IN (''invoice'',''invoice_receipt'') THEN (v_quote->>''total'')::numeric ELSE 0 END';
BEGIN
 v_def := pg_get_functiondef('public.api_finance_create_invoice(uuid,uuid,jsonb,text,text,date,text,text)'::regprocedure);
 IF position(v_old in v_def)=0 OR position(v_balance_old in v_def)=0 THEN
   RAISE EXCEPTION 'FR_DRAFT_API_SOURCE_CHANGED_ABORTING_MIGRATION';
 END IF;
 EXECUTE replace(replace(v_def,v_old,v_new),v_balance_old,v_balance_new);
END
$migration$;

DO $migration$
DECLARE
 v_def text;
 v_old_sig text := 'FUNCTION finance.finalize_invoice_internal(p_organization_id uuid, p_invoice_id uuid, p_fiscal_series_code text)';
 v_new_sig text := 'FUNCTION finance.finalize_invoice_receipt_internal(p_organization_id uuid, p_invoice_id uuid, p_fiscal_series_code text, p_cash_session_id uuid, p_payment_method text, p_reference text, p_idempotency_key text)';
 v_auth_old text := 'OR NOT core.has_org_permission(p_organization_id,''finance.invoice.issue'') THEN';
 v_auth_new text := 'OR NOT core.has_org_permission(p_organization_id,''finance.invoice.issue'') OR NOT core.has_org_permission(p_organization_id,''finance.cash.receive'') THEN';
 v_declare_old text := 'v_grand_total numeric := 0;';
 v_declare_new text := E'v_grand_total numeric := 0;\n  v_payment jsonb;';
 v_draft_old text := E'SELECT * INTO v_invoice\n  FROM finance.invoices';
 v_draft_new text := E'SELECT to_jsonb(d) INTO v_document FROM documents.issued_documents d\n  WHERE d.organization_id=p_organization_id AND d.document_code=''FACTURA_RECIBO''\n    AND d.related_resource_type=''finance_invoice'' AND d.related_resource_id=p_invoice_id\n    AND d.document_status=''issued'';\n  IF FOUND THEN RETURN jsonb_build_object(''duplicate'',true,''document'',v_document); END IF;\n\n  SELECT * INTO v_invoice\n  FROM finance.invoices';
 v_found_old text := E'IF NOT FOUND THEN\n    RAISE EXCEPTION ''DRAFT_INVOICE_NOT_FOUND'';\n  END IF;';
 v_found_new text := E'IF NOT FOUND THEN\n    RAISE EXCEPTION ''DRAFT_INVOICE_NOT_FOUND'';\n  END IF;\n  IF v_invoice.invoice_type IS DISTINCT FROM ''invoice_receipt'' THEN RAISE EXCEPTION ''INVOICE_RECEIPT_DRAFT_REQUIRED''; END IF;\n  IF v_invoice.amount_paid<>0 OR v_invoice.total_amount<=0 THEN RAISE EXCEPTION ''INVOICE_RECEIPT_REQUIRES_UNPAID_POSITIVE_TOTAL''; END IF;\n  IF p_payment_method NOT IN (''cash'',''card'',''transfer'',''reference'',''mobile_money'',''insurance'',''other'') THEN RAISE EXCEPTION ''INVALID_PAYMENT_METHOD''; END IF;';
 v_return_old text := E'RETURN jsonb_build_object(\n    ''invoice'',to_jsonb(v_invoice),';
 v_return_new text := E'v_payment:=finance.record_payment_internal(p_organization_id,p_cash_session_id,v_invoice.id,v_invoice.patient_id,v_invoice.total_amount,p_payment_method,p_reference,''Pagamento integral da factura-recibo'',p_idempotency_key);\n\n  RETURN jsonb_build_object(\n    ''invoice'',(SELECT to_jsonb(i) FROM finance.invoices i WHERE i.id=v_invoice.id AND i.organization_id=p_organization_id),\n    ''payment'',v_payment,';
BEGIN
 v_def := pg_get_functiondef('finance.finalize_invoice_internal(uuid,uuid,text)'::regprocedure);
 IF position(v_old_sig in v_def)=0 OR position(v_auth_old in v_def)=0 OR position(v_declare_old in v_def)=0
    OR position(v_draft_old in v_def)=0 OR position(v_found_old in v_def)=0 OR position(v_return_old in v_def)=0
 THEN RAISE EXCEPTION 'FR_FINALIZER_SOURCE_CHANGED_ABORTING_MIGRATION'; END IF;
 v_def := replace(v_def,v_old_sig,v_new_sig);
 v_def := replace(v_def,v_auth_old,v_auth_new);
 v_def := replace(v_def,v_declare_old,v_declare_new);
 v_def := replace(v_def,v_draft_old,v_draft_new);
 v_def := replace(v_def,v_found_old,v_found_new);
 v_def := replace(v_def,'document_code=''FACTURA''','document_code=''FACTURA_RECIBO''');
 v_def := replace(v_def,'document_type=''invoice''','document_type=''invoice_receipt''');
 v_def := replace(v_def,'''fiscal_document_type'',''invoice''','''fiscal_document_type'',''invoice_receipt''');
 v_def := replace(v_def,'''FACTURA'',','''FACTURA_RECIBO'',');
 v_def := replace(v_def,v_return_old,v_return_new);
 EXECUTE v_def;
END
$migration$;

CREATE OR REPLACE FUNCTION public.api_finance_finalize_invoice_receipt(
 p_organization_id uuid,p_invoice_id uuid,p_fiscal_series_code text,
 p_cash_session_id uuid,p_payment_method text,p_reference text DEFAULT NULL,
 p_idempotency_key text DEFAULT NULL
) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path TO ''
AS $function$
 SELECT finance.finalize_invoice_receipt_internal($1,$2,$3,$4,$5,$6,$7);
$function$;

REVOKE ALL ON FUNCTION public.api_finance_finalize_invoice_receipt(uuid,uuid,text,uuid,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_finance_finalize_invoice_receipt(uuid,uuid,text,uuid,text,text,text) TO authenticated;
