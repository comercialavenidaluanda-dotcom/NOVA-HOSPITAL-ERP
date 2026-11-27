-- Central document authentication v2: issuer identity + integrity check for every issued document.
alter table documents.issued_documents alter column public_verification_token
  set default replace(gen_random_uuid()::text, '-', '');
update documents.issued_documents set public_verification_token=replace(gen_random_uuid()::text,'-','')
where public_verification_token is null;
alter table documents.issued_documents alter column public_verification_token set not null;
create or replace function documents.verify_document_internal(p_verification_token text)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
 v_document documents.issued_documents%rowtype; v_snapshot jsonb; v_institution jsonb;
 v_content jsonb; v_integrity_ok boolean := false; v_is_issued boolean := false;
begin
 if nullif(trim(p_verification_token),'') is null or length(p_verification_token)>128 then
  return jsonb_build_object('valid',false,'document_found',false,'message','Código de autenticação inválido.');
 end if;
 select * into v_document from documents.issued_documents d
 where d.public_verification_token=trim(p_verification_token) limit 1;
 if not found then return jsonb_build_object('valid',false,'document_found',false,
  'message','Documento não encontrado no registo da entidade emissora.'); end if;
 v_snapshot:=coalesce(v_document.content_snapshot,'{}'::jsonb);
 v_institution:=coalesce(v_snapshot->'institution','{}'::jsonb);
 v_content:=coalesce(v_snapshot->'content','{}'::jsonb);
 v_integrity_ok:=v_document.integrity_sha256 is not null
  and v_document.integrity_hash_algorithm='SHA-256'
  and encode(extensions.digest(convert_to(v_document.content_snapshot::text,'UTF8'),'sha256'),'hex')
      =v_document.integrity_sha256;
 v_is_issued:=v_document.document_status='issued';
 return jsonb_build_object(
  'valid',v_is_issued and v_integrity_ok,'document_found',true,
  'document_number',v_document.document_number,'document_code',v_document.document_code,
  'document_status',v_document.document_status,'issued_at',v_document.issued_at,
  'institution_name',coalesce(nullif(v_institution->>'legal_name',''),
   nullif(v_institution->>'header_title',''),nullif(v_institution->>'display_name',''),'Entidade emissora registada'),
  'institution_tax_id',coalesce(nullif(v_institution->>'tax_identifier',''),nullif(v_institution->>'agt_taxpayer_code','')),
  'institution_address',nullif(v_institution->>'address_text',''),
  'institution_phone',nullif(v_institution->>'contact_phone',''),
  'institution_email',nullif(v_institution->>'contact_email',''),
  'institution_website',nullif(v_institution->>'website',''),
  'valid_until',nullif(v_content->>'valid_until',''),
  'document_category',coalesce(v_snapshot->>'category','institutional'),
  'fiscal_document',coalesce(v_content->>'fiscal_issue'='true' or v_snapshot->>'category'='financial',false),
  'agt_transmission_status',coalesce(v_document.agt_transmission_status,'not_applicable'),
  'integrity_verified',v_integrity_ok,
  'message',case when not v_is_issued then 'Documento localizado, mas encontra-se anulado ou sem estado de emissão válido.'
   when not v_integrity_ok then 'A integridade do documento não pôde ser confirmada. Contacte a entidade emissora.'
   else 'Documento autêntico e íntegro, confirmado no registo da entidade emissora.' end
 );
end;
$function$;
revoke all on function documents.verify_document_internal(text) from public;
grant execute on function documents.verify_document_internal(text) to anon,authenticated;
create or replace function public.api_document_verify(p_verification_token text)
returns jsonb language sql security invoker set search_path=''
as $function$ select documents.verify_document_internal($1); $function$;
revoke all on function public.api_document_verify(text) from public;
grant execute on function public.api_document_verify(text) to anon,authenticated;
