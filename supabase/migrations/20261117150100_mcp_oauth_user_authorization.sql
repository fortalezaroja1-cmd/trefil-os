-- OAuth-backed MCP access. Each AI client acts as the signed-in workforce
-- member and receives only the tools allowed by that member's effective
-- permissions (role plus per-person overrides).

insert into workforce.permissions(code,name,description,category,module,sort_order)
values (
  'ai_connect',
  'Conectar asistentes de IA',
  'Conectar ChatGPT u otro cliente MCP para trabajar únicamente con las funciones autorizadas.',
  'personal',
  'integrations',
  140
)
on conflict (code) do update set
  name=excluded.name,
  description=excluded.description,
  category=excluded.category,
  module=excluded.module,
  sort_order=excluded.sort_order;

update workforce.permissions
set module='integrations'
where code='integrations_manage';

insert into workforce.role_permissions(role_code,permission_code)
values ('admin','ai_connect')
on conflict do nothing;

create or replace function developer.require_manager() returns workforce.people
language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person();
begin
  if not workforce.has_permission(actor,'integrations_manage') then
    raise exception 'Se requiere permiso para administrar integraciones.' using errcode='42501';
  end if;
  return actor;
end;
$$;

create function developer.require_oauth_actor(p_permission text default null)
returns workforce.people
language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person();
begin
  if not actor.active or not workforce.has_permission(actor,'ai_connect') then
    raise exception 'La cuenta no tiene permiso para conectar asistentes de IA.' using errcode='42501';
  end if;
  if p_permission is not null and not workforce.has_permission(actor,p_permission) then
    raise exception 'La función solicitada no está autorizada para esta cuenta.' using errcode='42501';
  end if;
  return actor;
end;
$$;

create function developer.oauth_profile() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=developer.require_oauth_actor(); permissions jsonb;
begin
  permissions:=workforce.effective_permissions(actor);
  return jsonb_build_object(
    'id',actor.id,
    'name',actor.full_name,
    'job_title',actor.job_title,
    'area',actor.area,
    'role',actor.access_role,
    'permissions',permissions,
    'tools',jsonb_build_array('trefil_get_profile','trefil_system_status')
      || case when permissions ? 'tasks_view_own' then jsonb_build_array('trefil_workforce_today') else '[]'::jsonb end
      || case when permissions ? 'tasks_assign' then jsonb_build_array('trefil_team_targets','trefil_assign_task') else '[]'::jsonb end
  );
end;
$$;

create function developer.oauth_workforce_today() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=developer.require_oauth_actor('tasks_view_own'); stamp timestamptz:=clock_timestamp();
  day date:=(stamp at time zone 'America/Bogota')::date;
begin
  return jsonb_build_object(
    'person',jsonb_build_object('id',actor.id,'name',actor.full_name,'job_title',actor.job_title,'area',actor.area),
    'day',day,
    'server_now',stamp,
    'tasks',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',t.id,'title',t.title,'details',t.details,'due_at',t.due_at,'status',t.status
      ) order by t.due_at nulls last,t.created_at)
      from workforce.tasks t
      where t.person_id=actor.id and t.scheduled_on=day
    ),'[]'::jsonb)
  );
end;
$$;

create function developer.oauth_team_targets() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=developer.require_oauth_actor('tasks_assign');
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.full_name,'job_title',p.job_title,'area',p.area
    ) order by p.full_name)
    from workforce.people p
    where p.active and (actor.access_role='admin' or p.supervisor_id=actor.id)
  ),'[]'::jsonb);
end;
$$;

create function developer.oauth_assign_task(
  p_id uuid,p_person uuid,p_day date,p_time time,p_title text,p_details text
) returns uuid
language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=developer.require_oauth_actor('tasks_assign'); subject workforce.people;
begin
  select * into subject from workforce.people p where p.id=p_person and p.active;
  if subject.id is null or not (actor.access_role='admin' or subject.supervisor_id=actor.id) then
    raise exception 'La persona no pertenece al equipo autorizado.' using errcode='42501';
  end if;
  if p_id is null or p_day is null or not isfinite(p_day)
    or length(btrim(p_title)) not between 2 and 120
    or length(btrim(coalesce(p_details,'')))>1000 then
    raise exception 'Revisa la fecha y el contenido de la tarea.' using errcode='22023';
  end if;
  insert into workforce.tasks(id,person_id,assigned_by,scheduled_on,due_at,title,details)
  values(p_id,subject.id,actor.id,p_day,p_time,btrim(p_title),btrim(coalesce(p_details,'')));
  return p_id;
end;
$$;

create or replace function developer.snapshot() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=developer.require_manager();
begin
  return jsonb_build_object(
    'me',jsonb_build_object('id',actor.id,'full_name',actor.full_name,'job_title',actor.job_title,'area',actor.area,'access_role',actor.access_role),
    'endpoint','https://kifmqoolaerepvlzrqnk.supabase.co/functions/v1/trefil-mcp',
    'oauth_enabled',true,
    'scopes',coalesce((select jsonb_agg(to_jsonb(s) order by s.sort_order) from developer.scopes s),'[]'::jsonb),
    'keys',coalesce((select jsonb_agg(jsonb_build_object(
      'id',k.id,'name',k.name,'token_prefix',k.token_prefix,'scopes',k.scopes,
      'rate_limit_per_minute',k.rate_limit_per_minute,'created_at',k.created_at,
      'expires_at',k.expires_at,'last_used_at',k.last_used_at,'revoked_at',k.revoked_at,
      'calls_24h',(select count(*) from developer.usage_log u where u.key_id=k.id and u.outcome='success' and u.occurred_at>=clock_timestamp()-interval '24 hours')
    ) order by k.created_at desc) from developer.keys k),'[]'::jsonb)
  );
end;
$$;

create function public.developer_oauth_profile() returns jsonb
language sql security invoker set search_path='' as $$ select developer.oauth_profile() $$;
create function public.developer_oauth_workforce_today() returns jsonb
language sql security invoker set search_path='' as $$ select developer.oauth_workforce_today() $$;
create function public.developer_oauth_team_targets() returns jsonb
language sql security invoker set search_path='' as $$ select developer.oauth_team_targets() $$;
create function public.developer_oauth_assign_task(
  p_id uuid,p_person uuid,p_day date,p_time time,p_title text,p_details text
) returns uuid language sql security invoker set search_path='' as $$
  select developer.oauth_assign_task(p_id,p_person,p_day,p_time,p_title,p_details)
$$;

revoke execute on function developer.require_oauth_actor(text),developer.oauth_profile(),
  developer.oauth_workforce_today(),developer.oauth_team_targets(),
  developer.oauth_assign_task(uuid,uuid,date,time,text,text)
from public,anon,authenticated,service_role;

grant execute on function developer.oauth_profile(),developer.oauth_workforce_today(),
  developer.oauth_team_targets(),developer.oauth_assign_task(uuid,uuid,date,time,text,text)
to authenticated;

revoke all on function public.developer_oauth_profile(),public.developer_oauth_workforce_today(),
  public.developer_oauth_team_targets(),public.developer_oauth_assign_task(uuid,uuid,date,time,text,text)
from public,anon;

grant execute on function public.developer_oauth_profile(),public.developer_oauth_workforce_today(),
  public.developer_oauth_team_targets(),public.developer_oauth_assign_task(uuid,uuid,date,time,text,text)
to authenticated;
