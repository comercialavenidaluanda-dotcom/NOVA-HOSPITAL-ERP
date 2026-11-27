-- NOVA HOSPITAL ERP
-- Harden FR idempotency and preserve payment details in the issued document snapshot.

DO $patch$
DECLARE
 v_def text;
 v_old text := 'IF p_payment_method NOT IN (''cash'',''card'',''transfer'',''reference'',''mobile_money'',''insurance'',''other'') THEN RAISE EXCEPTION ''INVALID_PAYMENT_METHOD''; END IF;';
 v_new text := 'IF p_payment_method NOT IN (''cash'',''card'',''transfer'',''reference'',''mobile_money'',''insurance'',''other'') THEN RAISE EXCEPTION ''INVALID_PAYMENT_METHOD''; END IF; IF nullif(trim(p_idempotency_key),'''') IS NULL THEN RAISE EXCEPTION ''PAYMENT_IDEMPOTENCY_KEY_REQUIRED''; END IF; IF EXISTS(SELECT 1 FROM finance.payments p WHERE p.organization_id=p_organization_id AND p.idempotency_key=p_idempotency_key) THEN RAISE EXCEPTION ''PAYMENT_IDEMPOTENCY_KEY_ALREADY_USED''; END IF;';
 v_content_old text := E'''notes'',v_invoice.notes,\n    ''patient'',v_patient,';
 v_content_new text := E'''notes'',v_invoice.notes,\n    ''payment'',jsonb_build_object(''method'',p_payment_method,''amount'',v_grand_total,''reference'',p_reference,''paid_at'',now()),\n    ''patient'',v_patient,';
BEGIN
 v_def := pg_get_functiondef('finance.finalize_invoice_receipt_internal(uuid,uuid,text,uuid,text,text,text)'::regprocedure);
 IF position(v_old in v_def)=0 OR position(v_content_old in v_def)=0 THEN
   RAISE EXCEPTION 'FR_FINALIZER_PATCH_SOURCE_CHANGED';
 END IF;
 v_def := replace(v_def,v_old,v_new);
 v_def := replace(v_def,v_content_old,v_content_new);
 EXECUTE v_def;
END
$patch$;

REVOKE ALL ON FUNCTION finance.finalize_invoice_receipt_internal(uuid,uuid,text,uuid,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION finance.finalize_invoice_receipt_internal(uuid,uuid,text,uuid,text,text,text) TO authenticated;

COMMENT ON FUNCTION finance.finalize_invoice_receipt_internal(uuid,uuid,text,uuid,text,text,text)
 IS 'Factura-recibo: validação fiscal e pagamento integral atómicos; requer série AGT comunicada e idempotency key.';
