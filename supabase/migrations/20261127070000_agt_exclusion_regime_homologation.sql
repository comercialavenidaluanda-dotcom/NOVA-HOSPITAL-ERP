-- NOVA HOSPITAL ERP
-- Regime de Exclusão do IVA: perfil completo sem liquidar IVA.
-- Esta migração não activa produção, certificação, credenciais nem séries fiscais.

CREATE OR REPLACE FUNCTION fiscal.save_agt_settings_internal(p_organization_id uuid, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'core', 'fiscal'
AS $function$
DECLARE
  v_environment text := 'homologation';
  v_status text;
  v_regime text := upper(trim(coalesce(p_data->>'tax_regime','')));
  v_regime_code text;
  v_vat_status text := lower(trim(coalesce(p_data->>'vat_registration_status','')));
  v_invoice_tax_enabled boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF NOT core.has_org_permission(p_organization_id,'fiscal.manage') THEN
    RAISE EXCEPTION 'FISCAL_MANAGE_DENIED';
  END IF;

  v_regime_code := CASE v_regime
    WHEN 'GERAL' THEN 'general'
    WHEN 'SIMPLIFICADO' THEN 'simplified'
    WHEN 'EXCLUSAO' THEN 'exclusion'
    ELSE NULL
  END;

  -- No Regime de Exclusão não há liquidação de IVA; normalizar o estado
  -- de registo para permitir que o perfil fique completo sem inventar taxa.
  IF v_regime_code='exclusion' AND v_vat_status='' THEN
    v_vat_status := 'not_registered';
  END IF;

  IF v_regime <> '' AND v_regime_code IS NULL THEN
    RAISE EXCEPTION 'INVALID_ANGOLA_VAT_REGIME' USING errcode='22023';
  END IF;
  IF v_vat_status <> '' AND v_vat_status NOT IN ('registered','not_registered','exempt') THEN
    RAISE EXCEPTION 'INVALID_VAT_REGISTRATION_STATUS' USING errcode='22023';
  END IF;

  v_invoice_tax_enabled := (v_regime_code='general' AND v_vat_status='registered');

  INSERT INTO fiscal.agt_settings(
    organization_id, environment, taxpayer_nif, legal_name, tax_regime,
    vat_registration_status, taxpayer_adhesion_date, software_product_id,
    software_version, schema_version, agt_api_base_url, status, notes, updated_by
  )
  VALUES(
    p_organization_id, v_environment,
    nullif(trim(p_data->>'taxpayer_nif'),''),
    nullif(trim(p_data->>'legal_name'),''),
    nullif(v_regime,''),
    nullif(v_vat_status,''),
    nullif(p_data->>'taxpayer_adhesion_date','')::date,
    'NOVA HOSPITAL ERP',
    coalesce((select product_version from fiscal.agt_producer_runtime where singleton),'1.0.0'),
    coalesce((select schema_version from fiscal.agt_producer_runtime where singleton),'2.0'),
    'https://sifphml.minfin.gov.ao',
    'pending_certification',
    nullif(trim(p_data->>'notes'),''),
    auth.uid()
  )
  ON CONFLICT(organization_id) DO UPDATE SET
    taxpayer_nif=excluded.taxpayer_nif,
    legal_name=excluded.legal_name,
    tax_regime=excluded.tax_regime,
    vat_registration_status=excluded.vat_registration_status,
    taxpayer_adhesion_date=excluded.taxpayer_adhesion_date,
    notes=excluded.notes,
    updated_by=auth.uid(),
    updated_at=now()
  RETURNING status INTO v_status;

  -- Keep the AGT taxpayer regime and the invoice calculation profile in sync.
  -- The simplified and exclusion regimes do not add VAT to invoice lines.
  UPDATE documents.organization_document_settings
  SET legal_name=coalesce(nullif(trim(p_data->>'legal_name'),''),legal_name),
      tax_identifier=coalesce(nullif(trim(p_data->>'taxpayer_nif'),''),tax_identifier),
      tax_regime=nullif(v_regime,''),
      tax_regime_code=v_regime_code,
      vat_registration_status=nullif(v_vat_status,''),
      invoice_tax_enabled=v_invoice_tax_enabled,
      tax_rate=CASE WHEN v_invoice_tax_enabled THEN 14 ELSE NULL END,
      updated_by=auth.uid(),
      updated_at=now()
  WHERE organization_id=p_organization_id;

  RETURN jsonb_build_object(
    'saved',true,
    'status',coalesce(v_status,'pending_certification'),
    'environment',v_environment,
    'producer_configuration','server_managed',
    'credentials_required',true,
    'private_keys_stored',false,
    'invoice_tax_profile_synced',FOUND,
    'tax_regime_code',v_regime_code,
    'invoice_tax_enabled',v_invoice_tax_enabled
  );
END
$function$
;

CREATE OR REPLACE FUNCTION finance.calculate_invoice_quote_internal(p_organization_id uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_item jsonb;
  v_service hospital.services%rowtype;
  v_fiscal documents.organization_document_settings%rowtype;
  v_service_id uuid;
  v_description text;
  v_quantity numeric;
  v_price numeric;
  v_discount numeric;
  v_rate numeric;
  v_code text;
  v_exemption text;
  v_reason text;
  v_legal text;
  v_line_subtotal numeric;
  v_line_tax numeric;
  v_line_total numeric;
  v_subtotal numeric := 0;
  v_discount_total numeric := 0;
  v_tax_total numeric := 0;
  v_total numeric := 0;
  v_lines jsonb := '[]'::jsonb;
  v_tax_summary jsonb;
  v_tax_enabled boolean := false;
  v_tax_profile_ready boolean := false;
BEGIN
  IF auth.uid() IS NULL
     OR NOT core.is_org_member(p_organization_id)
     OR NOT core.has_org_permission(p_organization_id,'finance.invoice.issue') THEN
    RAISE EXCEPTION 'INVOICE_ISSUE_PERMISSION_REQUIRED' USING errcode='42501';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
     OR jsonb_array_length(p_items)=0 OR jsonb_array_length(p_items)>100 THEN
    RAISE EXCEPTION 'INVOICE_ITEMS_COUNT_INVALID' USING errcode='22023';
  END IF;

  SELECT * INTO v_fiscal
  FROM documents.organization_document_settings
  WHERE organization_id=p_organization_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DOCUMENT_SETTINGS_NOT_CONFIGURED';
  END IF;

  v_tax_enabled := coalesce(v_fiscal.invoice_tax_enabled,false);
  v_tax_profile_ready := coalesce(v_fiscal.tax_regime_code IN ('general','simplified','exclusion','not_applicable') AND v_fiscal.vat_registration_status IN ('registered','not_registered','exempt'),false);

  -- Draft quotation may calculate net amounts while tax is disabled.
  -- Fiscal issue remains separately blocked until issuer profile and series are verified.
  IF v_tax_enabled AND NOT v_tax_profile_ready THEN
    RAISE EXCEPTION 'FISCAL_TAX_PROFILE_INCOMPLETE';
  END IF;

  IF v_tax_enabled AND (
    v_fiscal.tax_regime_code NOT IN ('general','simplified')
    OR v_fiscal.vat_registration_status IS DISTINCT FROM 'registered'
    OR v_fiscal.tax_rate IS NULL OR v_fiscal.tax_rate<0 OR v_fiscal.tax_rate>100
  ) THEN
    RAISE EXCEPTION 'FISCAL_TAX_CONFIGURATION_INCOMPLETE';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    v_quantity := coalesce(nullif(v_item->>'quantity','')::numeric,1);
    v_discount := coalesce(nullif(v_item->>'discount_amount','')::numeric,0);
    v_service_id := nullif(v_item->>'service_id','')::uuid;
    v_exemption := NULL; v_reason := NULL; v_legal := NULL; v_code := NULL;

    IF v_service_id IS NOT NULL THEN
      SELECT * INTO v_service FROM hospital.services
      WHERE id=v_service_id AND organization_id=p_organization_id AND status='active';
      IF NOT FOUND THEN RAISE EXCEPTION 'SERVICE_NOT_FOUND_OR_INACTIVE'; END IF;
      IF v_service.price_amount IS NULL OR v_service.price_amount<0 THEN
        RAISE EXCEPTION 'SERVICE_PRICE_NOT_CONFIGURED';
      END IF;

      IF v_tax_enabled AND (
        v_service.tax_classification_status IS DISTINCT FROM 'configured'
        OR v_service.tax_type IS DISTINCT FROM 'IVA'
        OR v_service.tax_code IS NULL OR v_service.tax_percentage IS NULL
      ) THEN
        RAISE EXCEPTION 'SERVICE_TAX_CLASSIFICATION_REQUIRED: %',v_service.name;
      END IF;

      v_price := v_service.price_amount;
      v_description := v_service.name;

      IF v_tax_enabled THEN
        v_code := v_service.tax_code;
        v_rate := v_service.tax_percentage;
        v_exemption := v_service.tax_exemption_code;
        v_reason := v_service.tax_exemption_reason;
        v_legal := v_service.tax_legal_reference;

        IF v_code='ISE' AND (v_rate<>0 OR v_exemption IS NULL OR v_reason IS NULL OR v_legal IS NULL) THEN
          RAISE EXCEPTION 'VAT_EXEMPTION_DATA_INCOMPLETE: %',v_service.name;
        ELSIF v_code='OUT' AND v_rate<>0 THEN
          RAISE EXCEPTION 'OUT_OF_SCOPE_TAX_RATE_MUST_BE_ZERO';
        ELSIF v_code NOT IN ('NOR','INT','RED','ISE','OUT') THEN
          RAISE EXCEPTION 'INVALID_AGT_TAX_CODE';
        END IF;
      ELSE
        v_rate := 0;
        -- Do not invent an AGT tax classification when tax calculation is disabled.
        v_code := NULL;
      END IF;
    ELSE
      v_description := nullif(trim(v_item->>'description'),'');
      IF v_description IS NULL THEN RAISE EXCEPTION 'INVOICE_ITEM_DESCRIPTION_REQUIRED'; END IF;
      v_price := nullif(v_item->>'unit_price','')::numeric;
      IF v_price IS NULL THEN RAISE EXCEPTION 'INVALID_INVOICE_ITEM_VALUES'; END IF;

      IF v_tax_enabled THEN
        v_rate := v_fiscal.tax_rate;
        v_code := CASE WHEN v_rate=14 THEN 'NOR' WHEN v_rate=7 THEN 'INT' WHEN v_rate=5 THEN 'RED' ELSE NULL END;
        IF v_code IS NULL THEN RAISE EXCEPTION 'MANUAL_ITEM_TAX_RATE_REQUIRES_SERVICE_CLASSIFICATION'; END IF;
      ELSE
        v_rate := 0;
        v_code := NULL;
      END IF;
    END IF;

    IF v_quantity<=0 OR v_quantity>100000 OR v_price<0 OR v_discount<0
       OR v_discount>round(v_quantity*v_price,2) THEN
      RAISE EXCEPTION 'INVALID_INVOICE_ITEM_VALUES' USING errcode='22023';
    END IF;

    v_line_subtotal := round(v_quantity*v_price,2);
    v_line_tax := round((v_line_subtotal-v_discount)*v_rate/100,2);
    v_line_total := v_line_subtotal-v_discount+v_line_tax;
    v_subtotal := v_subtotal+v_line_subtotal;
    v_discount_total := v_discount_total+v_discount;
    v_tax_total := v_tax_total+v_line_tax;
    v_total := v_total+v_line_total;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'description',v_description,'service_id',v_service_id,'quantity',v_quantity,
      'unit_price',v_price,'discount_amount',v_discount,'tax_type',CASE WHEN v_tax_enabled THEN 'IVA' ELSE NULL END,
      'tax_code',v_code,'tax_rate',v_rate,'tax_exemption_code',v_exemption,
      'tax_exemption_reason',v_reason,'tax_legal_reference',v_legal,
      'subtotal',v_line_subtotal,'discount_amount',v_discount,'taxable_base',v_line_subtotal-v_discount,'tax',v_line_tax,'total',v_line_total,
      'tax_source',CASE WHEN v_tax_enabled AND v_service_id IS NOT NULL THEN 'hospital.services'
                        WHEN v_tax_enabled THEN 'institution_document_settings'
                        ELSE CASE WHEN v_fiscal.tax_regime_code='exclusion' AND v_tax_profile_ready
                          THEN 'fiscal_exclusion_regime'
                          ELSE 'tax_not_applied_pending_fiscal_profile' END END,
      'tax_calculation_status',CASE WHEN v_tax_enabled THEN 'calculated'
            WHEN v_fiscal.tax_regime_code='exclusion' AND v_tax_profile_ready THEN 'not_applicable'
            ELSE 'not_applied' END
    ));
  END LOOP;

  IF v_tax_enabled THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'tax_code',g.tax_code,'tax_rate',g.tax_rate,
        'taxable_base',g.taxable_base,'tax_amount',g.tax_amount
      ) ORDER BY g.tax_code,g.tax_rate),'[]'::jsonb)
    INTO v_tax_summary
    FROM (
      SELECT x->>'tax_code' AS tax_code,
        (x->>'tax_rate')::numeric AS tax_rate,
        sum((x->>'taxable_base')::numeric) AS taxable_base,
        sum((x->>'tax')::numeric) AS tax_amount
      FROM jsonb_array_elements(v_lines) x
      GROUP BY x->>'tax_code',(x->>'tax_rate')::numeric
    ) g;
  ELSE
    v_tax_summary := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'currency','AOA','subtotal',round(v_subtotal,2),'discount_total',round(v_discount_total,2),
    'tax_total',round(v_tax_total,2),'total',round(v_total,2),'lines',v_lines,
    'tax_summary',v_tax_summary,
    'tax_calculation_status',CASE
      WHEN v_tax_enabled THEN 'calculated'
      WHEN v_fiscal.tax_regime_code='exclusion' AND v_tax_profile_ready THEN 'not_applicable_exclusion_regime'
      ELSE 'not_applied_fiscal_profile_pending' END,
    'tax_profile_ready',v_tax_profile_ready,
    'calculation_source','server','is_quote',true,'fiscal_issue',false
  );
END;
$function$
;


-- Seed a non-certified producer runtime profile for homologation only.
-- Official credentials, certificates and private keys remain unset.
insert into fiscal.agt_producer_runtime(
  singleton, product_id, product_version, schema_version, environment,
  certification_status, producer_credentials_configured, producer_signing_key_configured
) values (
  true, 'NOVA HOSPITAL ERP', '1.0.0', '2.0', 'homologation',
  'not_registered', false, false
)
on conflict (singleton) do nothing;

 
-- Prevent the generic document center from issuing financial documents.
-- Invoices, receipts, credit notes and debit notes must pass through the
-- dedicated finance finalization functions, which recalculate values and
-- enforce fiscal-series, payment and correction controls.
CREATE OR REPLACE FUNCTION public.api_issue_document(
 p_organization_id uuid,p_document_code text,p_patient_id uuid,
 p_related_resource_type text,p_related_resource_id uuid,p_content jsonb
) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO ''
AS $function$
declare v_template documents.document_templates%rowtype; v_permission text; v_professional jsonb;
begin
 if auth.uid() is null then raise exception 'AUTHENTICATION_REQUIRED' using errcode='28000'; end if;
 if p_organization_id is null or not core.is_org_member(p_organization_id) then raise exception 'ORGANIZATION_ACCESS_DENIED' using errcode='42501'; end if;
 select * into v_template from documents.document_templates
 where organization_id=p_organization_id and document_code=upper(trim(p_document_code));
 if not found then raise exception 'DOCUMENT_TEMPLATE_NOT_FOUND_OR_DISABLED' using errcode='P0002'; end if;
 if v_template.category='financial' then
  raise exception 'FINANCIAL_DOCUMENT_MUST_USE_FINANCE_FINALIZATION' using errcode='42501';
 end if;
 if not v_template.enabled then raise exception 'DOCUMENT_TEMPLATE_NOT_FOUND_OR_DISABLED' using errcode='P0002'; end if;
 v_permission:=nullif(v_template.template_config->>'required_permission','');
 if v_permission is not null then
  if not (core.has_org_permission(p_organization_id,'documents.issue') or core.has_org_permission(p_organization_id,v_permission)) then
   raise exception 'DOCUMENT_ISSUE_PERMISSION_REQUIRED' using errcode='42501';
  end if;
 elsif not (core.has_org_permission(p_organization_id,'documents.issue') or (v_template.category<>'financial' and core.has_org_permission(p_organization_id,'reception.queue.manage'))) then
  raise exception 'DOCUMENT_ISSUE_PERMISSION_REQUIRED' using errcode='42501';
 end if;
 if coalesce((v_template.template_config->>'patient_required')::boolean,false) and p_patient_id is null then
  raise exception 'PATIENT_REQUIRED_FOR_DOCUMENT' using errcode='22023';
 end if;
 if coalesce((v_template.template_config->>'requires_professional')::boolean,false) then
  select jsonb_build_object('professional_id',p.id,'professional_name',p.full_name,'professional_code',p.professional_code,'license_number',p.license_number,'department_id',p.department_id)
  into v_professional from hospital.professionals p
  where p.organization_id=p_organization_id and p.user_id=auth.uid() and p.status='active'
  order by p.created_at desc limit 1;
  if v_professional is null then raise exception 'ACTIVE_HOSPITAL_PROFESSIONAL_PROFILE_REQUIRED' using errcode='42501'; end if;
  p_content:=p_content || jsonb_build_object('responsible_professional',v_professional,'professional_validation_status','identified');
 end if;
 return documents.issue_document_internal(p_organization_id,p_document_code,p_patient_id,p_related_resource_type,p_related_resource_id,p_content);
end;
$function$;

 
-- Keep fiscal issuance disabled until the NOVA producer is explicitly
-- switched to production and its certification, credentials and signing key
-- have all been confirmed by the responsible authority.
CREATE OR REPLACE FUNCTION fiscal.guard_and_track_issued_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','documents','fiscal','extensions'
AS $function$
declare
 v_category text;
 v_settings fiscal.agt_settings%rowtype;
 v_series documents.fiscal_series%rowtype;
 v_runtime fiscal.agt_producer_runtime%rowtype;
begin
 if tg_op='INSERT' then
  select category into v_category from documents.document_templates
  where id=new.template_id and organization_id=new.organization_id;
  if v_category='financial' then
   select * into v_runtime from fiscal.agt_producer_runtime where singleton;
   if not found or v_runtime.environment is distinct from 'production'
     or v_runtime.certification_status is distinct from 'validated'
     or not v_runtime.producer_credentials_configured
     or not v_runtime.producer_signing_key_configured then
    raise exception 'NOVA_FISCAL_PRODUCTION_LOCKED: o produtor NOVA HOSPITAL ERP ainda não está validado para produção.' using errcode='42501';
   end if;
   select * into v_settings from fiscal.agt_settings where organization_id=new.organization_id;
   if not found or v_settings.status<>'approved'
     or not v_settings.api_credentials_configured
     or not v_settings.producer_signing_key_configured
     or not v_settings.taxpayer_signing_key_configured
     or nullif(v_settings.software_validation_number,'') is null
     or nullif(v_settings.software_certificate_reference,'') is null then
    raise exception 'AGT_CERTIFICATION_AND_CREDENTIALS_REQUIRED: emissão fiscal bloqueada até aprovação oficial do software, credenciais e chaves de assinatura.' using errcode='42501';
   end if;
   if new.series_id is null then raise exception 'AGT_FISCAL_SERIES_REQUIRED' using errcode='22023'; end if;
   select * into v_series from documents.fiscal_series where id=new.series_id and organization_id=new.organization_id;
   if not found or not v_series.active or not v_series.communicated_to_agt
     or nullif(v_series.agt_communication_reference,'') is null then
    raise exception 'AGT_SERIES_COMMUNICATION_REQUIRED: a série deve estar activa e comunicada à AGT.' using errcode='42501';
   end if;
  end if;
  if new.content_snapshot is not null then
   new.integrity_sha256:=encode(extensions.digest(convert_to(new.content_snapshot::text,'UTF8'),'sha256'),'hex');
   new.integrity_hash_algorithm:='SHA-256';
  end if;
  return new;
 elsif tg_op='UPDATE' then
  if new.organization_id is distinct from old.organization_id
   or new.template_id is distinct from old.template_id
   or new.document_code is distinct from old.document_code
   or new.document_number is distinct from old.document_number
   or new.patient_id is distinct from old.patient_id
   or new.series_id is distinct from old.series_id
   or new.fiscal_year is distinct from old.fiscal_year
   or new.series_code is distinct from old.series_code
   or new.sequence_number is distinct from old.sequence_number
   or new.content_snapshot is distinct from old.content_snapshot
   or new.document_hash is distinct from old.document_hash
   or new.integrity_sha256 is distinct from old.integrity_sha256
   or new.issued_at is distinct from old.issued_at then
   raise exception 'ISSUED_DOCUMENT_IMMUTABLE: não é permitido alterar os dados originais de um documento emitido.' using errcode='42501';
  end if;
  if old.document_status is distinct from new.document_status and new.document_status in ('voided','cancelled') then
   insert into fiscal.document_lifecycle_events(organization_id,issued_document_id,event_type,actor_user_id,event_payload)
   values(new.organization_id,new.id,'voided',auth.uid(),jsonb_build_object('reason',new.void_reason,'status',new.document_status));
  end if;
  return new;
 end if;
 return new;
end;
$function$;

 
-- Prevent duplicate non-fiscal document numbers caused by colliding template
-- prefixes. The template counter is independently locked and incremented by
-- documents.issue_document_internal; prefixes must therefore be unique per
-- organization across all non-financial templates.
UPDATE documents.document_templates
SET numbering_prefix = CASE document_code
  WHEN 'PARTOGRAMA' THEN 'PTG'
  WHEN 'RECLAMACAO' THEN 'RCLM'
  WHEN 'REQUISICAO_EXAMES' THEN 'REX'
  ELSE numbering_prefix
END,
updated_at = now()
WHERE organization_id = '116dfb29-ec22-4aef-9eb3-cc5f5cd064eb'
  AND document_code IN ('PARTOGRAMA','RECLAMACAO','REQUISICAO_EXAMES');

CREATE UNIQUE INDEX IF NOT EXISTS document_templates_org_nonfinancial_prefix_uq
ON documents.document_templates (organization_id, numbering_prefix)
WHERE category <> 'financial';


-- PF / Proforma: finalização administrativa, sem série fiscal e sem transmissão AGT.
create or replace function finance.finalize_proforma_internal(
  p_organization_id uuid,
  p_invoice_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invoice finance.invoices%rowtype;
  v_document jsonb;
  v_content jsonb;
  v_items jsonb;
  v_patient jsonb;
  v_settings documents.organization_document_settings%rowtype;
begin
  if auth.uid() is null
     or not core.is_org_member(p_organization_id)
     or not core.has_org_permission(p_organization_id,'finance.invoice.issue') then
    raise exception 'INVOICE_ISSUE_PERMISSION_REQUIRED' using errcode='42501';
  end if;
  select * into v_invoice from finance.invoices
  where id=p_invoice_id and organization_id=p_organization_id
    and invoice_type='proforma' and status='draft' for update;
  if not found then raise exception 'DRAFT_PROFORMA_NOT_FOUND'; end if;
  if nullif(trim(v_invoice.customer_name),'') is null then raise exception 'PROFORMA_CUSTOMER_NAME_REQUIRED'; end if;
  if not exists (select 1 from documents.document_templates
    where organization_id=p_organization_id and document_code='PROFORMA'
      and category='administrative' and enabled) then raise exception 'PROFORMA_TEMPLATE_DISABLED'; end if;
  if not exists (select 1 from finance.invoice_items
    where organization_id=p_organization_id and invoice_id=p_invoice_id) then raise exception 'PROFORMA_REQUIRES_ITEMS'; end if;
  select * into v_settings from documents.organization_document_settings where organization_id=p_organization_id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'description',i.description,'quantity',i.quantity,'unit_price',i.unit_price,
    'discount',i.discount_amount,'subtotal',i.line_subtotal,'tax',i.line_tax,
    'tax_total',i.line_tax,'total',i.line_total,'tax_type',i.tax_type,
    'tax_code',i.tax_code,'tax_rate',i.tax_rate,
    'tax_exemption_code',i.tax_exemption_code,
    'tax_exemption_reason',i.tax_exemption_reason,
    'tax_legal_reference',i.tax_legal_reference
  ) order by i.created_at,i.id),'[]'::jsonb) into v_items
  from finance.invoice_items i
  where i.organization_id=p_organization_id and i.invoice_id=p_invoice_id;
  if v_invoice.patient_id is not null then
    select jsonb_build_object('patient_id',r.id,'patient_number',r.patient_number,'patient_name',r.full_name)
    into v_patient from patient.records r
    where r.id=v_invoice.patient_id and r.organization_id=p_organization_id;
  end if;
  v_content:=jsonb_build_object(
    'document_title','FACTURA PROFORMA','document_type','proforma',
    'fiscal_document',false,'fiscal_issue',false,
    'customer_name',v_invoice.customer_name,'customer_nif',v_invoice.customer_tax_id,
    'currency','AOA','subtotal',v_invoice.subtotal,'discount_total',v_invoice.discount_total,
    'tax_total',v_invoice.tax_total,'total_amount',v_invoice.total_amount,
    'items',v_items,'notes',v_invoice.notes,'patient',v_patient,
    'patient_name',v_patient->>'patient_name','patient_number',v_patient->>'patient_number',
    'finance_invoice_id',v_invoice.id,'calculation_source','server_quote_saved_in_draft',
    'notice','PROFORMA — documento comercial não fiscal; não comprova pagamento.'
  );
  v_document:=documents.issue_document_internal(p_organization_id,'PROFORMA',v_invoice.patient_id,
    'finance_invoice',v_invoice.id,v_content);
  update finance.invoices set issued_document_id=(v_document->>'id')::uuid,
    invoice_number=v_document->>'document_number',status='issued',
    issue_date=(now() at time zone coalesce(v_settings.timezone_name,'Africa/Luanda'))::date,
    balance_due=0,updated_at=now()
  where id=v_invoice.id and organization_id=p_organization_id returning * into v_invoice;
  return jsonb_build_object('invoice',to_jsonb(v_invoice),'document',v_document,
    'document_type','proforma','fiscal_issue',false,'agt_transmission_status','not_applicable');
end;
$$;

create or replace function public.api_finance_finalize_proforma(p_organization_id uuid,p_invoice_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select finance.finalize_proforma_internal($1,$2); $$;
revoke all on function finance.finalize_proforma_internal(uuid,uuid) from public,anon,authenticated;
grant execute on function finance.finalize_proforma_internal(uuid,uuid) to authenticated,service_role;
revoke all on function public.api_finance_finalize_proforma(uuid,uuid) from public,anon;
grant execute on function public.api_finance_finalize_proforma(uuid,uuid) to authenticated,service_role;


-- Permitir estado issued apenas à PF não fiscal, mantendo OR como orçamento/rascunho.
create or replace function finance.guard_non_invoice_fiscal_issue()
returns trigger
language plpgsql
set search_path=''
as $$
begin
 if new.status='issued'
    and old.status is distinct from new.status
    and new.invoice_type not in ('invoice','invoice_receipt','credit_note','debit_note','proforma') then
   raise exception 'NON_FISCAL_DOCUMENT_CANNOT_BE_ISSUED_AS_INVOICE';
 end if;
 return new;
end;
$$;
