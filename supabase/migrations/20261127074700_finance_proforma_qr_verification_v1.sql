alter table documents.issued_documents add column if not exists public_verification_token text default replace(gen_random_uuid()::text,'-','');
update documents.issued_documents set public_verification_token=replace(gen_random_uuid()::text,'-','') where public_verification_token is null;
create unique index if not exists issued_documents_public_verification_token_uidx on documents.issued_documents(public_verification_token);
do $$ declare v_definition text; begin
 select pg_get_functiondef('documents.issue_document_internal(uuid,text,uuid,text,uuid,jsonb)'::regprocedure) into v_definition;
 if position('v_finance_permission:=v_template.category=''financial'' and core.has_org_permission' in v_definition)=0 then raise exception 'EXPECTED_FINANCE_PERMISSION_EXPRESSION_NOT_FOUND'; end if;
 v_definition:=replace(v_definition,'v_finance_permission:=v_template.category=''financial'' and core.has_org_permission(p_organization_id,''finance.invoice.issue'');','v_finance_permission:=(v_template.category=''financial'' or v_template.document_code=''PROFORMA'') and core.has_org_permission(p_organization_id,''finance.invoice.issue'');');
 if position('v_finance_permission:=(v_template.category=''financial'' or v_template.document_code=''PROFORMA'')' in v_definition)=0 then raise exception 'PROFORMA_PERMISSION_PATCH_FAILED'; end if;
 v_definition:=replace(v_definition,'''agt_transmission_status'',v_agt_status,''content_snapshot'',v_snapshot','''agt_transmission_status'',v_agt_status,''verification_token'',(select d.public_verification_token from documents.issued_documents d where d.id=v_id),''content_snapshot'',v_snapshot');
 if position('verification_token' in v_definition)=0 then raise exception 'VERIFICATION_TOKEN_RETURN_PATCH_FAILED'; end if;
 execute v_definition;
end $$;
create or replace function documents.verify_document_internal(p_verification_token text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_document documents.issued_documents%rowtype; v_snapshot jsonb;
begin
 if nullif(trim(p_verification_token),'') is null or length(p_verification_token)>128 then return jsonb_build_object('valid',false,'message','Código de validação inválido.'); end if;
 select * into v_document from documents.issued_documents d where d.public_verification_token=trim(p_verification_token) and d.document_status='issued' limit 1;
 if not found then return jsonb_build_object('valid',false,'message','Documento não encontrado ou sem estado válido.'); end if;
 v_snapshot:=coalesce(v_document.content_snapshot,'{}'::jsonb);
 return jsonb_build_object('valid',true,'document_number',v_document.document_number,'document_code',v_document.document_code,'document_status',v_document.document_status,'issued_at',v_document.issued_at,'institution_name',coalesce(v_snapshot#>>'{institution,legal_name}',v_snapshot#>>'{institution,header_title}','Instituição registada'),'fiscal_document',coalesce(v_snapshot->>'category'='financial',false),'agt_transmission_status',coalesce(v_document.agt_transmission_status,'not_applicable'));
end; $$;
revoke all on function documents.verify_document_internal(text) from public;
grant execute on function documents.verify_document_internal(text) to anon,authenticated;
create or replace function public.api_document_verify(p_verification_token text) returns jsonb language sql security invoker set search_path='' as $$ select documents.verify_document_internal($1); $$;
revoke all on function public.api_document_verify(text) from public;
grant execute on function public.api_document_verify(text) to anon,authenticated;
