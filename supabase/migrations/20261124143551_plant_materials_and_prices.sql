-- Applied prices expose commercial amounts only, after the authorized effective date.
create function plant_ops.prices() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person(); access_row plant_ops.access;
begin
  select * into access_row from plant_ops.access where person=actor.id;
  if not (plant_ops.permits(access_row,'planta.ver') or workforce.has_permission(actor,'sales_view')) then
    raise exception 'Consulta de precios restringida.' using errcode='42501';
  end if;
  return (select coalesce(jsonb_agg(to_jsonb(p) order by lista,codigo),'[]') from (
    select distinct on (lower(btrim(data->>'lista')),upper(btrim(data->>'codigo')))
      lower(btrim(data->>'lista')) lista, upper(btrim(data->>'codigo')) codigo,
      data->>'precio' precio, (data->>'vigente')::date vigente
    from plant_ops.records where kind='precio' and (data->>'vigente')::date <= (now() at time zone 'America/Bogota')::date
    order by lower(btrim(data->>'lista')),upper(btrim(data->>'codigo')),(data->>'vigente')::date desc,series desc
  ) p);
end $$;
create function public.plant_current_prices() returns jsonb language sql stable security invoker set search_path=''
as $$select plant_ops.prices()$$;
revoke all on function public.plant_current_prices(),plant_ops.prices() from public,anon;
grant execute on function public.plant_current_prices(),plant_ops.prices() to authenticated;

-- All stock operations use the same ledger, within the order transaction. Each revision
-- has an independent reservation document so later releases never consume another order's meters.
create function plant_ops.order_materials() returns trigger language plpgsql set search_path='' as $$
declare material record; prior jsonb; previous_rows jsonb:='[]'; result jsonb:='[]'; needed numeric;
  qty numeric; available numeric; booked numeric; used numeric; total_used numeric; doc text; item_key text; unit_name text;
  closing boolean:=new.state='cerrado'; reopening boolean:=false;
begin
  if tg_op='UPDATE' then
    reopening:=old.state='cerrado' and new.state='abierto';
    if not closing and not reopening and new.data->'necesidades' is not distinct from old.data->'necesidades' then return new; end if;
    previous_rows:=coalesce(old.data->'reservasMaterial','[]');
  end if;
  for material in
    select upper(btrim(f->>'codigo')) code,lower(btrim(f->>'unidad')) unit,
      upper(coalesce(nullif(btrim(l->>'bodegaMaterial'),''),'MATERIA PRIMA')) warehouse,
      sum((l->>'cantidad')::numeric*(f->>'cantidad')::numeric) target
    from jsonb_array_elements(new.data->'lineas') l
    cross join lateral jsonb_array_elements(coalesce(l#>'{fichaTecnica,formula}','[]')) f
    group by 1,2,3 order by 1,2,3
  loop
    item_key:=jsonb_build_array(material.code,material.unit,material.warehouse)::text;
    select p into prior from jsonb_array_elements(previous_rows) p where p->>'clave'=item_key;
    booked:=coalesce((prior->>'reservado')::numeric,0);
    total_used:=coalesce((prior->>'consumido')::numeric,0);
    select base_unit into unit_name from inventory_hub.items where code=material.code;
    if unit_name is not null and lower(btrim(unit_name))<>material.unit then
      raise exception 'La unidad de % debe coincidir con su unidad física (%).',material.code,unit_name;
    end if;
    if closing then
      used:=plant_ops.quantity(new.data#>'{cierre,consumos}',item_key,true);
      if used is null then raise exception 'Registra el consumo real de %.',material.code; end if;
      if booked>used then perform plant_ops.stock(material.code,material.warehouse,'liberacion',booked-used,prior->>'documento',gen_random_uuid()); end if;
      if least(booked,used)>0 then perform plant_ops.stock(material.code,material.warehouse,'despacho',least(booked,used),prior->>'documento',gen_random_uuid()); end if;
      if used>booked then perform plant_ops.stock(material.code,material.warehouse,'salida',used-booked,'OT-CONS-'||new.id||'-'||new.version,gen_random_uuid()); end if;
      total_used:=total_used+used; booked:=0; doc:=null;
    else
      if booked>0 then perform plant_ops.stock(material.code,material.warehouse,'liberacion',booked,prior->>'documento',gen_random_uuid()); end if;
      needed:=greatest(0,material.target-total_used);
      select physical-reserved into available from inventory_hub.balances where code=material.code and warehouse=material.warehouse and revision>0 for update;
      booked:=least(needed,coalesce(available,0));
      doc:='OT-MAT-'||new.id||'-'||new.version;
      if booked>0 then perform plant_ops.stock(material.code,material.warehouse,'reserva',booked,doc,gen_random_uuid()); end if;
    end if;
    result:=result||jsonb_build_array(jsonb_build_object('clave',item_key,'codigo',material.code,'unidad',material.unit,
      'bodega',material.warehouse,'teorico',material.target,'reservado',booked,'consumido',total_used,
      'faltante',case when closing then 0 else greatest(0,material.target-total_used-booked) end,'documento',doc));
  end loop;
  new.data:=jsonb_set(new.data,'{reservasMaterial}',result);
  return new;
end $$;
create trigger order_materials before insert or update on plant_ops.records
for each row when (new.kind='ot') execute function plant_ops.order_materials();

create function plant_ops.validate_record() returns trigger language plpgsql set search_path='' as $$
declare original plant_ops.records; period text; actor workforce.people:=workforce.require_person(); access_row plant_ops.access;
begin
  select * into access_row from plant_ops.access where person=actor.id;
  if tg_op='INSERT' and new.kind in ('ot','entrega','lote','rotulo','garantia','cierre') and access_row.profile not in ('CREADOR','PRODUCCIÓN') then
    raise exception 'La declaración técnica corresponde a Producción.' using errcode='42501';
  end if;
  if tg_op='UPDATE' and new.kind in ('caso','cierre') and new.state in ('aprobado','rechazado') and
    not plant_ops.permits(access_row,'control.aprobar') then raise exception 'Se requiere permiso de aprobación.' using errcode='42501'; end if;
  if new.kind='traslado' and tg_op='INSERT' then
    select * into strict original from plant_ops.records where id=new.parent;
    if (new.data->>'cantidad')::numeric<>(original.data->>'cantidad')::numeric then
      raise exception 'El traslado mueve el rótulo completo a la nueva ubicación.';
    end if;
  end if;
  if new.kind in ('costo','cierre') then
    period:=new.data->>'periodo';
    if period is null or period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Selecciona un mes válido.'; end if;
    if new.kind='costo' and exists(select from plant_ops.records c where c.kind='cierre' and c.state='aprobado' and c.data->>'periodo'=period) then raise exception 'El período ya está cerrado.'; end if;
  end if;
  if new.kind='caso' and new.parent is not null then
    select * into strict original from plant_ops.records where id=new.parent;
    if original.scope<>new.scope or original.kind in ('caso','expediente') then raise exception 'El documento no pertenece a este proceso.'; end if;
  end if;
  return new;
end $$;
create trigger plant_record_validation before insert or update on plant_ops.records for each row execute function plant_ops.validate_record();
revoke all on function plant_ops.validate_record(),plant_ops.order_materials() from public,anon,authenticated;

-- These aggregates deliberately run with the financial user's own row policies.
create function public.plant_management_cut(cutoff date) returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb:=public.plant_finance(cutoff); debts jsonb; matches jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(t) order by t.tipo),'[]') into debts from (
    select d.kind tipo,count(*) operaciones,sum(d.principal) capital,sum(coalesce(p.paid,0)) abonado,
      sum(d.principal-coalesce(p.paid,0)) saldo
    from public.debts d left join lateral (
      select sum(a.amount) paid from public.debt_payments p join public.payment_allocations a on a.payment_id=p.id
        join public.financial_transactions t on t.id=p.transaction_id
      where p.debt_id=d.id and a.kind='principal' and t.status='posted' and t.occurred_on<=cutoff and p.paid_on<=cutoff
        and not exists(select 1 from public.financial_transactions r where r.reversal_of=t.id and r.status='posted' and r.occurred_on<=cutoff)
    ) p on true where d.disbursed_on<=cutoff group by d.kind
  ) t;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.cuenta),'[]') into matches from (
    select distinct on (r.account_id) a.name cuenta,r.as_of fecha,r.difference diferencia,r.statement_balance extracto
    from public.reconciliations r join public.accounts a on a.id=r.account_id
    where r.as_of<=cutoff order by r.account_id,r.as_of desc,r.created_at desc,r.id desc
  ) q;
  return result||jsonb_build_object('deudas',debts,'conciliaciones',matches);
end $$;
revoke all on function public.plant_management_cut(date) from public,anon;
grant execute on function public.plant_management_cut(date) to authenticated;

-- Update the typed document field lists in the existing command. Existing writers that
-- submit the earlier, smaller payloads continue to work.
do $upgrade$
declare definition text:=pg_get_functiondef('plant_ops.command(text,text,uuid,integer,jsonb,text,uuid)'::regprocedure);
  mapping text[];
begin
  foreach mapping slice 1 in array array[
    ['array[''origen'',''documento'',''responsable'',''soporte'']','array[''origen'',''documento'',''responsable'',''soporte'',''importancia'',''areaResponsable'',''claseCaso'']'],
    ['array[''objetivo'',''responsable'',''fecha'',''supuestos'',''presupuesto'']','array[''objetivo'',''responsable'',''fecha'',''supuestos'',''presupuesto'',''documentos'',''indicador'',''fechaFin'',''escenario'']'],
    ['array[''asunto'',''nivel'',''fecha'',''responsable'']','array[''asunto'',''nivel'',''fecha'',''responsable'',''claseDocumento'',''vigencia'',''vinculo'']'],
    ['array[''factura'',''material'',''destino'',''facturado'',''fisico'',''sinPesaje'']','array[''factura'',''material'',''destino'',''facturado'',''fisico'',''sinPesaje'',''proveedor'',''remision'',''fecha'']']
  ] loop
    if strpos(definition,mapping[1])=0 then raise exception 'La definición del módulo no coincide con esta migración.'; end if;
    definition:=replace(definition,mapping[1],mapping[2]);
  end loop;
  execute definition;
end $upgrade$;
