-- NOVA HOSPITAL ERP
-- Nursing handover workflow and tenant-scoped policy hardening.
-- Incremental and idempotent: preserves existing rows and schema objects.

drop policy if exists nursing_assessments_insert_scoped on hospital.nursing_assessments;
create policy nursing_assessments_insert_scoped
on hospital.nursing_assessments
for insert to authenticated
with check (
  recorded_by=(select auth.uid())
  and core.has_org_permission(organization_id,'hospital.nursing.write')
  and core.has_facility_department_access(organization_id,facility_id,department_id)
  and exists (
    select 1 from hospital.inpatient_admissions a
    where a.id=nursing_assessments.admission_id
      and a.organization_id=nursing_assessments.organization_id
      and a.facility_id=nursing_assessments.facility_id
      and a.department_id=nursing_assessments.department_id
      and a.patient_id=nursing_assessments.patient_id
      and a.status='admitted'
  )
);

drop policy if exists nursing_handovers_insert_scoped on hospital.nursing_handovers;
drop policy if exists nursing_handovers_read_scoped on hospital.nursing_handovers;
drop policy if exists nursing_handovers_acknowledge_scoped on hospital.nursing_handovers;

create or replace function core.is_active_nursing_recipient(
  p_organization_id uuid,p_facility_id uuid,p_department_id uuid,p_user_id uuid
)
returns boolean
language sql stable security definer
set search_path to pg_catalog, core, hospital
as $function$
  select exists (
    select 1
    from hospital.professionals hp
    join core.organization_memberships m
      on m.organization_id=hp.organization_id and m.user_id=hp.user_id and m.membership_status='active'
    join core.roles r on r.id=m.role_id and r.organization_id=m.organization_id and r.status='active'
    join core.user_profiles up on up.user_id=m.user_id and up.status='active'
    where hp.organization_id=p_organization_id
      and hp.facility_id=p_facility_id
      and hp.department_id=p_department_id
      and hp.user_id=p_user_id
      and hp.status='active'
      and (
        r.role_key in ('group_owner','institution_admin')
        or (
          exists(select 1 from core.user_facilities uf where uf.organization_id=p_organization_id and uf.user_id=p_user_id and uf.facility_id=p_facility_id)
          and exists(select 1 from core.user_departments ud where ud.organization_id=p_organization_id and ud.user_id=p_user_id and ud.department_id=p_department_id)
        )
      )
  );
$function$;

create or replace function core.list_nursing_handover_recipients(p_organization_id uuid,p_admission_id uuid)
returns table(user_id uuid,full_name text,specialty text)
language plpgsql stable security definer
set search_path to pg_catalog, core, hospital, auth
as $function$
declare v_admission hospital.inpatient_admissions%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not core.has_org_permission(p_organization_id,'hospital.nursing.handover') then raise exception 'PERMISSION_DENIED'; end if;
  select * into v_admission from hospital.inpatient_admissions
   where id=p_admission_id and organization_id=p_organization_id and status='admitted';
  if not found then raise exception 'ACTIVE_ADMISSION_REQUIRED'; end if;
  if not core.has_facility_department_access(p_organization_id,v_admission.facility_id,v_admission.department_id) then raise exception 'DEPARTMENT_SCOPE_DENIED'; end if;
  return query
  select hp.user_id,coalesce(up.preferred_name,up.full_name),hp.specialty
  from hospital.professionals hp
  join core.user_profiles up on up.user_id=hp.user_id and up.status='active'
  where hp.organization_id=p_organization_id
    and hp.facility_id=v_admission.facility_id
    and hp.department_id=v_admission.department_id
    and hp.user_id is not null and hp.user_id<>auth.uid()
    and core.is_active_nursing_recipient(p_organization_id,v_admission.facility_id,v_admission.department_id,hp.user_id)
  order by coalesce(up.preferred_name,up.full_name);
end;
$function$;

create or replace function public.api_list_nursing_handover_recipients(p_organization_id uuid,p_admission_id uuid)
returns table(user_id uuid,full_name text,specialty text)
language sql stable security invoker
set search_path to pg_catalog, public, core, auth
as $function$
  select * from core.list_nursing_handover_recipients(p_organization_id,p_admission_id);
$function$;

create policy nursing_handovers_insert_scoped
on hospital.nursing_handovers
for insert to authenticated
with check (
  outgoing_nurse_user_id=(select auth.uid())
  and incoming_nurse_user_id is not null
  and incoming_nurse_user_id<>(select auth.uid())
  and core.has_org_permission(organization_id,'hospital.nursing.handover')
  and core.has_facility_department_access(organization_id,facility_id,department_id)
  and exists (
    select 1 from hospital.inpatient_admissions a
    where a.id=nursing_handovers.admission_id
      and a.organization_id=nursing_handovers.organization_id
      and a.facility_id=nursing_handovers.facility_id
      and a.department_id=nursing_handovers.department_id
      and a.patient_id=nursing_handovers.patient_id
      and a.status='admitted'
  )
  and core.is_active_nursing_recipient(organization_id,facility_id,department_id,incoming_nurse_user_id)
);

create policy nursing_handovers_read_scoped
on hospital.nursing_handovers
for select to authenticated
using (
  (core.has_org_permission(organization_id,'hospital.nursing.read')
   or core.has_org_permission(organization_id,'hospital.nursing.handover'))
  and core.has_facility_department_access(organization_id,facility_id,department_id)
);

revoke update on table hospital.nursing_handovers from authenticated;
grant update (acknowledged_at) on table hospital.nursing_handovers to authenticated;

create policy nursing_handovers_acknowledge_scoped
on hospital.nursing_handovers
for update to authenticated
using (
  incoming_nurse_user_id=(select auth.uid())
  and acknowledged_at is null
  and core.has_org_permission(organization_id,'hospital.nursing.handover')
  and core.has_facility_department_access(organization_id,facility_id,department_id)
)
with check (
  incoming_nurse_user_id=(select auth.uid())
  and acknowledged_at is not null
  and core.has_org_permission(organization_id,'hospital.nursing.handover')
  and core.has_facility_department_access(organization_id,facility_id,department_id)
);

create or replace function public.api_create_nursing_handover(
  p_organization_id uuid,p_admission_id uuid,p_shift_code text,
  p_incoming_nurse_user_id uuid,p_clinical_summary text,
  p_pending_tasks text default null,p_risk_flags jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql security invoker
set search_path to pg_catalog, public, hospital, core, auth
as $function$
declare v_admission hospital.inpatient_admissions%rowtype; v_id uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not core.has_org_permission(p_organization_id,'hospital.nursing.handover') then raise exception 'PERMISSION_DENIED'; end if;
  if p_shift_code not in ('day','evening','night') then raise exception 'INVALID_SHIFT'; end if;
  if p_clinical_summary is null or length(trim(p_clinical_summary))<5 or length(p_clinical_summary)>5000 then raise exception 'CLINICAL_SUMMARY_REQUIRED'; end if;
  if p_pending_tasks is not null and length(p_pending_tasks)>5000 then raise exception 'PENDING_TASKS_TOO_LONG'; end if;
  if p_risk_flags is null or jsonb_typeof(p_risk_flags)<>'array' then raise exception 'INVALID_RISK_FLAGS'; end if;
  if jsonb_array_length(p_risk_flags)>20 then raise exception 'TOO_MANY_RISK_FLAGS'; end if;
  if exists(select 1 from jsonb_array_elements(p_risk_flags) as x(value)
    where jsonb_typeof(x.value)<>'string' or length(trim(x.value #>> '{}'))>120) then raise exception 'INVALID_RISK_FLAG'; end if;
  select * into v_admission from hospital.inpatient_admissions
   where id=p_admission_id and organization_id=p_organization_id and status='admitted';
  if not found then raise exception 'ACTIVE_ADMISSION_REQUIRED'; end if;
  if not core.has_facility_department_access(p_organization_id,v_admission.facility_id,v_admission.department_id) then raise exception 'DEPARTMENT_SCOPE_DENIED'; end if;
  if p_incoming_nurse_user_id is null or p_incoming_nurse_user_id=auth.uid() then raise exception 'HANDOVER_REQUIRES_SECOND_NURSE'; end if;
  if not core.is_active_nursing_recipient(p_organization_id,v_admission.facility_id,v_admission.department_id,p_incoming_nurse_user_id) then raise exception 'INVALID_INCOMING_NURSE'; end if;
  insert into hospital.nursing_handovers(
    organization_id,facility_id,department_id,admission_id,patient_id,shift_code,
    outgoing_nurse_user_id,incoming_nurse_user_id,clinical_summary,pending_tasks,risk_flags
  ) values(
    p_organization_id,v_admission.facility_id,v_admission.department_id,v_admission.id,v_admission.patient_id,
    p_shift_code,auth.uid(),p_incoming_nurse_user_id,trim(p_clinical_summary),
    nullif(trim(coalesce(p_pending_tasks,'')),''),p_risk_flags
  ) returning id into v_id;
  return jsonb_build_object('id',v_id,'status','handed_over');
end;
$function$;

create or replace function public.api_acknowledge_nursing_handover(p_organization_id uuid,p_handover_id uuid)
returns timestamptz
language plpgsql security invoker
set search_path to pg_catalog, public, hospital, core, auth
as $function$
declare v_ack timestamptz;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not core.has_org_permission(p_organization_id,'hospital.nursing.handover') then raise exception 'PERMISSION_DENIED'; end if;
  update hospital.nursing_handovers h set acknowledged_at=now()
   where h.id=p_handover_id and h.organization_id=p_organization_id
     and h.incoming_nurse_user_id=auth.uid() and h.acknowledged_at is null
     and core.has_facility_department_access(h.organization_id,h.facility_id,h.department_id)
  returning h.acknowledged_at into v_ack;
  if v_ack is null then raise exception 'HANDOVER_NOT_AVAILABLE_FOR_ACKNOWLEDGEMENT'; end if;
  return v_ack;
end;
$function$;

drop policy if exists pharmacy_purchase_orders_manage on pharmacy.purchase_orders;
create policy pharmacy_purchase_orders_manage
on pharmacy.purchase_orders
for insert to authenticated
with check (
  core.has_org_permission(organization_id,'pharmacy.procurement.manage')
  and exists(select 1 from core.facilities f where f.id=purchase_orders.facility_id and f.organization_id=purchase_orders.organization_id)
  and exists(select 1 from pharmacy.suppliers s where s.id=purchase_orders.supplier_id and s.organization_id=purchase_orders.organization_id)
);

drop policy if exists pharmacy_purchase_orders_update on pharmacy.purchase_orders;
create policy pharmacy_purchase_orders_update
on pharmacy.purchase_orders
for update to authenticated
using (
  core.has_org_permission(organization_id,'pharmacy.procurement.manage')
  and exists(select 1 from core.facilities f where f.id=purchase_orders.facility_id and f.organization_id=purchase_orders.organization_id)
  and exists(select 1 from pharmacy.suppliers s where s.id=purchase_orders.supplier_id and s.organization_id=purchase_orders.organization_id)
)
with check (
  core.has_org_permission(organization_id,'pharmacy.procurement.manage')
  and exists(select 1 from core.facilities f where f.id=purchase_orders.facility_id and f.organization_id=purchase_orders.organization_id)
  and exists(select 1 from pharmacy.suppliers s where s.id=purchase_orders.supplier_id and s.organization_id=purchase_orders.organization_id)
);

revoke all on function core.is_active_nursing_recipient(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function core.is_active_nursing_recipient(uuid,uuid,uuid,uuid) to authenticated;
revoke all on function core.list_nursing_handover_recipients(uuid,uuid) from public,anon;
grant execute on function core.list_nursing_handover_recipients(uuid,uuid) to authenticated;
revoke all on function public.api_list_nursing_handover_recipients(uuid,uuid) from public,anon;
revoke all on function public.api_create_nursing_handover(uuid,uuid,text,uuid,text,text,jsonb) from public,anon;
revoke all on function public.api_acknowledge_nursing_handover(uuid,uuid) from public,anon;
grant execute on function public.api_list_nursing_handover_recipients(uuid,uuid) to authenticated;
grant execute on function public.api_create_nursing_handover(uuid,uuid,text,uuid,text,text,jsonb) to authenticated;
grant execute on function public.api_acknowledge_nursing_handover(uuid,uuid) to authenticated;
