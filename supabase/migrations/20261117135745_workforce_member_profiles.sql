-- Unified member administration: contact data, weekly availability and
-- per-person permission overrides. Authorization remains enforced in Postgres.

alter table workforce.people
  add column contact_email text,
  add constraint workforce_people_contact_email_check check (
    contact_email is null or (
      contact_email=lower(btrim(contact_email)) and length(contact_email)<=254
      and contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    )
  );

alter table workforce.permissions add column module text not null default 'workforce';
update workforce.permissions set module=case
  when code in ('attendance_view_own','attendance_mark') then 'personal'
  when code in ('tasks_view_own','tasks_update_own','team_view','attendance_view_team','tasks_view_team','tasks_assign','tasks_cancel') then 'workforce'
  when code='integrations_manage' then 'integrations'
  else 'administration' end;

insert into workforce.permissions(code,name,description,category,module,sort_order) values
  ('finance_view','Ver Finanzas','Consultar saldos, movimientos y proyecciones financieras.','administration','finance',200),
  ('finance_edit','Registrar en Finanzas','Crear y editar registros financieros sin aprobarlos.','administration','finance',210),
  ('finance_approve','Aprobar en Finanzas','Autorizar cierres, ajustes y operaciones financieras.','administration','finance',220),
  ('cash_view','Ver Caja','Consultar cajas, recaudos, pagos y cierres.','administration','cash',230),
  ('cash_register','Registrar en Caja','Crear recaudos, pagos, traslados y novedades.','administration','cash',240),
  ('cash_close','Cerrar Caja','Aprobar cierres y excepciones de caja.','administration','cash',250),
  ('inventory_view','Ver Inventarios','Consultar existencias, lotes y valorización.','administration','inventory',260),
  ('inventory_register','Registrar Inventarios','Crear movimientos, lotes y conteos físicos.','administration','inventory',270),
  ('inventory_approve','Aprobar Inventarios','Autorizar conformidades, ajustes y cierres.','administration','inventory',280),
  ('sales_view','Ver Ventas','Consultar clientes, pedidos y ventas.','administration','sales',290),
  ('sales_register','Registrar Ventas','Crear y editar pedidos, clientes y ventas.','administration','sales',300),
  ('sales_approve','Aprobar Ventas','Autorizar excepciones y condiciones comerciales.','administration','sales',310),
  ('debts_view','Ver Deudas','Consultar cartera, obligaciones y vencimientos.','administration','debts',320),
  ('debts_register','Registrar Deudas','Crear facturas, pagos y devoluciones en disputa.','administration','debts',330),
  ('debts_approve','Aprobar Deudas','Autorizar correcciones y excepciones de deuda.','administration','debts',340),
  ('agenda_view','Ver Agenda financiera','Consultar compromisos y vencimientos.','administration','agenda',350),
  ('agenda_manage','Gestionar Agenda financiera','Programar, editar y cerrar compromisos.','administration','agenda',360),
  ('reports_view','Ver Informes','Consultar tableros e informes consolidados.','administration','reports',370),
  ('reports_export','Exportar Informes','Descargar y compartir informes autorizados.','administration','reports',380),
  ('documents_view','Ver Documentos','Consultar archivos empresariales autorizados.','administration','documents',390),
  ('documents_upload','Cargar Documentos','Subir archivos y completar sus metadatos.','administration','documents',400),
  ('documents_manage','Administrar Documentos','Clasificar, aprobar, restringir y retirar documentos.','administration','documents',410);

update workforce.roles set name='Administrador total',description='Control total de usuarios, módulos, información y configuración.' where code='admin';
update workforce.roles set name='Agente',description='Opera su jornada, sus tareas y los módulos que se le autoricen.' where code='employee';
insert into workforce.roles(code,name,description,system) values
  ('reader','Lector','Consulta únicamente la información de los módulos autorizados.',true);

insert into workforce.role_permissions(role_code,permission_code)
select 'admin',code from workforce.permissions on conflict do nothing;
insert into workforce.role_permissions(role_code,permission_code) values
  ('reader','attendance_view_own'),('reader','tasks_view_own'),
  ('reader','finance_view'),('reader','cash_view'),('reader','inventory_view'),
  ('reader','sales_view'),('reader','debts_view'),('reader','agenda_view'),
  ('reader','reports_view'),('reader','documents_view')
on conflict do nothing;

create table workforce.person_permission_overrides (
  person_id uuid not null references workforce.people(id) on delete cascade,
  permission_code text not null references workforce.permissions(code) on delete cascade,
  granted boolean not null,
  updated_by uuid not null references workforce.people(id) on delete restrict,
  updated_at timestamptz not null default clock_timestamp(),
  primary key(person_id,permission_code)
);

create table workforce.availability (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references workforce.people(id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_time time not null,
  end_time time not null,
  slot_order smallint not null check (slot_order between 0 and 7),
  active boolean not null default true,
  updated_by uuid not null references workforce.people(id) on delete restrict,
  updated_at timestamptz not null default clock_timestamp(),
  constraint workforce_availability_time_check check (start_time<end_time),
  unique(person_id,weekday,slot_order)
);

alter table workforce.person_permission_overrides enable row level security;
alter table workforce.availability enable row level security;
revoke all on workforce.person_permission_overrides,workforce.availability from public,anon,authenticated;

create or replace function workforce.has_permission(p_actor workforce.people,p_permission text)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce(
    (select o.granted from workforce.person_permission_overrides o
      where o.person_id=p_actor.id and o.permission_code=p_permission),
    exists(
      select 1 from workforce.roles r
      join workforce.role_permissions rp on rp.role_code=r.code
      where r.code=p_actor.access_role and r.active and rp.permission_code=p_permission
    )
  )
$$;

create function workforce.effective_permissions(p_person workforce.people)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(p.code order by p.sort_order),'[]'::jsonb)
  from workforce.permissions p
  where workforce.has_permission(p_person,p.code)
$$;

create function workforce.save_member_access(p_person uuid,p_email text,p_role text,p_permissions text[])
returns void language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); subject workforce.people; normalized_email text;
begin
  perform pg_advisory_xact_lock(727714,4);
  if coalesce(auth.jwt()->>'aal','')<>'aal2' or not workforce.has_permission(actor,'people_manage')
    or not workforce.has_permission(actor,'roles_manage') then
    raise exception 'Se requiere control de usuarios, roles y doble factor.' using errcode='42501';
  end if;
  select * into subject from workforce.people where id=p_person for update;
  if subject.id is null or p_role is null or p_permissions is null
    or not exists(select 1 from workforce.roles r where r.code=p_role and r.active)
    or exists(select 1 from unnest(p_permissions) x where not exists(select 1 from workforce.permissions p where p.code=x)) then
    raise exception 'Revisa el usuario, el rol y sus permisos.' using errcode='22023';
  end if;
  if actor.id=subject.id and (p_role<>subject.access_role or
    (select count(distinct x) from unnest(p_permissions) x)<>(select count(*) from workforce.permissions)) then
    raise exception 'Tu cuenta conserva control total para evitar un bloqueo administrativo.' using errcode='22023';
  end if;
  if p_role='admin' and (select count(distinct x) from unnest(p_permissions) x)<>(select count(*) from workforce.permissions) then
    raise exception 'El Administrador total debe conservar todos los permisos.' using errcode='22023';
  end if;
  normalized_email:=nullif(lower(btrim(coalesce(p_email,''))), '');
  if normalized_email is not null and normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Introduce un correo válido.' using errcode='22023';
  end if;
  update workforce.people set contact_email=normalized_email,access_role=p_role where id=subject.id;
  delete from workforce.person_permission_overrides where person_id=subject.id;
  insert into workforce.person_permission_overrides(person_id,permission_code,granted,updated_by)
  select subject.id,p.code,(p.code=any(p_permissions)),actor.id
  from workforce.permissions p
  where (p.code=any(p_permissions)) is distinct from exists(
    select 1 from workforce.role_permissions rp where rp.role_code=p_role and rp.permission_code=p.code
  );
end;
$$;

create function workforce.save_availability(p_person uuid,p_schedule jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); schedule_item jsonb;
begin
  perform pg_advisory_xact_lock(727714,5);
  if coalesce(auth.jwt()->>'aal','')<>'aal2' or not workforce.has_permission(actor,'people_manage') then
    raise exception 'Se requiere autorización de usuarios y doble factor.' using errcode='42501';
  end if;
  if not exists(select 1 from workforce.people where id=p_person) or jsonb_typeof(p_schedule)<>'array'
    or jsonb_array_length(p_schedule) not between 1 and 56 then
    raise exception 'El horario no es válido.' using errcode='22023';
  end if;
  for schedule_item in select value from jsonb_array_elements(p_schedule) loop
    if (schedule_item->>'weekday')::integer not between 1 and 7
      or (schedule_item->>'slot_order')::integer not between 0 and 7
      or (schedule_item->>'start_time')::time >= (schedule_item->>'end_time')::time then
      raise exception 'Revisa los intervalos del horario.' using errcode='22023';
    end if;
  end loop;
  delete from workforce.availability where person_id=p_person;
  insert into workforce.availability(person_id,weekday,start_time,end_time,slot_order,active,updated_by)
  select p_person,(entry.value->>'weekday')::smallint,(entry.value->>'start_time')::time,(entry.value->>'end_time')::time,
    (entry.value->>'slot_order')::smallint,coalesce((entry.value->>'active')::boolean,true),actor.id
  from jsonb_array_elements(p_schedule) as entry(value);
end;
$$;

create or replace function workforce.day_snapshot(p_day date) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor workforce.people:=workforce.require_person(); stamp timestamptz:=statement_timestamp();
  today date:=(stamp at time zone 'America/Bogota')::date; day date:=coalesce(p_day,today);
  start_at timestamptz:=day::timestamp at time zone 'America/Bogota'; end_at timestamptz:=(day+1)::timestamp at time zone 'America/Bogota';
  verified boolean:=coalesce(auth.jwt()->>'aal','')='aal2'; manage_people boolean:=workforce.has_permission(actor,'people_manage');
  manage_roles boolean:=workforce.has_permission(actor,'roles_manage'); view_team boolean:=workforce.has_permission(actor,'team_view');
  view_team_attendance boolean:=workforce.has_permission(actor,'attendance_view_team'); view_team_tasks boolean:=workforce.has_permission(actor,'tasks_view_team');
begin
  if not isfinite(day) then raise exception 'Selecciona una fecha válida.' using errcode='22023'; end if;
  return jsonb_build_object(
    'me',jsonb_build_object('id',actor.id,'full_name',actor.full_name,'job_title',actor.job_title,'area',actor.area,'access_role',actor.access_role),
    'capabilities',workforce.effective_permissions(actor),
    'can_manage',verified and (manage_people or manage_roles or view_team or view_team_attendance or view_team_tasks or workforce.has_permission(actor,'tasks_assign') or workforce.has_permission(actor,'tasks_cancel')),
    'day',day,'today',today,'server_now',stamp,
    'roles',coalesce((select jsonb_agg(jsonb_build_object('code',r.code,'name',r.name,'description',r.description,'system',r.system,'active',r.active,
      'permissions',coalesce((select jsonb_agg(rp.permission_code order by p.sort_order) from workforce.role_permissions rp join workforce.permissions p on p.code=rp.permission_code where rp.role_code=r.code),'[]'::jsonb))
      order by case r.code when 'admin' then 0 when 'employee' then 1 when 'reader' then 2 when 'supervisor' then 3 else 4 end,r.name,r.code)
      from workforce.roles r where r.code=actor.access_role or (manage_people and r.active) or manage_roles),'[]'::jsonb),
    'permissions',coalesce((select jsonb_agg(to_jsonb(p) order by p.sort_order) from workforce.permissions p where manage_roles),'[]'::jsonb),
    'people',coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'full_name',p.full_name,'job_title',p.job_title,'area',p.area,'email',p.contact_email,
      'access_role',p.access_role,'active',p.active,'registered',p.user_id is not null,'supervisor_id',p.supervisor_id,
      'identifier_hash',case when workforce.has_permission(actor,'access_manage') then p.identifier_hash end,
      'identifier_last_four',case when workforce.has_permission(actor,'access_manage') then p.identifier_last_four end,
      'permissions',case when manage_roles then workforce.effective_permissions(p) else '[]'::jsonb end,
      'availability',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'person_id',a.person_id,'weekday',a.weekday,
        'start_time',to_char(a.start_time,'HH24:MI'),'end_time',to_char(a.end_time,'HH24:MI'),'slot_order',a.slot_order,'active',a.active)
        order by a.weekday,a.slot_order) from workforce.availability a where a.person_id=p.id),'[]'::jsonb)
    ) order by (p.id=actor.id) desc,p.active desc,p.full_name,p.id)
      from workforce.people p where verified and (manage_people or (view_team and p.supervisor_id=actor.id))),'[]'::jsonb),
    'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.arrived_at desc) from workforce.shifts s join workforce.people p on p.id=s.person_id
      where ((p.id=actor.id and workforce.has_permission(actor,'attendance_view_own')) or (verified and view_team_attendance and (manage_people or p.supervisor_id=actor.id)))
      and ((s.arrived_at<end_at and coalesce(s.left_at,stamp)>=start_at) or (day=today and s.left_at is null))),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_at nulls last,t.created_at,t.id) from workforce.tasks t join workforce.people p on p.id=t.person_id
      where t.scheduled_on=day and ((p.id=actor.id and workforce.has_permission(actor,'tasks_view_own')) or (verified and view_team_tasks and (manage_people or p.supervisor_id=actor.id)))),'[]'::jsonb)
  );
end;
$$;

create function public.workforce_save_member_access(p_person uuid,p_email text,p_role text,p_permissions text[])
returns void language sql security invoker set search_path='' as $$ select workforce.save_member_access(p_person,p_email,p_role,p_permissions) $$;
create function public.workforce_save_availability(p_person uuid,p_schedule jsonb)
returns void language sql security invoker set search_path='' as $$ select workforce.save_availability(p_person,p_schedule) $$;

revoke execute on function workforce.effective_permissions(workforce.people),workforce.save_member_access(uuid,text,text,text[]),workforce.save_availability(uuid,jsonb) from public,anon,authenticated;
grant execute on function workforce.save_member_access(uuid,text,text,text[]),workforce.save_availability(uuid,jsonb) to authenticated;
revoke all on function public.workforce_save_member_access(uuid,text,text,text[]),public.workforce_save_availability(uuid,jsonb) from public,anon;
grant execute on function public.workforce_save_member_access(uuid,text,text,text[]),public.workforce_save_availability(uuid,jsonb) to authenticated;
