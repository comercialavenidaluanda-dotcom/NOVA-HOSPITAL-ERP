-- Move controlled patient lookup behind a non-exposed SECURITY DEFINER function.
-- Public RPC is SECURITY INVOKER; internal function enforces membership and finance permission.

DO $migration$
DECLARE v_def text;
BEGIN
 v_def:=pg_get_functiondef('public.api_finance_search_invoice_customer(uuid,text,integer)'::regprocedure);
 IF position('SECURITY DEFINER' in v_def)=0
    OR position('auth.uid() IS NULL' in v_def)=0
    OR position('core.has_org_permission' in v_def)=0 THEN
   RAISE EXCEPTION 'CUSTOMER_SEARCH_SOURCE_SECURITY_CHECK_FAILED';
 END IF;
 v_def:=replace(v_def,
   'FUNCTION public.api_finance_search_invoice_customer(',
   'FUNCTION finance.search_invoice_customer_internal(');
 EXECUTE v_def;
END
$migration$;

REVOKE ALL ON FUNCTION finance.search_invoice_customer_internal(uuid,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION finance.search_invoice_customer_internal(uuid,text,integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.api_finance_search_invoice_customer(
 p_organization_id uuid,p_query text,p_limit integer DEFAULT 20
)
RETURNS TABLE(patient_id uuid,patient_number text,full_name text,preferred_name text)
LANGUAGE sql
SECURITY INVOKER
SET search_path TO ''
AS $function$
 SELECT * FROM finance.search_invoice_customer_internal($1,$2,$3);
$function$;

REVOKE ALL ON FUNCTION public.api_finance_search_invoice_customer(uuid,text,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.api_finance_search_invoice_customer(uuid,text,integer) TO authenticated;
