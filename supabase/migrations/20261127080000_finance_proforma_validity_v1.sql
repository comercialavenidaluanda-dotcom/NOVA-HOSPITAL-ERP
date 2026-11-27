do $$ declare v_definition text; begin
 select pg_get_functiondef('finance.finalize_proforma_internal(uuid,uuid)'::regprocedure) into v_definition;
 if position('''document_type'',''proforma'',' in v_definition)=0 then raise exception 'PROFORMA_CONTENT_ANCHOR_NOT_FOUND'; end if;
 v_definition:=replace(v_definition,'''document_type'',''proforma'',','''document_type'',''proforma'',''valid_until'',v_invoice.due_date,');
 if position('''valid_until'',v_invoice.due_date' in v_definition)=0 then raise exception 'PROFORMA_VALIDITY_PATCH_FAILED'; end if;
 execute v_definition;
end $$;