revoke all on function documents.verify_document_internal(text) from public, anon, authenticated;
create or replace function public.api_document_verify(p_verification_token text)
returns jsonb
language sql
security definer
set search_path=''
as $$ select documents.verify_document_internal($1); $$;
revoke all on function public.api_document_verify(text) from public;
grant execute on function public.api_document_verify(text) to anon, authenticated;
