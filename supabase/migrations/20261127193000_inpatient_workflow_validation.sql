-- NOVA HOSPITAL ERP
-- Hardening of inpatient transfer and discharge server-side validation.
-- Incremental: preserves all existing admissions, events and bed movements.

create or replace function hospital.transfer_inpatient(
  p_organization_id uuid,
  p_admission_id uuid,
  p_to_bed_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admission hospital.inpatient_admissions%rowtype;
  v_to_ward_id uuid;
  v_to_status text;
  v_movement_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_reason is null or length(btrim(p_reason)) < 3 or length(p_reason) > 1000 then
    raise exception 'Transfer reason must contain between 3 and 1000 characters';
  end if;

  select * into v_admission
  from hospital.inpatient_admissions
  where id=p_admission_id and organization_id=p_organization_id
  for update;

  if not found or v_admission.status <> 'admitted' then
    raise exception 'Active inpatient admission not found';
  end if;

  if not core.has_org_permission(p_organization_id,'hospital.inpatient.transfer')
     or not core.has_facility_department_access(p_organization_id,v_admission.facility_id,v_admission.department_id) then
    raise exception 'Insufficient permission for inpatient transfer';
  end if;

  if p_to_bed_id=v_admission.current_bed_id then
    raise exception 'Destination bed is the current bed';
  end if;

  select b.ward_id,b.status into v_to_ward_id,v_to_status
  from hospital.beds b
  join hospital.wards w on w.id=b.ward_id and w.organization_id=b.organization_id and w.facility_id=b.facility_id and w.department_id=b.department_id
  join hospital.rooms r on r.id=b.room_id and r.organization_id=b.organization_id and r.facility_id=b.facility_id and r.department_id=b.department_id and r.ward_id=b.ward_id
  where b.id=p_to_bed_id and b.organization_id=p_organization_id
    and b.facility_id=v_admission.facility_id and b.department_id=v_admission.department_id
    and b.is_active and w.status='active' and r.status='active'
  for update of b;

  if not found or v_to_status <> 'available' then
    raise exception 'Destination bed is unavailable';
  end if;

  perform set_config('hospital.internal_bed_state_change','on',true);

  update hospital.beds set status='cleaning',updated_at=now()
  where id=v_admission.current_bed_id and organization_id=p_organization_id and status='occupied';

  if not found then
    raise exception 'Current bed state is inconsistent';
  end if;

  update hospital.beds set status='occupied',updated_at=now()
  where id=p_to_bed_id and organization_id=p_organization_id;

  update hospital.inpatient_admissions
  set current_bed_id=p_to_bed_id,current_ward_id=v_to_ward_id,updated_at=now()
  where id=p_admission_id and organization_id=p_organization_id;

  insert into hospital.inpatient_bed_movements(
    organization_id,facility_id,department_id,admission_id,from_bed_id,from_ward_id,
    to_bed_id,to_ward_id,movement_type,reason,moved_by
  ) values (
    p_organization_id,v_admission.facility_id,v_admission.department_id,p_admission_id,
    v_admission.current_bed_id,v_admission.current_ward_id,p_to_bed_id,v_to_ward_id,
    'transfer',btrim(p_reason),v_user_id
  ) returning id into v_movement_id;

  insert into hospital.inpatient_events(
    organization_id,facility_id,department_id,admission_id,event_type,event_data,actor_user_id
  ) values (
    p_organization_id,v_admission.facility_id,v_admission.department_id,p_admission_id,
    'transferred',jsonb_build_object('from_bed_id',v_admission.current_bed_id,'to_bed_id',p_to_bed_id,'reason',btrim(p_reason)),v_user_id
  );

  return v_movement_id;
end;
$function$;

create or replace function hospital.discharge_inpatient(
  p_organization_id uuid,
  p_admission_id uuid,
  p_discharge_destination text,
  p_discharge_summary text
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_admission hospital.inpatient_admissions%rowtype;
  v_movement_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if p_discharge_summary is null or length(btrim(p_discharge_summary)) < 10 or length(p_discharge_summary) > 5000 then
    raise exception 'Discharge summary must contain between 10 and 5000 characters';
  end if;

  if p_discharge_destination is not null and length(p_discharge_destination) > 200 then
    raise exception 'Discharge destination cannot exceed 200 characters';
  end if;

  select * into v_admission
  from hospital.inpatient_admissions
  where id=p_admission_id and organization_id=p_organization_id
  for update;

  if not found or v_admission.status <> 'admitted' then
    raise exception 'Active inpatient admission not found';
  end if;

  if not core.has_org_permission(p_organization_id,'hospital.inpatient.discharge')
     or not core.has_facility_department_access(p_organization_id,v_admission.facility_id,v_admission.department_id) then
    raise exception 'Insufficient permission for inpatient discharge';
  end if;

  perform set_config('hospital.internal_bed_state_change','on',true);

  update hospital.beds set status='cleaning',updated_at=now()
  where id=v_admission.current_bed_id and organization_id=p_organization_id and status='occupied';

  if not found then
    raise exception 'Current bed state is inconsistent';
  end if;

  update hospital.inpatient_admissions
  set status='discharged',current_bed_id=null,current_ward_id=null,
      discharged_at=now(),discharge_destination=nullif(btrim(p_discharge_destination),''),
      discharge_summary=btrim(p_discharge_summary),discharged_by=v_user_id,updated_at=now()
  where id=p_admission_id and organization_id=p_organization_id;

  insert into hospital.inpatient_bed_movements(
    organization_id,facility_id,department_id,admission_id,from_bed_id,from_ward_id,
    movement_type,reason,moved_by
  ) values (
    p_organization_id,v_admission.facility_id,v_admission.department_id,p_admission_id,
    v_admission.current_bed_id,v_admission.current_ward_id,'discharge_release','Alta hospitalar',v_user_id
  ) returning id into v_movement_id;

  insert into hospital.inpatient_events(
    organization_id,facility_id,department_id,admission_id,event_type,previous_status,new_status,event_data,actor_user_id
  ) values (
    p_organization_id,v_admission.facility_id,v_admission.department_id,p_admission_id,
    'discharged','admitted','discharged',
    jsonb_build_object('destination',nullif(btrim(p_discharge_destination),'')),v_user_id
  );

  return v_movement_id;
end;
$function$;

revoke all on function hospital.transfer_inpatient(uuid,uuid,uuid,text) from public,anon;
revoke all on function hospital.discharge_inpatient(uuid,uuid,text,text) from public,anon;
grant execute on function hospital.transfer_inpatient(uuid,uuid,uuid,text) to authenticated;
grant execute on function hospital.discharge_inpatient(uuid,uuid,text,text) to authenticated;
