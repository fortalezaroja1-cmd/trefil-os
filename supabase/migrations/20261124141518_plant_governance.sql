-- Identity is resolved by Equipo for every request; the browser never supplies an actor.
create schema plant_ops;
revoke all on schema plant_ops from public, anon, authenticated;
alter default privileges in schema plant_ops revoke execute on functions from public;

create table plant_ops.access (
  person uuid primary key references workforce.people(id),
  profile text not null check(profile in ('CREADOR','PRESIDENTE','SOCIO ACCIONISTA','GERENTE','PRODUCCIÓN','VENTAS','BODEGA','GERENTE DE VENTAS','COLABORADOR')),
  rights text[] not null default '{}'
);
create unique index plant_one_creator on plant_ops.access(profile) where profile='CREADOR';
create table plant_ops.records (
  id uuid primary key default gen_random_uuid(),
  series bigint generated always as identity unique,
  kind text not null, title text not null check(length(btrim(title)) between 1 and 220),
  parent uuid references plant_ops.records(id), state text not null default 'abierto',
  data jsonb not null, version integer not null default 1, scope text not null default 'produccion',
  author uuid not null references workforce.people(id), created timestamptz not null default now()
);
create unique index plant_single_order on plant_ops.records(kind) where kind='ot' and state='abierto';
create index plant_children on plant_ops.records(parent,kind,state);
create unique index plant_order_source on plant_ops.records(lower(data->>'op'),upper(data->>'codigo')) where kind='pedido_corte';
create unique index plant_spool_code on plant_ops.records(lower(title)) where kind='carreta';
create unique index plant_invoice_line on plant_ops.records(lower(data->>'proveedor'),lower(data->>'factura'),lower(data->>'partida')) where kind='servicio';
create unique index plant_price_start on plant_ops.records(lower(data->>'lista'),upper(data->>'codigo'),(data->>'vigente')) where kind='precio';
create unique index plant_monthly_close on plant_ops.records((data->>'periodo')) where kind='cierre' and state<>'rechazado';
create table plant_ops.events (
  seq bigint generated always as identity primary key, request uuid unique not null,
  actor uuid not null references workforce.people(id), at_time timestamptz not null default now(),
  area text not null, action text not null, target uuid not null, reason text not null,
  previous jsonb, current_value jsonb, signature text not null
);
create table plant_ops.files (
  record uuid not null references plant_ops.records, version integer not null,
  content bytea not null check(octet_length(content) between 5 and 3145728), primary key(record,version)
);
alter table plant_ops.access enable row level security;
alter table plant_ops.records enable row level security;
alter table plant_ops.events enable row level security;
alter table plant_ops.files enable row level security;
revoke all on all tables in schema plant_ops from public, anon, authenticated;

create function plant_ops.permissions() returns text[] language sql immutable set search_path='' as $$
 select array['planta.ver','planta.registrar','planta.verificar','bodega.recibir','control.ver','control.personas','control.aprobar','control.seguimiento','control.panel','control.proyectos','archivo.ver','archivo.descargar','archivo.editar','control.auditar']
$$;
create function plant_ops.permits(a plant_ops.access, capability text) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(a.profile='CREADOR' or (capability=any(a.rights) and
   (split_part(capability,'.',1) not in ('control','archivo') or a.profile in ('PRESIDENTE','SOCIO ACCIONISTA','GERENTE'))),false)
$$;
create function plant_ops.required(d jsonb, keys text[]) returns void language plpgsql set search_path='' as $$
declare k text;
begin
 foreach k in array keys loop
   if nullif(btrim(d->>k),'') is null then raise exception 'Falta el campo %.',k; end if;
 end loop;
end $$;
create function plant_ops.quantity(d jsonb,k text,allow_zero boolean default false) returns numeric language plpgsql set search_path='' as $$
declare n numeric;
begin
 if coalesce(d->>k,'') !~ '^[0-9]{1,13}([.][0-9]{1,6})?$' then raise exception 'Revisa el valor de %.',k; end if;
 n:=(d->>k)::numeric;
 if not allow_zero and n=0 then raise exception '% debe ser positivo.',k; end if;
 return n;
end $$;
create function plant_ops.stock(code text,warehouse text,operation text,qty numeric,document text,request uuid) returns void language plpgsql set search_path='' as $$
declare rev bigint;
begin
 execute 'select revision from inventory_hub.balances where code=$1 and warehouse=$2' into rev using upper(btrim(code)),upper(btrim(warehouse));
 if rev is null or rev=0 then raise exception 'Inventarios debe verificar el código físico y registrar el conteo de apertura en esa bodega.'; end if;
 execute 'select public.central_inventory_record($1,$2,$3,$4,$5,$6,$7)' using upper(btrim(code)),upper(btrim(warehouse)),operation,qty,document,rev,request;
end $$;
create function plant_ops.material_plan(lines jsonb) returns jsonb language sql immutable set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(m) order by m.codigo,m.unidad),'[]') from (
   select upper(trim(b->>'codigo')) codigo,b->>'unidad' unidad,
     sum((b->>'cantidad')::numeric*(l->>'cantidad')::numeric) cantidad,
     sum((b->>'cantidad')::numeric*(l->>'cantidad')::numeric*(b->>'costo')::numeric) costo
   from jsonb_array_elements(lines) l cross join lateral jsonb_array_elements(coalesce(l#>'{fichaTecnica,formula}','[]')) b
   group by 1,2) m
$$;
create function plant_ops.snapshot(area text) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; result jsonb; people jsonb:='[]'; history jsonb:='[]';
begin
 select * into a from plant_ops.access where person=actor.id;
 if area not in ('produccion','control') or area is null or not plant_ops.permits(a,case area when 'control' then 'control.ver' else 'planta.ver' end)
   then raise exception 'Tu perfil no tiene acceso a este módulo.' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(r) order by r.series desc),'[]') into result from plant_ops.records r where
   (area='produccion' and r.scope='produccion') or
   (area='control' and case r.kind
      when 'caso' then plant_ops.permits(a,'control.aprobar') or plant_ops.permits(a,'control.seguimiento')
      when 'proyecto' then plant_ops.permits(a,'control.proyectos')
      when 'expediente' then plant_ops.permits(a,'archivo.ver') and (r.data->>'nivel'<>'CREADOR' or a.profile='CREADOR')
      else false end);
 if area='control' and plant_ops.permits(a,'control.personas') then
   select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nombre',p.full_name,'activo',p.active,'perfil',x.profile,'permisos',x.rights) order by p.full_name),'[]')
     into people from workforce.people p left join plant_ops.access x on x.person=p.id where p.removed_at is null;
 end if;
 if area='control' and plant_ops.permits(a,'control.auditar') then
   select coalesce(jsonb_agg(to_jsonb(e) order by seq desc),'[]') into history from
    (select e.seq,e.at_time,p.full_name as actor,e.action,e.target,e.reason from plant_ops.events e
       join workforce.people p on p.id=e.actor where not exists(select 1 from plant_ops.records r where r.id=e.target and r.kind='expediente'
          and (not plant_ops.permits(a,'archivo.ver') or r.data->>'nivel'='CREADOR' and a.profile<>'CREADOR'))
       order by seq desc limit 300) e;
 end if;
 return jsonb_build_object('persona',actor.id,'nombre',actor.full_name,'perfil',a.profile,'permisos',
   case when a.profile='CREADOR' then plant_ops.permissions() else a.rights end,'opciones',plant_ops.permissions(),
   'registros',result,'personas',people,'auditoria',history,'corte',now(),
   'panel',case when area='control' and plant_ops.permits(a,'control.panel') then
     (select jsonb_build_object('OT abiertas',count(*) filter(where kind='ot' and state='abierto'),
       'Entregas aceptadas',count(*) filter(where kind='entrega' and state='aceptado'),
       'Novedades abiertas',count(*) filter(where kind='caso' and state in ('pendiente','en revisión'))) from plant_ops.records) end);
end $$;

create function plant_ops.command(area text, action text, target uuid, expected integer, body jsonb, reason text, request uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; prior plant_ops.events;
 r plant_ops.records; parent_row plant_ops.records; original jsonb; next_data jsonb; old_access plant_ops.access;
 k text; right_needed text; subject uuid; linked uuid; required_qty numeric; qty numeric; used numeric; rev bigint;
 entry jsonb; item plant_ops.records; lines jsonb:='[]'; sku text; step text; number_label bigint;
 stamp text:=md5(jsonb_build_array(area,action,target,expected,body,reason)::text); content bytea; allowed text[];
begin
 if area is null or area not in ('produccion','control') or request is null or target is null or
    jsonb_typeof(body) is distinct from 'object' or length(body::text)>4300000 or coalesce(length(btrim(reason)),0) not between 2 and 1500 then raise exception 'Revisa los datos, el motivo y la referencia.'; end if;
 -- Serialize transitions, grants, consecutive labels and idempotent retries for this company.
 perform pg_advisory_xact_lock(727714,710);
 select * into a from plant_ops.access where person=actor.id;
 if not plant_ops.permits(a,case area when 'control' then 'control.ver' else 'planta.ver' end) then raise exception 'Acceso restringido.' using errcode='42501'; end if;
 select * into prior from plant_ops.events e where e.request=command.request;
 if found then
   if prior.actor<>actor.id or prior.signature<>stamp then raise exception 'Solicitud en conflicto.'; end if;
   return prior.target;
 end if;
 select * into r from plant_ops.records t where t.id=target for update;
 original:=case when r.id is not null then to_jsonb(r) end;
 if action='acceso' then
   if area<>'control' or a.profile<>'CREADOR' then raise exception 'Solo CREADOR asigna los perfiles de gobierno.' using errcode='42501'; end if;
   select * into old_access from plant_ops.access where person=target;
   if old_access.profile='CREADOR' or body->>'perfil'='CREADOR' or not exists(select from workforce.people p where p.id=target and p.removed_at is null)
      then raise exception 'Selecciona otra persona del equipo.'; end if;
   perform plant_ops.required(body,array['perfil','permisos']);
   select array(select jsonb_array_elements_text(body->'permisos')) into allowed;
   if not allowed <@ plant_ops.permissions() then raise exception 'Permiso desconocido.'; end if;
   original:=to_jsonb(old_access);
   insert into plant_ops.access(person,profile,rights) values(target,body->>'perfil',allowed)
     on conflict(person) do update set profile=excluded.profile,rights=excluded.rights;
   next_data:=body;
 else
   k:=case when action='crear' then body->>'tipo' else r.kind end;
   if k is null or k not in ('ficha','ot','rotulo','lote','carreta','pedido_corte','corte','traslado','entrega','recuperacion','servicio','conteo','costo','garantia','precio','cierre','caso','proyecto','expediente')
     then raise exception 'Tipo de registro inválido.'; end if;
   if area='produccion' and (k in ('proyecto','expediente') or r.scope='control') or area='control' and k not in ('caso','proyecto','expediente') then raise exception 'Módulo incorrecto.'; end if;
   right_needed:=case when k='expediente' then 'archivo.editar' when k='proyecto' then 'control.proyectos'
     when action in ('aprobar','rechazar') and area='control' then 'control.aprobar'
     when k='caso' and area='control' then 'control.seguimiento' when action='recibir' then 'bodega.recibir'
     when action in ('verificar','cerrar') then 'planta.verificar' else 'planta.registrar' end;
   if not plant_ops.permits(a,right_needed) or
     (k='expediente' and (not plant_ops.permits(a,'archivo.ver') or
        (r.data->>'nivel'='CREADOR' or body->>'nivel'='CREADOR') and a.profile<>'CREADOR')) then
     raise exception 'Tu perfil no autoriza esta acción.' using errcode='42501'; end if;
   if action='crear' then
     if r.id is not null then raise exception 'El registro ya existe.'; end if;
     perform plant_ops.required(body,array['titulo']);
     if body ?| array['numero','despachado','primerConteo','recibido','receptor','verificado','cierre','autor','reapertura','necesidades','versiones'] then raise exception 'Hay campos reservados al sistema.'; end if;
     next_data:=body-array['tipo','titulo','padre','archivo'];
     -- Persist only the fields defined by this document. Calculated balances,
     -- historical versions and supervisor decisions are always server-owned.
     allowed:=case k
       when 'ficha' then array['codigo','unidad','presentacion','origen','ruta','materiales','formula']
       when 'ot' then array['acta','lineas']
       when 'rotulo' then array['ficha','categoria','cantidad','ubicacion','unidad']
       when 'traslado' then array['destino','cantidad','soporte']
       when 'carreta' then array['metros'] when 'pedido_corte' then array['op','codigo','metros','soporte']
       when 'corte' then array['pedido','metros','soporte']
       when 'lote' then array['ficha','soporte','rotulos','compra']
       when 'entrega' then array['ficha','cantidad','bodega','soporte','lote']
       when 'recuperacion' then array['factura','material','destino','facturado','fisico','sinPesaje']
       when 'servicio' then array['proveedor','factura','partida','vencimiento','valor','soporte']
       when 'conteo' then array['ubicacion','codigo','clase','soporte','fisico','teorico']
       when 'costo' then array['codigo','periodo','base','teorico','real','soporte']
       when 'garantia' then array['factura','codigo','familia','medida','cantidad','pagado','origen','dictamen','destino']
       when 'precio' then array['lista','codigo','precio','vigente']
       when 'cierre' then array['periodo','soporte']
       when 'caso' then array['origen','documento','responsable','soporte']
       when 'proyecto' then array['objetivo','responsable','fecha','supuestos','presupuesto']
       when 'expediente' then array['asunto','nivel','fecha','responsable'] end;
     if exists(select from jsonb_object_keys(next_data) key where not key=any(allowed)) then raise exception 'Campo no válido para este documento.'; end if;
     linked:=nullif(body->>'padre','')::uuid;
     if linked is not null then select * into strict parent_row from plant_ops.records where id=linked; end if;
     if k='ficha' then
       perform plant_ops.required(body,array['codigo','unidad','presentacion','materiales','ruta']);
       if lower(split_part(body->>'ruta',E'\n',1)) not like 'recuperaci%' and body->>'origen' is distinct from 'Comprado terminado' then raise exception 'La ruta interna comienza en Recuperación.'; end if;
       if exists(select from plant_ops.records t where t.kind='ficha' and lower(t.data->>'codigo')=lower(body->>'codigo')) then raise exception 'Ya existe ficha con este código.'; end if;
       for entry in select value from jsonb_array_elements(coalesce(body->'formula','[]')) loop
         perform plant_ops.required(entry,array['codigo','unidad']);perform plant_ops.quantity(entry,'cantidad');perform plant_ops.quantity(entry,'costo',true);
       end loop;
     elsif k='ot' then
       perform plant_ops.required(body,array['acta','lineas']);
       if jsonb_typeof(body->'lineas') is distinct from 'array' or jsonb_array_length(body->'lineas')=0 then raise exception 'Agrega referencias a la OT.'; end if;
       for entry in select value from jsonb_array_elements(body->'lineas') loop
         select * into strict item from plant_ops.records where id=(entry->>'ficha')::uuid and kind='ficha';
         perform plant_ops.required(entry,array['fecha','responsable','prioridad']); perform (entry->>'fecha')::date;
         perform plant_ops.quantity(entry,'cantidad');
         if entry->>'prioridad' not in ('Alta','Media','Baja') or lines @> jsonb_build_array(jsonb_build_object('ficha',item.id)) then raise exception 'Revisa referencias y prioridades.'; end if;
         lines:=lines||jsonb_build_array(entry||jsonb_build_object('ficha',item.id,'version',item.version,'fichaTecnica',item.data,'verificado',false));
       end loop;
       next_data:=jsonb_set(next_data,'{lineas}',lines)||jsonb_build_object('necesidades',plant_ops.material_plan(lines));
     elsif k='lote' then
       if parent_row.kind is distinct from 'ot' or parent_row.state<>'abierto' then raise exception 'Selecciona una OT abierta.'; end if;
       select value into strict entry from jsonb_array_elements(parent_row.data->'lineas') where value->>'ficha'=body->>'ficha';
       if (entry->>'verificado')::boolean is not true then raise exception 'Verifica primero el checklist de la referencia.'; end if;
       if entry#>>'{fichaTecnica,origen}'='Comprado terminado' then perform plant_ops.required(body,array['compra']);
       elsif exists(select from jsonb_array_elements_text(coalesce(body->'rotulos','[]')) t(id)
         where not exists(select from plant_ops.records x where x.kind='rotulo' and x.parent=linked and x.data->>'ficha'=body->>'ficha' and x.id=t.id::uuid)) then raise exception 'Rótulo incompatible con la referencia.'; end if;
       select count(*)+1 into number_label from plant_ops.records where kind='lote';
       next_data:=next_data||jsonb_build_object('numero',number_label);
     elsif k='traslado' then
       if parent_row.kind is distinct from 'rotulo' or parent_row.state<>'abierto' then raise exception 'Selecciona un rótulo abierto.'; end if;
       perform plant_ops.required(body,array['destino','soporte']); perform plant_ops.quantity(body,'cantidad');
       if (body->>'cantidad')::numeric>(parent_row.data->>'cantidad')::numeric then raise exception 'Cantidad mayor que el rótulo.'; end if;
       if exists(select from plant_ops.records where parent=linked and kind='traslado' and state<>'aceptado') then raise exception 'Ya hay un traslado pendiente.'; end if;
       next_data:=next_data||jsonb_build_object('origen',parent_row.data->>'ubicacion');
     elsif k='carreta' then
       if parent_row.kind is distinct from 'entrega' or parent_row.state<>'aceptado' then raise exception 'Selecciona una entrega aceptada.'; end if;
       qty:=plant_ops.quantity(body,'metros');
       if not exists(select from plant_ops.records f where f.id=(parent_row.data->>'ficha')::uuid and lower(f.data->>'unidad') in ('m','metro','metros')) then raise exception 'La referencia debe estar medida en metros.'; end if;
       select coalesce(sum((data->>'metros')::numeric),0) into used from plant_ops.records where parent=linked and kind=k;
       if qty+used>(parent_row.data->>'cantidad')::numeric then raise exception 'Los metros superan la entrega.'; end if;
       next_data:=next_data||jsonb_build_object('codigo',parent_row.data->>'codigo','bodega',parent_row.data->>'bodega');
     elsif k='pedido_corte' then
       if a.profile not in ('CREADOR','VENTAS','GERENTE DE VENTAS') then raise exception 'Ventas confirma la OP de origen.'; end if;
       perform plant_ops.required(body,array['op','codigo','soporte']); perform plant_ops.quantity(body,'metros');
     elsif k='corte' then
       if parent_row.kind is distinct from 'carreta' or parent_row.state<>'abierto' then raise exception 'Selecciona una carreta abierta.'; end if;
       select * into strict item from plant_ops.records where id=(body->>'pedido')::uuid and kind='pedido_corte' and state='abierto' and upper(data->>'codigo')=upper(parent_row.data->>'codigo');
       qty:=plant_ops.quantity(body,'metros');
       select coalesce(sum(coalesce(data->>'despachado',data->>'metros')::numeric),0) into used from plant_ops.records where parent=linked and kind='corte';
       if used+qty>(parent_row.data->>'metros')::numeric then raise exception 'La carreta tiene menos metros disponibles.'; end if;
       select coalesce(sum(coalesce(data->>'despachado',data->>'metros')::numeric),0) into used from plant_ops.records where kind='corte' and data->>'pedido'=item.id::text;
       if used+qty>(item.data->>'metros')::numeric then raise exception 'Excede los metros confirmados para la OP.'; end if;
       perform plant_ops.stock(parent_row.data->>'codigo',parent_row.data->>'bodega','reserva',qty,'CORTE-'||target,request);
       next_data:=next_data||jsonb_build_object('codigo',parent_row.data->>'codigo','bodega',parent_row.data->>'bodega');
     elsif k in ('rotulo','entrega') then
       if parent_row.kind is distinct from 'ot' or parent_row.state<>'abierto' then raise exception 'Selecciona la OT abierta.'; end if;
       select value into strict entry from jsonb_array_elements(parent_row.data->'lineas') where value->>'ficha'=body->>'ficha';
       qty:=plant_ops.quantity(body,'cantidad');
       if k='rotulo' then
         if coalesce(body->>'categoria','') not in ('Alambre Eco','Alambre Plus','Alambre Desnudo','Cable 7 Hilos','Cobre para Pinos','Aluminio') then raise exception 'Categoría de rótulo inválida.'; end if;
         select coalesce(max((data->>'numero')::bigint),0)+1 into number_label from plant_ops.records where kind='rotulo' and data->>'categoria'=body->>'categoria';
         next_data:=next_data||jsonb_build_object('numero',number_label);
       else
         select * into strict item from plant_ops.records where kind='lote' and state='abierto' and parent=linked and id=(body->>'lote')::uuid and data->>'ficha'=body->>'ficha';
         if (entry->>'verificado')::boolean is not true then raise exception 'Verifica primero el checklist del producto.'; end if;
         perform plant_ops.required(body,array['bodega','soporte']);
         select coalesce(sum((data->>'cantidad')::numeric),0) into used from plant_ops.records where kind='entrega' and parent=linked and data->>'ficha'=body->>'ficha';
         if used+qty>(entry->>'cantidad')::numeric then raise exception 'La entrega supera lo programado.'; end if;
         next_data:=next_data||jsonb_build_object('codigo',entry#>>'{fichaTecnica,codigo}');
       end if;
     elsif k='recuperacion' then
       perform plant_ops.required(body,array['factura','material','destino']); perform plant_ops.quantity(body,'facturado');
       if nullif(body->>'fisico','') is null then perform plant_ops.required(body,array['sinPesaje']);
       else perform plant_ops.quantity(body,'fisico',true); end if;
     elsif k='servicio' then
       perform plant_ops.required(body,array['proveedor','factura','partida','vencimiento']); perform plant_ops.quantity(body,'valor');
     elsif k='conteo' then
       perform plant_ops.required(body,array['ubicacion','codigo','clase','soporte']);
       perform plant_ops.quantity(body,'fisico',true); perform plant_ops.quantity(body,'teorico',true);
     elsif k='costo' then
       perform plant_ops.required(body,array['codigo','periodo','base']);
       perform plant_ops.quantity(body,'teorico',true); perform plant_ops.quantity(body,'real',true);
     elsif k='garantia' then
       perform plant_ops.required(body,array['factura','codigo','medida','origen','dictamen','destino']);
       perform plant_ops.quantity(body,'cantidad'); perform plant_ops.quantity(body,'pagado',true);
       if body->>'familia'='Cable 7 Hilos dañado' and body->>'destino'<>'Chatarra' then raise exception 'Cable 7 Hilos dañado se clasifica como chatarra.'; end if;
     elsif k='precio' then
       if a.profile not in ('CREADOR','GERENTE','GERENTE DE VENTAS') then raise exception 'Se requiere autorización comercial.'; end if;
       perform plant_ops.required(body,array['lista','codigo','vigente']); perform (body->>'vigente')::date; perform plant_ops.quantity(body,'precio',true);
     elsif k='cierre' then perform plant_ops.required(body,array['periodo','soporte']);
     elsif k='caso' then perform plant_ops.required(body,array['origen','documento','responsable']);
     elsif k='proyecto' then
       perform plant_ops.required(body,array['objetivo','responsable','fecha','supuestos']); perform plant_ops.quantity(body,'presupuesto',true);
     elsif k='expediente' then
       perform plant_ops.required(body,array['asunto','nivel','fecha','responsable','archivo']);
       if body->>'nivel' not in ('Dirección','CREADOR') then raise exception 'Nivel de acceso inválido.'; end if;
     end if;
     if k='expediente' then
       content:=decode(body->>'archivo','base64');
       if substring(content for 5)<>convert_to('%PDF-','UTF8') then raise exception 'Adjunta un PDF válido.'; end if;
     end if;
     insert into plant_ops.records(id,kind,title,parent,state,data,author,scope)
      values(target,k,btrim(body->>'titulo'),linked,case when k in ('caso','garantia','cierre') then 'pendiente' else 'abierto' end,next_data,actor.id,area) returning * into r;
     if k='expediente' then insert into plant_ops.files values(target,1,content); end if;
     if (k='recuperacion' and nullif(body->>'fisico','')::numeric<>(body->>'facturado')::numeric) or
        (k='conteo' and (body->>'fisico')::numeric<>(body->>'teorico')::numeric) then
       insert into plant_ops.records(kind,title,parent,state,data,author) values('caso','Diferencia · '||r.title,r.id,'pendiente',
          jsonb_build_object('origen','Producción','documento',r.series,'responsable','Gerencia','hecho',next_data),actor.id);
     end if;
   else
     if r.id is null or expected is distinct from r.version then raise exception 'El registro cambió. Actualiza la vista.'; end if;
     if r.state in ('cerrado','aceptado','rechazado','aprobado') and action<>'reabrir' then raise exception 'El registro está cerrado.'; end if;
     case action
     when 'verificar' then
       if k<>'ot' or a.profile not in ('CREADOR','PRODUCCIÓN') then raise exception 'Verificación reservada a Producción.'; end if;
       select value into strict entry from jsonb_array_elements(r.data->'lineas') where value->>'ficha'=body->>'ficha';
       if body->>'ruta' is distinct from entry#>>'{fichaTecnica,ruta}' then raise exception 'Completa la verificación de todas las etapas.'; end if;
       select jsonb_agg(case when e->>'ficha'=body->>'ficha' then e||jsonb_build_object('verificado',true,'verificador',actor.id) else e end order by pos)
         into lines from jsonb_array_elements(r.data->'lineas') with ordinality v(e,pos);
       r.data:=jsonb_set(r.data,'{lineas}',lines);
     when 'recibir' then
       if k not in ('entrega','traslado') or r.author=actor.id or (k='entrega' and a.profile not in ('CREADOR','BODEGA','VENTAS')) then raise exception 'El área receptora debe confirmar con otra cuenta.'; end if;
       if k='traslado' and actor.area is distinct from r.data->>'destino' then raise exception 'Tu área no es el destino del traslado.'; end if;
       qty:=plant_ops.quantity(body,'recibido',true);
       r.data:=r.data||jsonb_build_object('primerConteo',coalesce(r.data->'primerConteo',to_jsonb(qty)),'recibido',qty,'receptor',actor.id);
       if qty<>(r.data->>'cantidad')::numeric then
         r.state:='diferencia';
         if not exists(select from plant_ops.records where parent=r.id and kind='caso') then
           insert into plant_ops.records(kind,title,parent,state,data,author) values('caso','Diferencia en entrega '||r.series,r.id,'pendiente',jsonb_build_object('origen','Producción','documento',r.series,'responsable','Gerencia','primerConteo',qty),actor.id);
         end if;
       else
         if k='entrega' then
           perform plant_ops.stock(r.data->>'codigo',r.data->>'bodega','entrada',qty,'PROD-ENT-'||r.series,request);
         else
           update plant_ops.records set data=jsonb_set(data,'{ubicacion}',r.data->'destino'),version=version+1 where id=r.parent and state='abierto';
         end if;
         r.state:='aceptado';
       end if;
     when 'despachar' then
       if k<>'corte' or a.profile not in ('CREADOR','VENTAS','BODEGA') then raise exception 'Despacho reservado a Bodega o Ventas.'; end if;
       qty:=plant_ops.quantity(body,'real'); required_qty:=(r.data->>'metros')::numeric;
       if qty<>required_qty then
         if r.state<>'autorizado' or qty is distinct from (r.data->>'real')::numeric then
           if r.state in ('diferencia','autorizado') then raise exception 'Revisa el caso abierto y los metros autorizados.'; end if;
           insert into plant_ops.records(kind,title,parent,state,data,author) values('caso','Diferencia de corte '||r.series,r.id,'pendiente',jsonb_build_object('origen','Producción','documento',r.series,'responsable','Gerencia','real',qty),actor.id);
           r.data:=r.data||jsonb_build_object('real',qty);r.state:='diferencia';
         end if;
       elsif r.state='diferencia' then raise exception 'Gerencia debe resolver el caso.'; end if;
       if r.state<>'diferencia' then
         if r.state='autorizado' and (r.data->>'real')::numeric<>qty then raise exception 'Los metros difieren de la decisión autorizada.'; end if;
         if qty>required_qty then
           select * into strict parent_row from plant_ops.records where id=r.parent;
           select coalesce(sum(coalesce(data->>'despachado',data->>'metros')::numeric),0) into used from plant_ops.records where parent=r.parent and kind='corte' and id<>r.id;
           if used+qty>(parent_row.data->>'metros')::numeric then raise exception 'Metros insuficientes en la carreta.'; end if;
           perform plant_ops.stock(r.data->>'codigo',r.data->>'bodega','reserva',qty-required_qty,'EXCESO-'||r.id,gen_random_uuid());
           perform plant_ops.stock(r.data->>'codigo',r.data->>'bodega','despacho',qty-required_qty,'EXCESO-'||r.id,gen_random_uuid());
         elsif qty<required_qty then perform plant_ops.stock(r.data->>'codigo',r.data->>'bodega','liberacion',required_qty-qty,'CORTE-'||r.id,gen_random_uuid()); end if;
         perform plant_ops.stock(r.data->>'codigo',r.data->>'bodega','despacho',least(qty,required_qty),'CORTE-'||r.id,request);
         r.data:=r.data||jsonb_build_object('despachado',qty);r.state:='aceptado';
       end if;
     when 'aprobar','rechazar' then
       if k not in ('cierre','caso','garantia') or a.profile not in ('CREADOR','GERENTE') and not(k='garantia' and a.profile='GERENTE DE VENTAS')
         then raise exception 'Se requiere el autorizador competente.'; end if;
       if r.author=actor.id then raise exception 'Se requiere una segunda persona autorizada.'; end if;
       if k='caso' and r.parent is not null and exists(select from plant_ops.records where id=r.parent and kind='entrega' and state<>'aceptado') and action='aprobar' then raise exception 'Concilia primero la recepción en Bodega.'; end if;
       if k='cierre' and action='aprobar' and exists(select from plant_ops.records t where t.kind='caso' and t.scope='produccion' and to_char(t.created at time zone 'America/Bogota','YYYY-MM')=r.data->>'periodo' and t.state not in ('aprobado','rechazado')) then raise exception 'Concilia las novedades del período.'; end if;
       if k='caso' and r.parent is not null then
         update plant_ops.records set state=case action when 'aprobar' then 'autorizado' else 'abierto' end,version=version+1 where id=r.parent and kind='corte' and state='diferencia';
       end if;
       r.state:=case action when 'aprobar' then 'aprobado' else 'rechazado' end;
     when 'reabrir' then
       if a.profile<>'CREADOR' or not ((r.state='cerrado' and k in ('rotulo','ot','recuperacion','lote') or r.state='aprobado' and k='cierre')) then raise exception 'La reapertura corresponde al CREADOR sobre un cierre conciliado.'; end if;
       if k in ('rotulo','lote') and not exists(select from plant_ops.records where id=r.parent and state='abierto') then raise exception 'Reabre primero la OT.'; end if;
       r.state:=case k when 'cierre' then 'pendiente' else 'abierto' end;
     when 'cerrar' then
       if k not in ('rotulo','ot','recuperacion','proyecto','carreta','lote') then raise exception 'Este registro sigue otro flujo de cierre.'; end if;
       if k='carreta' then
         select coalesce(sum((data->>'despachado')::numeric),0) into used from plant_ops.records where parent=r.id and kind='corte';
         if exists(select from plant_ops.records where parent=r.id and state<>'aceptado') or plant_ops.quantity(body,'saldo',true)<>0 or used<>(r.data->>'metros')::numeric then raise exception 'Concilia todos los cortes y el saldo real antes de cerrar la carreta.'; end if;
       elsif k='lote' then
         if not exists(select from plant_ops.records where data->>'lote'=r.id::text and state='aceptado') or exists(select from plant_ops.records where data->>'lote'=r.id::text and state<>'aceptado') then raise exception 'Bodega debe aceptar todas las entregas del lote.'; end if;
       elsif k='ot' and exists(select from plant_ops.records where parent=r.id and kind='lote' and state<>'cerrado') then raise exception 'Cierra los lotes pendientes.'; end if;
       if k='rotulo' and exists(select from plant_ops.records where parent=r.id and kind='traslado' and state<>'aceptado') then raise exception 'Concilia los traslados del rótulo.'; end if;
       if k='ot' and exists(select from plant_ops.records x where x.parent=r.id and ((x.kind='entrega' and x.state<>'aceptado') or (x.kind='rotulo' and x.state<>'cerrado') or exists(select from plant_ops.records c where c.parent=x.id and c.kind='caso' and c.state not in ('aprobado','rechazado')))) then raise exception 'Concilia los rótulos, novedades y entregas pendientes.'; end if;
       if k='ot' then
         for entry in select value from jsonb_array_elements(r.data->'lineas') loop
           select coalesce(sum((data->>'cantidad')::numeric),0) into used from plant_ops.records where parent=r.id and kind='entrega' and data->>'ficha'=entry->>'ficha';
           if used<(entry->>'cantidad')::numeric and nullif(btrim(body->'faltantes'->>(entry->>'ficha')),'') is null then raise exception 'Justifica el pendiente de cada referencia.'; end if;
         end loop;
       end if;
       if k in ('rotulo','recuperacion') then
         perform plant_ops.required(body,array['unidad','destinos','soporte']);
         required_qty:=coalesce(nullif(r.data->>'fisico',''),r.data->>'cantidad')::numeric;
         if required_qty is null or plant_ops.quantity(body,'conciliado',true)<>required_qty then raise exception 'Concilia la cantidad física y sus destinos en la misma unidad.'; end if;
       end if;
       if exists(select from plant_ops.records x where x.parent=r.id and x.kind='caso' and x.state not in ('aprobado','rechazado')) then raise exception 'Hay novedades pendientes.'; end if;
       r.data:=r.data||jsonb_build_object('cierre',body); r.state:='cerrado';
     when 'seguimiento' then
       if k not in ('proyecto','caso','ficha','expediente','ot') then raise exception 'Acción inválida.'; end if;
       if k='ficha' then
         if a.profile<>'CREADOR' then raise exception 'Cambiar la ficha requiere CREADOR.'; end if;
         perform plant_ops.required(body,array['ruta','materiales']);
         if r.data->>'origen' is distinct from 'Comprado terminado' and lower(body->>'ruta') not like 'recuperaci%' then raise exception 'La ruta inicia en Recuperación.'; end if;
         r.data:=r.data||jsonb_build_object('ruta',body->>'ruta','materiales',body->>'materiales');
         if body ? 'formula' then
           for entry in select value from jsonb_array_elements(body->'formula') loop
             perform plant_ops.required(entry,array['codigo','unidad']);perform plant_ops.quantity(entry,'cantidad');perform plant_ops.quantity(entry,'costo',true);
           end loop;
           r.data:=jsonb_set(r.data,'{formula}',body->'formula');
         end if;
       elsif k='ot' then
         if a.profile not in ('CREADOR','PRODUCCIÓN') then raise exception 'Reprogramación reservada a Producción.'; end if;
         select value into strict entry from jsonb_array_elements(r.data->'lineas') where value->>'ficha'=body->>'ficha';
         qty:=plant_ops.quantity(body,'cantidad'); perform plant_ops.required(body,array['prioridad','responsable','fecha']); perform (body->>'fecha')::date;
         if body->>'prioridad' not in ('Alta','Media','Baja') or qty<(select coalesce(sum((data->>'cantidad')::numeric),0) from plant_ops.records where parent=r.id and kind='entrega' and data->>'ficha'=body->>'ficha') then raise exception 'Revisa la cantidad comprometida o prioridad.'; end if;
         select jsonb_agg(case when e->>'ficha'=body->>'ficha' then e||jsonb_build_object('cantidad',qty,'prioridad',body->>'prioridad','fecha',body->>'fecha','responsable',body->>'responsable','verificado',false) else e end order by pos) into lines from jsonb_array_elements(r.data->'lineas') with ordinality v(e,pos);
         r.data:=jsonb_set(r.data,'{lineas}',lines)||jsonb_build_object('necesidades',plant_ops.material_plan(lines));
       elsif k='expediente' then
         content:=decode(body->>'archivo','base64'); if substring(content for 5)<>convert_to('%PDF-','UTF8') then raise exception 'PDF inválido.'; end if;
         insert into plant_ops.files values(r.id,r.version+1,content);
       else
         if k='proyecto' then perform plant_ops.quantity(body,'ejecutado',true); perform plant_ops.required(body,array['supuestos']); end if;
         perform plant_ops.required(body,array['seguimiento','responsable']);
         r.data:=r.data||jsonb_build_object('seguimiento',body->>'seguimiento','responsable',body->>'responsable');
         if k='proyecto' then r.data:=r.data||jsonb_build_object('ejecutado',body->>'ejecutado','supuestos',body->>'supuestos'); else r.state:='en revisión'; end if;
       end if;
     else raise exception 'Acción desconocida.';
     end case;
     update plant_ops.records t set data=r.data,state=r.state,version=t.version+1 where t.id=r.id returning * into r;
   end if;
   next_data:=to_jsonb(r);
 end if;
 insert into plant_ops.events(request,actor,area,action,target,reason,previous,current_value,signature)
   values(request,actor.id,area,action,target,reason,original,next_data,stamp);
 return target;
end $$;

create function plant_ops.download(item uuid, revision integer) returns text language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; payload bytea;
begin
 select * into a from plant_ops.access where person=actor.id;
 if not plant_ops.permits(a,'control.ver') or not plant_ops.permits(a,'archivo.ver') or not plant_ops.permits(a,'archivo.descargar') then raise exception 'Descarga restringida.' using errcode='42501'; end if;
 select f.content into strict payload from plant_ops.files f join plant_ops.records r on r.id=f.record
   where f.record=item and f.version=revision and (r.data->>'nivel'<>'CREADOR' or a.profile='CREADOR');
 insert into plant_ops.events(request,actor,area,action,target,reason,signature) values(gen_random_uuid(),actor.id,'control','descargar',item,'PDF versión '||revision,'download');
 return encode(payload,'base64');
end $$;
create function public.plant_workspace(area text) returns jsonb language sql security invoker set search_path='' as $$select plant_ops.snapshot(area)$$;
create function plant_ops.history(area text,item uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare visible jsonb:=plant_ops.snapshot(area);
begin
 if not exists(select from jsonb_array_elements(visible->'registros') r where r->>'id'=item::text) then raise exception 'Historial restringido.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('fecha',e.at_time,'responsable',p.full_name,'acción',e.action,'motivo',e.reason,'anterior',e.previous,'nuevo',e.current_value) order by e.seq desc)
  from plant_ops.events e join workforce.people p on p.id=e.actor where e.target=item),'[]');
end $$;
create function public.plant_history(area text,item uuid) returns jsonb language sql security invoker set search_path='' as $$select plant_ops.history(area,item)$$;
-- Financial tables keep their own organization, location and MFA policies.
create function public.plant_finance(cutoff date) returns jsonb language plpgsql security invoker set search_path='' as $$
declare ctx jsonb:=plant_ops.snapshot('control'); accounts jsonb; pending jsonb;
begin
 if cutoff is null or cutoff>(now() at time zone 'America/Bogota')::date or not (ctx->'permisos' ? 'control.panel') then raise exception 'Corte o permiso inválido.'; end if;
 select coalesce(jsonb_agg(to_jsonb(q) order by q.cuenta),'[]') into accounts from (
   select a.name cuenta, coalesce(sum(case when t.status='posted' and t.occurred_on<=cutoff then e.debit-e.credit else 0 end),0)::text saldo_cop
   from public.accounts a left join public.transaction_entries e on e.account_id=a.id
   left join public.financial_transactions t on t.id=e.transaction_id
   where a.kind in ('bank','cash','wallet') group by a.id,a.name) q;
 if ctx->'permisos' ? 'control.aprobar' then
   select coalesce(jsonb_agg(jsonb_build_object('id',x.transaction_id,'motivo',x.reason_required,'fecha',x.created_at)),'[]') into pending
   from public.approvals x where x.status='pending' and (x.created_at at time zone 'America/Bogota')::date<=cutoff;
 end if;
 return jsonb_build_object('cuentas',accounts,'pendientes',coalesce(pending,'[]'::jsonb),'corte',cutoff);
end $$;
revoke all on function public.plant_finance(date) from public,anon;
grant execute on function public.plant_finance(date) to authenticated;
create function public.plant_command(area text,action text,target uuid,expected integer,body jsonb,reason text,request uuid)
returns uuid language sql security invoker set search_path='' as $$select plant_ops.command(area,action,target,expected,body,reason,request)$$;
create function public.plant_file(item uuid,revision integer) returns text language sql security invoker set search_path='' as $$select plant_ops.download(item,revision)$$;
revoke all on all functions in schema plant_ops from public,anon,authenticated;
revoke all on function public.plant_history(text,uuid) from public,anon;
grant execute on function public.plant_history(text,uuid),plant_ops.history(text,uuid) to authenticated;
revoke all on function public.plant_workspace(text),public.plant_command(text,text,uuid,integer,jsonb,text,uuid),public.plant_file(uuid,integer) from public,anon;
grant usage on schema plant_ops to authenticated;
grant execute on function plant_ops.snapshot(text),plant_ops.command(text,text,uuid,integer,jsonb,text,uuid),plant_ops.download(uuid,integer),
 public.plant_workspace(text),public.plant_command(text,text,uuid,integer,jsonb,text,uuid),public.plant_file(uuid,integer) to authenticated;
