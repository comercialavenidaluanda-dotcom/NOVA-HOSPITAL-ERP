-- NOVA HOSPITAL ERP: correction document drafts (NC/ND).
-- Drafts require an issued original document and preserve original line tax snapshots.
ALTER TABLE finance.invoices
  ADD COLUMN IF NOT EXISTS original_invoice_id uuid,
  ADD COLUMN IF NOT EXISTS original_document_id uuid,
  ADD COLUMN IF NOT EXISTS correction_reason text;
ALTER TABLE finance.invoice_items
  ADD COLUMN IF NOT EXISTS source_invoice_item_id uuid;
DO $constraints$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='invoices_original_invoice_fk') THEN
  ALTER TABLE finance.invoices ADD CONSTRAINT invoices_original_invoice_fk
   FOREIGN KEY (organization_id,original_invoice_id)
   REFERENCES finance.invoices(organization_id,id) ON DELETE RESTRICT;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='invoices_original_document_fk') THEN
  ALTER TABLE finance.invoices ADD CONSTRAINT invoices_original_document_fk
   FOREIGN KEY (original_document_id) REFERENCES documents.issued_documents(id) ON DELETE RESTRICT;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='invoice_items_source_item_fk') THEN
  ALTER TABLE finance.invoice_items ADD CONSTRAINT invoice_items_source_item_fk
   FOREIGN KEY (source_invoice_item_id) REFERENCES finance.invoice_items(id) ON DELETE RESTRICT;
 END IF;
END
$constraints$;

CREATE OR REPLACE FUNCTION public.api_finance_create_correction_draft(p_organization_id uuid, p_original_invoice_id uuid, p_correction_type text, p_items jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
 v_original finance.invoices%rowtype;
 v_original_doc documents.issued_documents%rowtype;
 v_correction finance.invoices%rowtype;
 v_source finance.invoice_items%rowtype;
 v_item jsonb;
 v_qty numeric;
 v_unit numeric;
 v_discount numeric;
 v_subtotal numeric;
 v_tax numeric;
 v_total numeric;
 v_subtotal_sum numeric:=0;
 v_discount_sum numeric:=0;
 v_tax_sum numeric:=0;
 v_total_sum numeric:=0;
 v_existing_credit numeric:=0;
 v_created_items integer:=0; v_existing_credit_qty numeric:=0;
BEGIN
 IF auth.uid() IS NULL OR NOT core.is_org_member(p_organization_id)
    OR NOT core.has_org_permission(p_organization_id,'finance.invoice.issue') THEN
  RAISE EXCEPTION 'INVOICE_ISSUE_PERMISSION_REQUIRED' USING errcode='42501';
 END IF;

 IF p_correction_type NOT IN ('credit_note','debit_note') THEN
  RAISE EXCEPTION 'INVALID_CORRECTION_DOCUMENT_TYPE' USING errcode='22023';
 END IF;
 IF length(trim(coalesce(p_reason,'')))<10 THEN
  RAISE EXCEPTION 'CORRECTION_REASON_REQUIRED_MIN_10_CHARACTERS' USING errcode='22023';
 END IF;
 IF jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)=0 THEN
  RAISE EXCEPTION 'CORRECTION_ITEMS_REQUIRED' USING errcode='22023';
 END IF;
 IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e GROUP BY e.value->>'invoice_item_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'DUPLICATE_ORIGINAL_INVOICE_ITEM'; END IF;

 SELECT * INTO v_original
 FROM finance.invoices
 WHERE organization_id=p_organization_id AND id=p_original_invoice_id
   AND invoice_type IN ('invoice','invoice_receipt')
   AND status IN ('issued','partially_paid','paid')
   AND issued_document_id IS NOT NULL
 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORIGINAL_ISSUED_INVOICE_NOT_FOUND'; END IF;

 SELECT * INTO v_original_doc
 FROM documents.issued_documents
 WHERE id=v_original.issued_document_id
   AND organization_id=p_organization_id
   AND document_status='issued'
   AND document_code IN ('FACTURA','FACTURA_RECIBO');
 IF NOT FOUND THEN RAISE EXCEPTION 'ORIGINAL_FISCAL_DOCUMENT_NOT_FOUND'; END IF;

 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
 LOOP
  IF nullif(v_item->>'invoice_item_id','') IS NULL THEN
   RAISE EXCEPTION 'ORIGINAL_INVOICE_ITEM_ID_REQUIRED';
  END IF;
  v_qty:=nullif(v_item->>'quantity','')::numeric;
  IF v_qty IS NULL OR v_qty<=0 THEN RAISE EXCEPTION 'INVALID_CORRECTION_QUANTITY'; END IF;

  SELECT * INTO v_source
  FROM finance.invoice_items
  WHERE organization_id=p_organization_id
    AND invoice_id=v_original.id
    AND id=(v_item->>'invoice_item_id')::uuid
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORIGINAL_INVOICE_ITEM_NOT_FOUND'; END IF;
  IF p_correction_type='credit_note' THEN
   SELECT coalesce(sum(ci.quantity),0) INTO v_existing_credit_qty
   FROM finance.invoice_items ci JOIN finance.invoices cn ON cn.id=ci.invoice_id AND cn.organization_id=ci.organization_id
   WHERE cn.organization_id=p_organization_id AND cn.original_invoice_id=v_original.id
     AND cn.invoice_type='credit_note' AND cn.status IN ('draft','issued')
     AND ci.source_invoice_item_id=v_source.id;
   IF v_qty+v_existing_credit_qty>v_source.quantity THEN
    RAISE EXCEPTION 'CREDIT_NOTE_QUANTITY_EXCEEDS_REMAINING_ORIGINAL_LINE';
   END IF;
  END IF;

  v_unit:=v_source.unit_price;
  v_discount:=round((v_source.discount_amount/v_source.quantity)*v_qty,2);
  v_subtotal:=round(v_unit*v_qty,2);
  v_tax:=round((v_subtotal-v_discount)*v_source.tax_rate/100,2);
  v_total:=v_subtotal-v_discount+v_tax;

  v_subtotal_sum:=v_subtotal_sum+v_subtotal;
  v_discount_sum:=v_discount_sum+v_discount;
  v_tax_sum:=v_tax_sum+v_tax;
  v_total_sum:=v_total_sum+v_total;
 END LOOP;

 IF v_total_sum<=0 THEN RAISE EXCEPTION 'CORRECTION_TOTAL_MUST_BE_POSITIVE'; END IF;

 IF p_correction_type='credit_note' THEN
  SELECT coalesce(sum(total_amount),0) INTO v_existing_credit
  FROM finance.invoices
  WHERE organization_id=p_organization_id
    AND original_invoice_id=v_original.id
    AND invoice_type='credit_note'
    AND status='draft';
  IF v_total_sum+v_existing_credit>v_original.balance_due THEN
   RAISE EXCEPTION 'CREDIT_NOTE_EXCEEDS_OUTSTANDING_BALANCE';
  END IF;
 END IF;

 INSERT INTO finance.invoices(
  organization_id,patient_id,invoice_type,status,currency_code,
  customer_name,customer_tax_id,notes,created_by,
  subtotal,discount_total,tax_total,total_amount,amount_paid,balance_due,
  original_invoice_id,original_document_id,correction_reason
 )
 VALUES(
  p_organization_id,v_original.patient_id,p_correction_type,'draft',v_original.currency_code,
  v_original.customer_name,v_original.customer_tax_id,
  'Correcção do documento '||v_original_doc.document_number,
  auth.uid(),v_subtotal_sum,v_discount_sum,v_tax_sum,v_total_sum,0,0,
  v_original.id,v_original_doc.id,trim(p_reason)
 )
 RETURNING * INTO v_correction;

 FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
 LOOP
  v_qty:=nullif(v_item->>'quantity','')::numeric;
  SELECT * INTO v_source FROM finance.invoice_items
  WHERE organization_id=p_organization_id
    AND invoice_id=v_original.id
    AND id=(v_item->>'invoice_item_id')::uuid;

  v_unit:=v_source.unit_price;
  v_discount:=round((v_source.discount_amount/v_source.quantity)*v_qty,2);
  v_subtotal:=round(v_unit*v_qty,2);
  v_tax:=round((v_subtotal-v_discount)*v_source.tax_rate/100,2);
  v_total:=v_subtotal-v_discount+v_tax;

  INSERT INTO finance.invoice_items(
   organization_id,invoice_id,service_id,description,quantity,unit_price,
   discount_amount,tax_type,tax_code,tax_rate,tax_exemption_code,
   tax_exemption_reason,tax_legal_reference,tax_snapshot,line_subtotal,
   line_tax,line_total,service_snapshot,source_invoice_item_id
  )
  VALUES(
   p_organization_id,v_correction.id,v_source.service_id,
   v_source.description,v_qty,v_unit,v_discount,v_source.tax_type,
   v_source.tax_code,v_source.tax_rate,v_source.tax_exemption_code,
   v_source.tax_exemption_reason,v_source.tax_legal_reference,
   v_source.tax_snapshot,v_subtotal,v_tax,v_total,v_source.service_snapshot,v_source.id
  );
  v_created_items:=v_created_items+1;
 END LOOP;

 INSERT INTO audit.audit_events(
  organization_id,actor_user_id,event_type,action,resource_type,resource_id,purpose,metadata
 )
 VALUES(
  p_organization_id,auth.uid(),'finance_correction','draft_created','finance_invoice',
  v_correction.id,'Criar rascunho de nota de crédito/débito com referência ao documento original',
  jsonb_build_object('correction_type',p_correction_type,'original_invoice_id',v_original.id,
    'original_document_number',v_original_doc.document_number,'reason',trim(p_reason),
    'total',v_total_sum,'items',v_created_items)
 );

 RETURN jsonb_build_object(
  'invoice',to_jsonb(v_correction),
  'original_invoice',jsonb_build_object('id',v_original.id,'invoice_number',v_original.invoice_number),
  'original_document',jsonb_build_object('id',v_original_doc.id,'document_number',v_original_doc.document_number),
  'items',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY i.created_at),'[]'::jsonb)
    FROM finance.invoice_items i WHERE i.invoice_id=v_correction.id AND i.organization_id=p_organization_id),
  'fiscal_issue',false
 );
END;
$function$

REVOKE ALL ON FUNCTION public.api_finance_create_correction_draft(uuid,uuid,text,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_finance_create_correction_draft(uuid,uuid,text,jsonb,text) TO authenticated;
