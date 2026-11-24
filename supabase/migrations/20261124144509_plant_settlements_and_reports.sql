-- Applications refer to original evidence. Approving an application never posts money or stock.
create table plant_ops.applications (
  id uuid primary key, part uuid not null references plant_ops.records(id),
  kind text not null check(kind in ('Caja','Chatarra')), evidence uuid not null,
  amount numeric(18,2) not null check(amount>0), quantity numeric, unit_price numeric,
  state text not null default 'pendiente' check(state in ('pendiente','aprobado','rechazado')),
  author uuid not null references workforce.people(id), reviewer uuid references workforce.people(id),
  created timestamptz not null default now(), decided timestamptz, reason text not null, decision text,
  check(author is distinct from reviewer)
);
create index plant_evidence on plant_ops.applications(kind,evidence) where state<>'rechazado';
alter table plant_ops.applications enable row level security;
revoke all on plant_ops.applications from public,anon,authenticated;

create function plant_ops.supplier_accounts() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access;
begin
  select * into a from plant_ops.access where person=actor.id;
  if not (plant_ops.permits(a,'planta.ver') or plant_ops.permits(a,'control.ver') and (plant_ops.permits(a,'control.panel') or plant_ops.permits(a,'control.aprobar')) or workforce.has_permission(actor,'debts_view')) then raise exception 'Cartera de proveedores restringida.' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(q) order by proveedor,factura,partida),'[]') from (
    select r.id,r.data->>'proveedor' proveedor,r.data->>'factura' factura,r.data->>'partida' partida,r.data->>'vencimiento' vencimiento,
      (r.data->>'valor')::numeric facturado, coalesce(x.aplicado,0) aplicado,
      greatest(0,(r.data->>'valor')::numeric-coalesce(x.aplicado,0)) por_pagar,
      greatest(0,coalesce(x.aplicado,0)-(r.data->>'valor')::numeric) por_cobrar,
      coalesce(x.detalle,'[]') aplicaciones
    from plant_ops.records r left join lateral (
      select sum(p.amount) filter(where p.state='aprobado' and not coalesce(reversed.flag,false)) aplicado,
        jsonb_agg(jsonb_build_object('id',p.id,'tipo',p.kind,'estado',case when reversed.flag then 'reversado en Caja' else p.state end,
          'monto',p.amount,'soporte',p.reason,'decisión',p.decision,'autor',p.author) order by p.created desc) detalle
      from plant_ops.applications p left join lateral (
        select exists(select from public.financial_transactions t where t.reversal_of=p.evidence and t.status='posted') flag
      ) reversed on p.kind='Caja' where p.part=r.id
    ) x on true where r.kind='servicio'
  ) q);
end $$;
create function public.plant_supplier_accounts() returns jsonb language sql stable security invoker set search_path='' as $$select plant_ops.supplier_accounts()$$;

create function plant_ops.apply_supplier(part_id uuid, entry_id uuid, operation text, payload jsonb, note text)
returns uuid language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; doc plant_ops.records; line plant_ops.applications;
  tx public.financial_transactions; stock inventory_hub.movements; prior numeric; ceiling numeric; normalized text; resulting text; amount numeric;
begin
  if part_id is null or entry_id is null or operation is null or operation not in ('solicitar','aprobar','rechazar') or coalesce(length(btrim(note)),0) not between 3 and 1500 then raise exception 'Indica la partida y el soporte.'; end if;
  perform pg_advisory_xact_lock(727714,710);
  select * into a from plant_ops.access where person=actor.id;
  select * into strict doc from plant_ops.records where id=part_id and kind='servicio';
  select * into line from plant_ops.applications where id=entry_id;
  if operation='solicitar' then
    if not plant_ops.permits(a,'planta.ver') or not plant_ops.permits(a,'planta.registrar') then raise exception 'Registro de proveedores restringido.' using errcode='42501'; end if;
    amount:=plant_ops.quantity(payload,'monto');
    if amount<>round(amount,2) or amount>=1e16 then raise exception 'Revisa el monto en COP.'; end if;
    if line.id is not null then
      if line.author=actor.id and line.part=part_id and line.reason=note and line.kind=payload->>'tipo' and line.amount=amount
        and exists(select from plant_ops.events e where e.request=entry_id and e.current_value=payload) then return line.id; end if;
      raise exception 'La solicitud ya tiene otros datos.';
    end if;
    line.id:=entry_id; line.part:=part_id; line.author:=actor.id; line.kind:=payload->>'tipo'; line.amount:=amount;
    if line.kind is null or line.kind not in ('Caja','Chatarra') then raise exception 'Selecciona el tipo de aplicación.'; end if;
  else
    if not plant_ops.permits(a,'control.ver') or not plant_ops.permits(a,'control.aprobar') or a.profile not in ('CREADOR','GERENTE')
      then raise exception 'La decisión corresponde a Gerencia o Creador.' using errcode='42501'; end if;
    resulting:=case operation when 'aprobar' then 'aprobado' else 'rechazado' end;
    if line.part is distinct from part_id or line.author=actor.id then raise exception 'Se requiere una segunda persona autorizada.'; end if;
    if line.state=resulting and line.reviewer=actor.id and line.decision=note then return entry_id; end if;
    if line.state<>'pendiente' then raise exception 'La solicitud ya fue resuelta.'; end if;
  end if;
  if operation<>'rechazar' then
    if line.kind='Caja' then
      if operation='solicitar' then
        select * into tx from public.financial_transactions t where (t.id::text=btrim(payload->>'documento') or t.reference::text=btrim(payload->>'documento'))
          and private.has_access(t.organization_id,t.location_id,array['owner','admin','treasury','accounting']);
      else select * into tx from public.financial_transactions t where t.id=line.evidence and private.has_access(t.organization_id,t.location_id,array['owner','admin','treasury','accounting']); end if;
      if tx.id is null or tx.kind<>'expense' or tx.status<>'posted' or lower(btrim(tx.party))<>lower(btrim(doc.data->>'proveedor'))
        or exists(select from public.financial_transactions r where r.reversal_of=tx.id and r.status='posted')
        then raise exception 'Se requiere un egreso contabilizado de este proveedor, visible en Caja y sin reverso.'; end if;
      line.evidence:=tx.id;
      select coalesce(sum(e.credit-e.debit),0) into ceiling from public.transaction_entries e join public.accounts b on b.id=e.account_id
        where e.transaction_id=tx.id and b.kind in ('bank','cash','wallet');
      select coalesce(sum(p.amount),0) into prior from plant_ops.applications p
        where p.kind='Caja' and p.evidence=tx.id and p.id<>entry_id and p.state<>'rechazado';
      if prior+line.amount>ceiling then raise exception 'Las aplicaciones superan el dinero efectivamente pagado.'; end if;
    else
      if not workforce.has_permission(actor,'inventory_view') then raise exception 'Se requiere acceso al inventario.' using errcode='42501'; end if;
      if operation='solicitar' then
        select * into stock from inventory_hub.movements m where m.request_id=nullif(payload->>'documento','')::uuid;
        line.quantity:=plant_ops.quantity(payload,'cantidad'); line.unit_price:=plant_ops.quantity(payload,'precio');
      else select * into stock from inventory_hub.movements m where m.request_id=line.evidence; end if;
      if stock.request_id is null or stock.kind<>'salida' or round(line.quantity*line.unit_price,2)<>line.amount then raise exception 'Vincula la salida física y verifica el peso, el precio y el valor del acuerdo.'; end if;
      line.evidence:=stock.request_id;
      select coalesce(sum(p.quantity),0) into prior from plant_ops.applications p where p.kind='Chatarra' and p.evidence=line.evidence and p.state<>'rechazado' and p.id<>entry_id;
      if prior+line.quantity>stock.quantity or exists(select from plant_ops.applications p join plant_ops.records r on r.id=p.part
        where p.evidence=line.evidence and p.state<>'rechazado' and (lower(btrim(r.data->>'proveedor'))<>lower(btrim(doc.data->>'proveedor')) or p.unit_price<>line.unit_price))
        then raise exception 'La salida física está comprometida con otra cantidad, precio o proveedor.'; end if;
    end if;
  end if;
  if operation='solicitar' then
    insert into plant_ops.applications(id,part,kind,evidence,amount,quantity,unit_price,author,reason)
      values(entry_id,part_id,line.kind,line.evidence,line.amount,line.quantity,line.unit_price,actor.id,note);
  else update plant_ops.applications set state=resulting,reviewer=actor.id,decided=now(),decision=note where id=entry_id; end if;
  insert into plant_ops.events(request,actor,area,action,target,reason,current_value,signature) values(
    case when operation='solicitar' then entry_id else gen_random_uuid() end,actor.id,case when operation='solicitar' then 'produccion' else 'control' end,
    'proveedor_'||operation,part_id,note,case when operation='solicitar' then payload else jsonb_build_object('solicitud',entry_id,'estado',resulting) end,'proveedor');
  return entry_id;
end $$;
create function public.plant_supplier_action(part_id uuid,entry_id uuid,operation text,payload jsonb,note text) returns uuid language sql security invoker set search_path=''
as $$select plant_ops.apply_supplier(part_id,entry_id,operation,payload,note)$$;
revoke all on function plant_ops.supplier_accounts(),public.plant_supplier_accounts(),plant_ops.apply_supplier(uuid,uuid,text,jsonb,text),public.plant_supplier_action(uuid,uuid,text,jsonb,text) from public,anon;
grant execute on function plant_ops.supplier_accounts(),public.plant_supplier_accounts(),plant_ops.apply_supplier(uuid,uuid,text,jsonb,text),public.plant_supplier_action(uuid,uuid,text,jsonb,text) to authenticated;

create function plant_ops.report(start_date date,end_date date,kind_filter text,sku text,exporting boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; rows jsonb;
begin
  select * into a from plant_ops.access where person=actor.id;
  if not plant_ops.permits(a,'planta.ver') or not (a.profile='CREADOR' or workforce.has_permission(actor,'reports_view'))
    then raise exception 'El informe requiere permisos de Producción e Informes.' using errcode='42501'; end if;
  if start_date is null or end_date is null or start_date>end_date or end_date>(now() at time zone 'America/Bogota')::date then raise exception 'Revisa el intervalo del informe.'; end if;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.fecha,t.serie),'[]') into rows from (
    select r.series serie,r.kind tipo,r.title documento,q.v->>'state' estado,(q.v->>'version')::integer version,
      (q.changed at time zone 'America/Bogota')::date fecha,coalesce(q.v#>>'{data,codigo}',f.data->>'codigo') codigo,
      q.v#>>'{data,cantidad}' cantidad,q.v#>>'{data,teorico}' teorico,q.v#>>'{data,real}' real,
      q.v#>>'{data,periodo}' periodo,p.full_name responsable
    from plant_ops.records r join lateral (
      select e.current_value v,e.at_time changed,e.actor from plant_ops.events e where e.target=r.id and e.current_value->>'id'=r.id::text
        and e.at_time<((end_date+1)::timestamp at time zone 'America/Bogota') order by e.seq desc limit 1
    ) q on true join workforce.people p on p.id=q.actor left join plant_ops.records f on f.id=nullif(q.v#>>'{data,ficha}','')::uuid and f.kind='ficha'
    where r.scope='produccion' and r.kind not in ('caso','expediente','proyecto')
      and q.changed>=start_date::timestamp at time zone 'America/Bogota' and (coalesce(kind_filter,'')='' or r.kind=kind_filter)
      and (coalesce(btrim(sku),'')='' or upper(coalesce(q.v#>>'{data,codigo}',f.data->>'codigo'))=upper(btrim(sku)) or exists(
        select from jsonb_array_elements(coalesce(q.v#>'{data,lineas}','[]')) l where upper(l#>>'{fichaTecnica,codigo}')=upper(btrim(sku))))
  ) t;
  if exporting then
    insert into plant_ops.events(request,actor,area,action,target,reason,signature) values(gen_random_uuid(),actor.id,'produccion','exportar',actor.id,
      'Informe '||start_date||' / '||end_date||' · '||jsonb_array_length(rows)||' registros','exportación');
  end if;
  return rows;
end $$;
create function public.plant_report(start_date date,end_date date,kind_filter text,sku text,exporting boolean) returns jsonb language sql security invoker set search_path=''
as $$select plant_ops.report(start_date,end_date,kind_filter,sku,exporting)$$;
revoke all on function public.plant_report(date,date,text,text,boolean),plant_ops.report(date,date,text,text,boolean) from public,anon;
grant execute on function public.plant_report(date,date,text,text,boolean),plant_ops.report(date,date,text,text,boolean) to authenticated;

create function plant_ops.supplier_sources(part_id uuid, mode text, search_term text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; supplier text;
begin
  select * into a from plant_ops.access where person=actor.id;
  if not plant_ops.permits(a,'planta.ver') or not plant_ops.permits(a,'planta.registrar') then raise exception 'Acceso restringido.' using errcode='42501'; end if;
  select data->>'proveedor' into strict supplier from plant_ops.records where id=part_id and kind='servicio';
  if mode='Caja' then
    return (select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (
      select t.id::text id,'Caja '||t.reference||' · '||t.occurred_on||' · '||t.description etiqueta from public.financial_transactions t
      where t.status='posted' and t.kind='expense' and lower(btrim(t.party))=lower(btrim(supplier))
        and private.has_access(t.organization_id,t.location_id,array['owner','admin','treasury','accounting'])
        and not exists(select from public.financial_transactions r where r.reversal_of=t.id and r.status='posted')
        and concat_ws(' ',t.reference,t.description) ilike '%'||left(coalesce(search_term,''),100)||'%' order by t.reference desc limit 60) q);
  elsif mode='Chatarra' and workforce.has_permission(actor,'inventory_view') then
    return (select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (
      select m.request_id::text id,m.document||' · '||m.code||' · '||m.warehouse||' · '||m.quantity||' '||i.base_unit etiqueta
      from inventory_hub.movements m join inventory_hub.items i on i.code=m.code
      where m.kind='salida' and concat_ws(' ',m.document,m.code,m.warehouse) ilike '%'||left(coalesce(search_term,''),100)||'%'
      order by m.at_time desc limit 60) q);
  end if;
  raise exception 'Se requiere acceso al origen.' using errcode='42501';
end $$;
create function public.plant_supplier_sources(part_id uuid,mode text,search_term text) returns jsonb language sql stable security invoker set search_path=''
as $$select plant_ops.supplier_sources(part_id,mode,search_term)$$;
revoke all on function public.plant_supplier_sources(uuid,text,text),plant_ops.supplier_sources(uuid,text,text) from public,anon;
grant execute on function public.plant_supplier_sources(uuid,text,text),plant_ops.supplier_sources(uuid,text,text) to authenticated;

create table plant_ops.warranty_evidence (
  record uuid not null references plant_ops.records(id), source uuid primary key, purpose text not null
);
alter table plant_ops.warranty_evidence enable row level security;
revoke all on plant_ops.warranty_evidence from public,anon,authenticated;
create function plant_ops.warranty_close(item uuid,expected integer,request uuid,body jsonb,note text) returns uuid language plpgsql security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; r plant_ops.records; initial jsonb;
  inbound inventory_hub.movements; outbound inventory_hub.movements; tx public.financial_transactions; decision text:=body->>'solucion';
  qty numeric; factor numeric; value_cop numeric; actual numeric; record_key text:=jsonb_build_array(item,expected,body,note)::text; event plant_ops.events;
begin
  perform pg_advisory_xact_lock(727714,710);
  select * into a from plant_ops.access where person=actor.id;
  if not plant_ops.permits(a,'planta.ver') or not plant_ops.permits(a,'planta.registrar') or a.profile not in ('CREADOR','GERENTE','GERENTE DE VENTAS','PRODUCCIÓN')
    or not workforce.has_permission(actor,'inventory_view') then raise exception 'Requiere acceso de Producción e Inventarios.' using errcode='42501'; end if;
  if request is null or coalesce(length(btrim(note)),0) not between 3 and 1500 or decision is null or decision not in ('Reposición','Reembolso','Sin compensación')
    then raise exception 'Selecciona la solución y el soporte.'; end if;
  select * into event from plant_ops.events e where e.request=warranty_close.request;
  if found then
    if event.actor<>actor.id or event.signature<>record_key then raise exception 'La solicitud cambió.'; end if;
    return item;
  end if;
  select * into strict r from plant_ops.records where id=item and kind='garantia' for update;
  if r.version is distinct from expected or not ((r.state='aprobado' and decision in ('Reposición','Reembolso')) or (r.state='rechazado' and decision='Sin compensación'))
    then raise exception 'Se necesita una decisión comercial vigente sobre la garantía.'; end if;
  initial:=to_jsonb(r); qty:=(r.data->>'cantidad')::numeric; value_cop:=round(qty*(r.data->>'pagado')::numeric,2);
  if r.state='aprobado' and r.data->>'solucionAutorizada' is distinct from decision then raise exception 'La solución debe ser la autorizada en la decisión comercial.'; end if;
  if coalesce((r.data->>'adicionalesAutorizados')::numeric,0)>0 then perform plant_ops.required(body,array['ventaAdicional']); end if;
  perform plant_ops.required(body,array['documentoOriginal','clasificacion','codigoDestino','bodegaDestino','factor']);
  select * into inbound from inventory_hub.movements where request_id=(body->>'clasificacion')::uuid;
  factor:=plant_ops.quantity(body,'factor');
  if inbound.request_id is null or inbound.kind not in ('entrada','devolucion') or inbound.code<>upper(btrim(body->>'codigoDestino'))
     or inbound.warehouse<>upper(btrim(body->>'bodegaDestino')) or inbound.quantity<>qty*factor
     then raise exception 'La entrada de clasificación debe coincidir con el material, la bodega y la cantidad convertida.'; end if;
  if factor<>1 then perform plant_ops.required(body,array['conversion']); end if;
  if inbound.warehouse<>upper('GARANTÍAS - '||(r.data->>'destino')) then raise exception 'El movimiento debe corresponder a la ubicación de clasificación GARANTÍAS - %.',upper(r.data->>'destino'); end if;
  if decision='Reposición' then
    select * into outbound from inventory_hub.movements where request_id=nullif(body->>'compensacion','')::uuid;
    if outbound.request_id is null or outbound.kind not in ('salida','despacho') or outbound.code<>upper(btrim(r.data->>'codigo')) or outbound.quantity<>qty
      then raise exception 'La reposición requiere la salida del mismo producto por la cantidad aprobada.'; end if;
    perform plant_ops.required(body,array['entregaCliente']); perform plant_ops.quantity(body,'costoInterno',true);
  elsif decision='Reembolso' then
    perform plant_ops.required(body,array['cliente','compensacion']);
    select * into tx from public.financial_transactions t where (t.id::text=body->>'compensacion' or t.reference::text=body->>'compensacion') and private.has_access(t.organization_id,t.location_id,array['owner','admin','treasury','accounting']);
    if tx.id is null or tx.status<>'posted' or tx.kind not in ('expense','reimbursement') or lower(btrim(tx.party))<>lower(btrim(body->>'cliente'))
      or exists(select from public.financial_transactions rev where rev.reversal_of=tx.id and rev.status='posted') then raise exception 'Selecciona un reembolso contabilizado a este cliente.'; end if;
    select sum(e.credit-e.debit) into actual from public.transaction_entries e join public.accounts b on b.id=e.account_id where e.transaction_id=tx.id and b.kind in ('cash','bank','wallet');
    if actual is distinct from value_cop then raise exception 'El reembolso debe coincidir con la cantidad por el precio pagado de la factura original.'; end if;
  end if;
  if exists(select from plant_ops.applications p where p.evidence in (inbound.request_id,outbound.request_id,tx.id) and p.state<>'rechazado') then raise exception 'Un movimiento ya respalda una aplicación de proveedor.'; end if;
  insert into plant_ops.warranty_evidence values(item,inbound.request_id,'clasificación');
  if decision<>'Sin compensación' then insert into plant_ops.warranty_evidence values(item,coalesce(outbound.request_id,tx.id),decision); end if;
  update plant_ops.records set state='cerrado',version=version+1,data=data||jsonb_build_object('conciliacion',jsonb_build_object(
    'solucion',decision,'factura',r.data->>'factura','soporteFactura',body->>'documentoOriginal','destino',r.data->>'destino',
    'clasificacion',inbound.document,'codigo',inbound.code,'bodega',inbound.warehouse,'factor',factor,'conversion',body->>'conversion',
    'valorReconocido',case when decision='Sin compensación' then 0 else value_cop end,'costoInterno',body->>'costoInterno',
    'egresoCaja',tx.reference,'salidaReposicion',outbound.document,'soporteEntrega',body->>'entregaCliente','ventaAdicional',body->>'ventaAdicional','responsable',actor.id))
    where id=item returning * into r;
  insert into plant_ops.events(request,actor,area,action,target,reason,previous,current_value,signature)
    values(request,actor.id,'produccion','conciliar_garantia',item,note,initial,to_jsonb(r),record_key);
  return item;
end $$;
create function public.plant_warranty_close(item uuid,expected integer,request uuid,body jsonb,note text) returns uuid language sql security invoker set search_path=''
as $$select plant_ops.warranty_close(item,expected,request,body,note)$$;
revoke all on function public.plant_warranty_close(uuid,integer,uuid,jsonb,text),plant_ops.warranty_close(uuid,integer,uuid,jsonb,text) from public,anon;
grant execute on function public.plant_warranty_close(uuid,integer,uuid,jsonb,text),plant_ops.warranty_close(uuid,integer,uuid,jsonb,text) to authenticated;
create function plant_ops.check_other_evidence() returns trigger language plpgsql set search_path='' as $$
begin
  if new.state<>'rechazado' and exists(select from plant_ops.warranty_evidence e where e.source=new.evidence) then raise exception 'El movimiento ya respalda una garantía.'; end if;
  return new;
end $$;
create trigger supplier_evidence_unique before insert or update on plant_ops.applications for each row execute function plant_ops.check_other_evidence();
revoke all on function plant_ops.check_other_evidence() from public,anon,authenticated;

create function plant_ops.warranty_sources(item uuid,mode text,search_term text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); a plant_ops.access; original plant_ops.records;
begin
  select * into a from plant_ops.access where person=actor.id;
  if not plant_ops.permits(a,'planta.ver') or not plant_ops.permits(a,'planta.registrar') or not workforce.has_permission(actor,'inventory_view') then raise exception 'Acceso restringido.' using errcode='42501'; end if;
  select * into strict original from plant_ops.records where id=item and kind='garantia' and state in ('aprobado','rechazado');
  return (select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (
    select m.request_id id,m.document||' · '||m.code||' · '||m.warehouse||' · '||m.quantity||' '||i.base_unit etiqueta
    from inventory_hub.movements m join inventory_hub.items i on i.code=m.code
    where ((mode='clasificacion' and m.kind in ('entrada','devolucion') and m.warehouse=upper('GARANTÍAS - '||(original.data->>'destino'))) or (mode='reposicion' and m.kind in ('salida','despacho') and m.code=upper(btrim(original.data->>'codigo'))))
      and not exists(select from plant_ops.warranty_evidence e where e.source=m.request_id)
      and concat_ws(' ',m.document,m.code,m.warehouse) ilike '%'||left(coalesce(search_term,''),100)||'%'
    order by m.at_time desc limit 60) q);
end $$;
create function public.plant_warranty_sources(item uuid,mode text,search_term text) returns jsonb language sql security invoker set search_path=''
as $$select plant_ops.warranty_sources(item,mode,search_term)$$;
revoke all on function public.plant_warranty_sources(uuid,text,text),plant_ops.warranty_sources(uuid,text,text) from public,anon;
grant execute on function public.plant_warranty_sources(uuid,text,text),plant_ops.warranty_sources(uuid,text,text) to authenticated;

do $upgrade$
declare definition text:=pg_get_functiondef('plant_ops.command(text,text,uuid,integer,jsonb,text,uuid)'::regprocedure);
  marker text:='if r.author=actor.id then raise exception';
begin
  if strpos(definition,marker)=0 then raise exception 'Decisión comercial incompatible con la versión.'; end if;
  definition:=replace(definition,marker,$approval$
    if k='garantia' and action='aprobar' then
      if coalesce(body->>'solucion','') not in ('Reposición','Reembolso') then raise exception 'Define la solución comercial autorizada.'; end if;
      r.data:=r.data||jsonb_build_object('solucionAutorizada',body->>'solucion');
      if body ? 'adicionales' and nullif(body->>'adicionales','') is not null and plant_ops.quantity(body,'adicionales',true)>0 then
        if a.profile<>'GERENTE DE VENTAS' then raise exception 'Los adicionales requieren decisión de Gerencia de Ventas.'; end if;
        select value into strict entry from jsonb_array_elements(plant_ops.prices()) where value->>'codigo'=upper(btrim(r.data->>'codigo')) and value->>'lista'=lower(btrim(body->>'lista'));
        r.data:=r.data||jsonb_build_object('adicionalesAutorizados',plant_ops.quantity(body,'adicionales'),'precioAdicional',entry,'valorAdicional',round((entry->>'precio')::numeric*(body->>'adicionales')::numeric,2));
      end if;
    end if;
    $approval$||marker);
  execute definition;
end $upgrade$;

create or replace function plant_ops.permissions() returns text[] language sql immutable set search_path='' as $$
 select array['planta.ver','planta.registrar','planta.verificar','bodega.recibir','control.ver','control.personas','control.administrar_permisos','control.aprobar','control.seguimiento','control.panel','control.proyectos','archivo.ver','archivo.descargar','archivo.editar','control.auditar']
$$;
do $rights$
declare definition text:=pg_get_functiondef('plant_ops.command(text,text,uuid,integer,jsonb,text,uuid)'::regprocedure);
  old_test text:='if area<>''control'' or a.profile<>''CREADOR'' then'; marker text:='if not allowed <@ plant_ops.permissions() then';
begin
  if strpos(definition,old_test)=0 or strpos(definition,marker)=0 then raise exception 'Versión de permisos incompatible.'; end if;
  definition:=replace(definition,old_test,'if area<>''control'' or not plant_ops.permits(a,''control.administrar_permisos'') then');
  definition:=replace(definition,marker,$guard$
    if a.profile<>'CREADOR' and (actor.id=target or body->>'perfil' is distinct from old_access.profile or
      not (allowed <@ a.rights) or not (coalesce(old_access.rights,'{}') <@ a.rights) or 'control.administrar_permisos'=any(allowed)
      or 'control.administrar_permisos'=any(old_access.rights)) then
      raise exception 'Solo puedes administrar funciones propias delegables del perfil ya asignado.' using errcode='42501';
    end if;
  $guard$||marker);
  execute definition;
end $rights$;

do $recovery$
declare definition text:=pg_get_functiondef('plant_ops.command(text,text,uuid,integer,jsonb,text,uuid)'::regprocedure);
  types text:='if k not in (''proyecto'',''caso'',''ficha'',''expediente'',''ot'') then';
  branch text:='elsif k=''expediente'' then'||chr(10)||'         content:=decode';
  reconcile text:='required_qty:=coalesce(nullif(r.data->>''fisico'',''''),r.data->>''cantidad'')::numeric;';
begin
  if strpos(definition,types)=0 or strpos(definition,branch)=0 or strpos(definition,reconcile)=0 then raise exception 'Versión de conciliación incompatible.'; end if;
  definition:=replace(definition,types,replace(types,'''ot'')','''ot'',''recuperacion'')'));
  definition:=replace(definition,branch,$body$
       elsif k='recuperacion' then
         if a.profile not in ('PRODUCCIÓN','CREADOR') or nullif(r.data->>'fisico','') is not null then raise exception 'Solo se puede completar el primer pesaje pendiente.'; end if;
         qty:=plant_ops.quantity(body,'fisico',true); perform plant_ops.required(body,array['soporte']);
         r.data:=r.data||jsonb_build_object('fisico',qty,'soportePesaje',body->>'soporte','pesadoPor',actor.id);
         if qty<>(r.data->>'facturado')::numeric then
           insert into plant_ops.records(kind,title,parent,state,data,author) values('caso','Diferencia de peso · '||r.title,r.id,'pendiente',
             jsonb_build_object('origen','Producción','documento',r.series,'responsable','Producción','facturado',r.data->'facturado','fisico',qty),actor.id);
         end if;
       $body$||branch);
  definition:=replace(definition,reconcile,$components$
        if jsonb_typeof(body->'partes') is distinct from 'array' or jsonb_array_length(body->'partes')=0 then raise exception 'Detalla las cantidades destinadas a cada clasificación.'; end if;
        used:=0;
        for entry in select value from jsonb_array_elements(body->'partes') loop
          if coalesce(entry->>'clase','') not in ('Producto regular','Cortas','Dañado','Sobrante','Material limpio','Insumo reutilizable','Chatarra comercial','Descarte') then raise exception 'Clasificación de componente inválida.'; end if;
          perform plant_ops.required(entry,array['destino','unidad']);
          qty:=plant_ops.quantity(entry,'cantidad',true); required_qty:=plant_ops.quantity(entry,'factor');
          if lower(btrim(entry->>'unidad'))<>lower(btrim(body->>'unidad')) or required_qty<>1 then perform plant_ops.required(entry,array['conversion']); end if;
          used:=used+qty*required_qty;
        end loop;
        if used<>plant_ops.quantity(body,'conciliado',true) then raise exception 'Los componentes convertidos deben sumar la cantidad conciliada.'; end if;
        if lower(btrim(body->>'unidad'))<>lower(btrim(case when k='recuperacion' then 'kg' else r.data->>'unidad' end)) then raise exception 'La conciliación debe expresarse en la unidad original.'; end if;
       $components$||reconcile);
  execute definition;
end $recovery$;

-- Production owns the technical disposition of material and transfer discrepancies.
-- Other decisions retain the financial/managerial separation of duties.
do $technical$
declare definition text:=pg_get_functiondef('plant_ops.command(text,text,uuid,integer,jsonb,text,uuid)'::regprocedure);
  validation text:=pg_get_functiondef('plant_ops.validate_record()'::regprocedure);
  marker text:='and not(k=''garantia'' and a.profile=''GERENTE DE VENTAS'')';
  validation_marker text:='not plant_ops.permits(access_row,''control.aprobar'') then';
begin
  if strpos(definition,marker)=0 or strpos(validation,validation_marker)=0 then raise exception 'Revisor de novedades incompatible.'; end if;
  definition:=replace(definition,marker,marker||$sql$
    and not(k='caso' and area='produccion' and a.profile='PRODUCCIÓN' and plant_ops.permits(a,'planta.verificar')
        and exists(select from plant_ops.records source where source.id=r.parent and source.kind in ('recuperacion','traslado')))
  $sql$);
  definition:=replace(definition,'where id=r.parent and kind=''entrega'' and state<>''aceptado''','where id=r.parent and kind in (''entrega'',''traslado'') and state<>''aceptado''');
  validation:=replace(validation,validation_marker,$sql$
    not plant_ops.permits(access_row,'control.aprobar') and not(new.kind='caso' and access_row.profile='PRODUCCIÓN' and plant_ops.permits(access_row,'planta.verificar')
      and exists(select from plant_ops.records source where source.id=new.parent and source.kind in ('recuperacion','traslado'))) then
  $sql$);
  execute definition;
  execute validation;
end $technical$;
