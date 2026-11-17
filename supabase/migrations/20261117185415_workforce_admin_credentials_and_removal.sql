-- Administrators define the initial password when a person is created. Removed
-- people are archived instead of erasing their attendance, tasks or audit trail.

alter table workforce.people add column removed_at timestamptz;
create index workforce_people_active_directory
  on workforce.people(active,full_name,id) where removed_at is null;

create function workforce.remove_person(p_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor workforce.people:=workforce.require_person();
  target workforce.people;
  old_hash text;
  old_user uuid;
  stamp timestamptz:=clock_timestamp();
begin
  perform pg_advisory_xact_lock(727714,6);
  if not workforce.has_permission(actor,'people_manage')
    or not workforce.has_permission(actor,'access_manage') then
    raise exception 'Se requiere control de usuarios y accesos.' using errcode='42501';
  end if;
  select * into target from workforce.people
    where id=p_id and removed_at is null for update;
  if target.id is null then
    raise exception 'El usuario ya no existe en el equipo.' using errcode='22023';
  end if;
  if target.id=actor.id then
    raise exception 'Tu cuenta de control total no se puede eliminar.' using errcode='22023';
  end if;
  if target.access_role='admin' and not exists(
    select 1 from workforce.people p
    where p.id<>target.id and p.active and p.removed_at is null and p.access_role='admin'
  ) then
    raise exception 'Equipo requiere por lo menos un administrador activo.' using errcode='22023';
  end if;
  if exists(select 1 from workforce.people p where p.supervisor_id=target.id and p.active and p.removed_at is null) then
    raise exception 'Reasigna primero a las personas de este equipo.' using errcode='22023';
  end if;
  if exists(select 1 from workforce.shifts s where s.person_id=target.id and s.left_at is null) then
    raise exception 'La persona debe registrar la salida antes de eliminar su acceso.' using errcode='22023';
  end if;

  old_hash:=target.identifier_hash;
  old_user:=target.user_id;
  update workforce.people set
    active=false,
    user_id=null,
    contact_email=null,
    supervisor_id=null,
    removed_at=stamp,
    identifier_hash=pg_catalog.md5('workforce-removed-a:'||id::text||':'||stamp::text)
      || pg_catalog.md5('workforce-removed-b:'||id::text||':'||stamp::text)
  where id=target.id;

  return jsonb_build_object(
    'person_id',target.id,
    'identifier_hash',old_hash,
    'user_id',old_user,
    'removed',true
  );
end;
$$;

-- These two helpers can only be called with the server-side secret key. They
-- keep Auth administration outside the browser and link the account at once.
create function workforce.register_auth_user(p_person uuid,p_user uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare target workforce.people; auth_email text;
begin
  select * into target from workforce.people
    where id=p_person and active and removed_at is null for update;
  select lower(u.email) into auth_email from auth.users u
    where u.id=p_user and u.email_confirmed_at is not null;
  if target.id is null or target.user_id is not null or auth_email is distinct from
    target.identifier_hash||'@identidad.trefielectric.internal' then
    raise exception 'No pudimos vincular el acceso con la persona.' using errcode='22023';
  end if;
  update workforce.people set user_id=p_user where id=target.id;
  return true;
end;
$$;

create function workforce.find_auth_user(p_identifier_hash text) returns uuid
language sql stable security definer set search_path='' as $$
  select u.id from auth.users u
  where lower(u.email)=p_identifier_hash||'@identidad.trefielectric.internal'
  limit 1
$$;

create function public.workforce_register_auth_user(p_person uuid,p_user uuid) returns boolean
language sql security invoker set search_path='' as $$
  select workforce.register_auth_user(p_person,p_user)
$$;

create function public.workforce_find_auth_user(p_identifier_hash text) returns uuid
language sql stable security invoker set search_path='' as $$
  select workforce.find_auth_user(p_identifier_hash)
$$;

create function public.workforce_remove_person(p_id uuid) returns jsonb
language sql security invoker set search_path='' as $$
  select workforce.remove_person(p_id)
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
      from workforce.people p where p.removed_at is null and authenticated and (manage_people or (view_team and p.supervisor_id=actor.id))),'[]'::jsonb),
    'shifts',coalesce((select jsonb_agg(to_jsonb(s) order by s.arrived_at desc) from workforce.shifts s join workforce.people p on p.id=s.person_id
      where ((p.id=actor.id and workforce.has_permission(actor,'attendance_view_own')) or (authenticated and view_team_attendance and (manage_people or p.supervisor_id=actor.id)))
      and ((s.arrived_at<end_at and coalesce(s.left_at,stamp)>=start_at) or (day=today and s.left_at is null))),'[]'::jsonb),
    'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.due_at nulls last,t.created_at,t.id) from workforce.tasks t join workforce.people p on p.id=t.person_id
      where t.scheduled_on=day and ((p.id=actor.id and workforce.has_permission(actor,'tasks_view_own')) or (authenticated and view_team_tasks and (manage_people or p.supervisor_id=actor.id)))),'[]'::jsonb)
  );
end;
$$;

revoke execute on function workforce.remove_person(uuid) from public,anon,authenticated;
grant execute on function workforce.remove_person(uuid) to authenticated;
revoke all on function public.workforce_remove_person(uuid) from public,anon;
grant execute on function public.workforce_remove_person(uuid) to authenticated;
revoke all on function public.workforce_register_auth_user(uuid,uuid),public.workforce_find_auth_user(text)
  from public,anon,authenticated;
revoke execute on function workforce.register_auth_user(uuid,uuid),workforce.find_auth_user(text)
  from public,anon,authenticated;
grant execute on function workforce.register_auth_user(uuid,uuid),workforce.find_auth_user(text)
  to service_role;
grant execute on function public.workforce_register_auth_user(uuid,uuid),public.workforce_find_auth_user(text)
  to service_role;
