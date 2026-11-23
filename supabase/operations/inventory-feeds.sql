-- Managed Supabase setup. Credentials live in Vault or the private server mapping.
create extension if not exists http with schema extensions;
create extension if not exists pg_cron;
create or replace function inventory_hub.refresh_wired() returns integer
language plpgsql set search_path='' as $$
declare captured timestamptz:=clock_timestamp(); batch jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('trefil:feed:wired',0)) then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',source_id,'sku',sku,'label',product_name,'variant',variant_name,'unit',unit,'stock',reported_stock)), '[]') into batch from inventory_hub.wired_offers;
  return inventory_hub.replace_snapshot('wired','directa',captured,batch);
exception when others then
  update inventory_hub.sources set last_attempt=clock_timestamp(),last_error='No se completó la lectura de Wired. Se conserva la última lectura.' where source='wired'; return null;
end $$;

create or replace function inventory_hub.refresh_mastershop() returns integer
language plpgsql set search_path='' as $$
declare key_value text; resp extensions.http_response; body jsonb; page_data jsonb; products jsonb:='[]';
        captured timestamptz:=clock_timestamp(); page_no integer:=1; expected integer; total integer; next_rows jsonb;
        message text:='Mastershop devolvió una respuesta incompleta. Se conserva la lectura anterior.';
begin
  if not pg_try_advisory_xact_lock(hashtextextended('trefil:feed:mastershop',0)) then return null; end if;
  select decrypted_secret into key_value from vault.decrypted_secrets where name='mastershop_wired_api_key';
  if nullif(trim(key_value),'') is null then
    update inventory_hub.sources set last_attempt=clock_timestamp(),last_error='Pendiente de llave de Wired Colombia en Vault.' where source='mastershop'; return null;
  end if;
  perform set_config('http.curlopt_timeout_ms','10000',true);
  perform set_config('http.curlopt_connecttimeout_ms','3500',true);
  loop
    select * into resp from extensions.http(('GET','https://prod.api.mastershop.com/api/products?page='||page_no||'&limit=20',
       array[extensions.http_header('ms-api-key',trim(key_value)),extensions.http_header('Accept','application/json')],null,null)::extensions.http_request);
    if resp.status<>200 then
      message:=format('Mastershop respondió HTTP %s. Se conserva la última lectura.',resp.status); raise data_exception;
    end if;
    body:=resp.content::jsonb;
    if jsonb_typeof(body->'data')='object' and body->'results' is null then body:=body->'data'; end if;
    page_data:=body->'results';
    if jsonb_typeof(page_data) is distinct from 'array' then raise data_exception; end if;
    total:=nullif(body->>'totalProducts','')::integer;
    if page_no=1 then expected:=total; end if;
    if total is distinct from expected or total<0 then raise data_exception; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id',p->>'idProduct','sku',nullif(p->>'sku',''),
      'label',p->>'name','variant',null,'unit','unds.','stock',nullif(p->>'stockTotal','')::numeric)),'[]') into next_rows
      from jsonb_array_elements(page_data) p;
    products:=products||next_rows;
    exit when jsonb_array_length(page_data)<20 or (expected is not null and jsonb_array_length(products)>=expected);
    page_no:=page_no+1;
    if page_no>500 then raise data_exception; end if;
  end loop;
  if expected is not null and expected<>jsonb_array_length(products) then raise data_exception; end if;
  return inventory_hub.replace_snapshot('mastershop','api',captured,products);
exception when others then
  update inventory_hub.sources set last_attempt=clock_timestamp(),last_error=message where source='mastershop'; return null;
end $$;
revoke all on function inventory_hub.refresh_wired(),inventory_hub.refresh_mastershop() from public,anon,authenticated;
select cron.schedule('trefil_inventario_wired','*/5 * * * *','select inventory_hub.refresh_wired()');
select cron.schedule('trefil_inventario_mastershop','2,17,32,47 * * * *','select inventory_hub.refresh_mastershop()');
