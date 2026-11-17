-- Equipo uses one authenticated session. Granular permissions remain enforced
-- in PostgreSQL, but administrators are no longer sent through a second,
-- separate MFA screen before opening the people and permissions console.

create or replace function workforce.can_manage(actor workforce.people,subject workforce.people)
returns boolean language sql stable security definer set search_path='' as $$
  select
    (workforce.has_permission(actor,'people_manage') and actor.access_role='admin')
    or (workforce.has_permission(actor,'team_view') and subject.supervisor_id=actor.id)
$$;

create or replace function workforce.save_person(
  p_id uuid,p_identifier_hash text,p_identifier_last_four text,p_name text,p_title text,p_area text,
  p_role text,p_supervisor uuid,p_active boolean
) returns uuid language plpgsql security definer set search_path='' as $$
declare actor workforce.people; existing workforce.people;
begin
  perform pg_advisory_xact_lock(727714,1);
  actor:=workforce.require_person();
  if not workforce.has_permission(actor,'people_manage') then
    raise exception 'Se requiere autorización para administrar personas.' using errcode='42501';
  end if;
  if p_id is null or p_role is null or p_active is null or p_identifier_hash !~ '^[0-9a-f]{64}$'
    or p_identifier_last_four !~ '^[0-9]{4}$' or not exists(
      select 1 from workforce.roles r where r.code=p_role and r.active
    ) then raise exception 'Completa los datos y selecciona un rol activo.' using errcode='22023'; end if;
  select * into existing from workforce.people where id=p_id for update;
  if actor.id=p_id and (p_role<>actor.access_role or not p_active) then
    raise exception 'Tu cuenta conserva control total para evitar un bloqueo administrativo.' using errcode='22023';
  end if;
  if actor.access_role<>'admin' and (p_role='admin' or existing.access_role='admin') then
    raise exception 'Solo un administrador puede modificar administradores.' using errcode='42501';
  end if;
  if existing.access_role='admin' and (p_role<>'admin' or not p_active) and not exists(
    select 1 from workforce.people p where p.id<>p_id and p.active and p.access_role='admin'
  ) then raise exception 'Equipo requiere por lo menos un administrador activo.' using errcode='22023'; end if;
  if existing.user_id is not null and existing.identifier_hash<>p_identifier_hash then
    raise exception 'La cédula de una cuenta vinculada no se puede cambiar.' using errcode='22023';
  end if;
  if (not p_active or not exists(select 1 from workforce.role_permissions rp where rp.role_code=p_role and rp.permission_code='team_view'))
    and exists(select 1 from workforce.people p where p.supervisor_id=p_id and p.active) then
    raise exception 'Reasigna primero a las personas de este equipo.' using errcode='22023';
  end if;
  if p_supervisor is not null and (p_supervisor=p_id or not exists(
    select 1 from workforce.people p join workforce.role_permissions rp on rp.role_code=p.access_role
    where p.id=p_supervisor and p.active and rp.permission_code='team_view'
  )) then raise exception 'Selecciona una persona activa con permiso para coordinar.' using errcode='22023'; end if;
  if not p_active and exists(select 1 from workforce.shifts where person_id=p_id and left_at is null) then
    raise exception 'La persona debe registrar la salida antes de desactivar su acceso.' using errcode='22023'; end if;
  insert into workforce.people(id,email,identifier_hash,identifier_last_four,full_name,job_title,area,access_role,supervisor_id,active)
    values(p_id,null,p_identifier_hash,p_identifier_last_four,btrim(p_name),btrim(p_title),btrim(p_area),p_role,p_supervisor,p_active)
  on conflict(id) do update set identifier_hash=excluded.identifier_hash,identifier_last_four=excluded.identifier_last_four,
    full_name=excluded.full_name,job_title=excluded.job_title,area=excluded.area,access_role=excluded.access_role,
    supervisor_id=excluded.supervisor_id,active=excluded.active;
  return p_id;
end;
$$;

create or replace function workforce.invite_target(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); target workforce.people;
begin
  if not workforce.has_permission(actor,'access_manage') then
    raise exception 'Se requiere autorización para administrar accesos.' using errcode='42501';
  end if;
  select * into target from workforce.people where id=p_id and active;
  if target.id is null then raise exception 'La persona no tiene acceso activo.' using errcode='22023'; end if;
  return jsonb_build_object('identifier_hash',target.identifier_hash,'registered',target.user_id is not null);
end;
$$;

create or replace function workforce.save_member_access(p_person uuid,p_email text,p_role text,p_permissions text[])
returns void language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); subject workforce.people; normalized_email text;
begin
  perform pg_advisory_xact_lock(727714,4);
  if not workforce.has_permission(actor,'people_manage') or not workforce.has_permission(actor,'roles_manage') then
    raise exception 'Se requiere control de usuarios y roles.' using errcode='42501';
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

create or replace function workforce.save_availability(p_person uuid,p_schedule jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); schedule_item jsonb;
begin
  perform pg_advisory_xact_lock(727714,5);
  if not workforce.has_permission(actor,'people_manage') then
    raise exception 'Se requiere autorización para administrar usuarios.' using errcode='42501';
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
  authenticated boolean:=auth.uid() is not null; manage_people boolean:=workforce.has_permission(actor,'people_manage');
  manage_roles boolean:=workforce.has_permission(actor,'roles_manage'); view_team boolean:=workforce.has_permission(actor,'team_view');
  view_team_attendance boolean:=workforce.has_permission(actor,'attendance_view_team'); view_team_tasks boolean:=workforce.has_permission(actor,'tasks_view_team');
begin
  if not isfinite(day) then raise exception 'Selecciona una fecha válida.' using errcode='22023'; end if;
  return jsonb_build_object(
    'me',jsonb_build_object('id',actor.id,'full_name',actor.full_name,'job_title',actor.job_title,'area',actor.area,'access_role',actor.access_role),
    'capabilities',workforce.effective_permissions(actor),
    'can_manage',authenticated and (manage_people or manage_roles or view_team or view_team_attendance or view_team_tasks or workforce.has_permission(actor,'tasks_assign') or workforce.has_permission(actor,'tasks_cancel')),
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
      from workforce.people p where authenticated and (manage_people or (view_team and p.supervisor_id=actor.id))),'[]'::jsonb),
    'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.arrived_at desc) from workforce.shifts s join workforce.people p on p.id=s.person_id
      where ((p.id=actor.id and workforce.has_permission(actor,'attendance_view_own')) or (authenticated and view_team_attendance and (manage_people or p.supervisor_id=actor.id)))
      and ((s.arrived_at<end_at and coalesce(s.left_at,stamp)>=start_at) or (day=today and s.left_at is null))),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_at nulls last,t.created_at,t.id) from workforce.tasks t join workforce.people p on p.id=t.person_id
      where t.scheduled_on=day and ((p.id=actor.id and workforce.has_permission(actor,'tasks_view_own')) or (authenticated and view_team_tasks and (manage_people or p.supervisor_id=actor.id)))),'[]'::jsonb)
  );
end;
$$;
