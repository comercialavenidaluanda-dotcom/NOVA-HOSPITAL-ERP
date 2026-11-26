-- Align fiscal-series storage type with the finance invoice workflow.
-- The document template remains FACTURA; the fiscal_series.document_type enum
-- is constrained to the canonical lower-case value "invoice".
DO $migration$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef('public.api_finance_workspace(uuid)'::regprocedure)
    INTO v_definition;
  IF position('fs.document_type=''FACTURA''' in v_definition) > 0 THEN
    v_definition := replace(v_definition, 'fs.document_type=''FACTURA''', 'fs.document_type=''invoice''');
    EXECUTE v_definition;
  ELSIF position('fs.document_type=''invoice''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'Unexpected api_finance_workspace series predicate; migration stopped safely';
  END IF;

  SELECT pg_get_functiondef('fiscal.finance_invoice_series_internal(uuid)'::regprocedure)
    INTO v_definition;
  IF position('fs.document_type=''FACTURA''' in v_definition) > 0 THEN
    v_definition := replace(v_definition, 'fs.document_type=''FACTURA''', 'fs.document_type=''invoice''');
    EXECUTE v_definition;
  ELSIF position('fs.document_type=''invoice''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'Unexpected finance_invoice_series_internal series predicate; migration stopped safely';
  END IF;

  SELECT pg_get_functiondef('finance.finalize_invoice_internal(uuid,uuid,text)'::regprocedure)
    INTO v_definition;
  IF position('fs.document_type=''FACTURA''' in v_definition) > 0 THEN
    v_definition := replace(v_definition, 'fs.document_type=''FACTURA''', 'fs.document_type=''invoice''');
  ELSIF position('fs.document_type=''invoice''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'Unexpected finalize_invoice_internal series predicate; migration stopped safely';
  END IF;

  IF position('''fiscal_document_type'',''FACTURA''' in v_definition) > 0 THEN
    v_definition := replace(v_definition, '''fiscal_document_type'',''FACTURA''', '''fiscal_document_type'',''invoice''');
  ELSIF position('''fiscal_document_type'',''invoice''' in v_definition) = 0 THEN
    RAISE EXCEPTION 'Unexpected finalize_invoice_internal fiscal_document_type; migration stopped safely';
  END IF;
  EXECUTE v_definition;
END
$migration$;
