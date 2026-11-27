revoke all on all functions in schema documents from public;
revoke all on all functions in schema documents from anon;
grant execute on all functions in schema documents to authenticated;
grant usage on schema documents to anon, authenticated;
grant execute on function documents.verify_document_internal(text) to anon;
create or replace function public.api_document_verify(p_verification_token text)
returns jsonb language sql security invoker set search_path=''
as $$ select documents.verify_document_internal($1); $$;
revoke all on function public.api_document_verify(text) from public;
grant execute on function public.api_document_verify(text) to anon, authenticated;
