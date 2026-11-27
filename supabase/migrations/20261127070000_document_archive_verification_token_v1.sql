-- Return the immutable authentication token to authorised archive views without changing stored snapshots.
do $block$
declare v_definition text;
begin
  select pg_get_functiondef('public.api_list_accessible_issued_documents(uuid,timestamptz,timestamptz,integer)'::regprocedure)
    into v_definition;
  if position('d.content_snapshot,d.issued_by' in v_definition)=0 then
    raise exception 'ACCESSIBLE_DOCUMENT_LIST_ANCHOR_NOT_FOUND';
  end if;
  v_definition:=replace(v_definition,
    'd.content_snapshot,d.issued_by',
    'jsonb_set(d.content_snapshot,''{public_verification_token}'',to_jsonb(d.public_verification_token),true),d.issued_by');
  execute v_definition;

  select pg_get_functiondef('public.api_list_reception_issued_documents(uuid,timestamptz,timestamptz,integer)'::regprocedure)
    into v_definition;
  if position('d.content_snapshot,d.issued_by' in v_definition)=0 then
    raise exception 'RECEPTION_DOCUMENT_LIST_ANCHOR_NOT_FOUND';
  end if;
  v_definition:=replace(v_definition,
    'd.content_snapshot,d.issued_by',
    'jsonb_set(d.content_snapshot,''{public_verification_token}'',to_jsonb(d.public_verification_token),true),d.issued_by');
  execute v_definition;
end;
$block$;
