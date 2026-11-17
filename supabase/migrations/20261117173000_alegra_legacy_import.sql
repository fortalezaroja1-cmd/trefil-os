-- Alegra is imported as a read-only historical source. These records never
-- create Caja movements, ledger entries, customer balances or stock changes.
create schema if not exists alegra;
revoke all on schema alegra from public,anon,authenticated;
grant usage on schema alegra to authenticated;

insert into workforce.permissions(code,name,description,category,module,sort_order) values
  ('alegra_read','Consultar histórico de Alegra','Ver clientes, productos y facturas importados desde Alegra.','team','sales',420),
  ('alegra_import','Importar histórico de Alegra','Ejecutar y verificar una importación administrativa de Alegra.','administration','sales',430)
on conflict(code) do update set name=excluded.name,description=excluded.description,category=excluded.category,module=excluded.module,sort_order=excluded.sort_order;

insert into workforce.role_permissions(role_code,permission_code) values
  ('admin','alegra_read'),('admin','alegra_import'),('supervisor','alegra_read')
on conflict do nothing;

create table alegra.import_batches (
  id uuid primary key,
  fingerprint text not null unique check(fingerprint ~ '^[0-9a-f]{64}$'),
  source text not null default 'Alegra Colombia',
  status text not null check(status in ('importing','completed','failed')),
  manifest jsonb not null,
  contacts_count integer not null default 0 check(contacts_count>=0),
  products_count integer not null default 0 check(products_count>=0),
  invoices_count integer not null default 0 check(invoices_count>=0),
  invoice_date_min date,
  invoice_date_max date,
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  check((status='completed')=(completed_at is not null)),
  check(invoice_date_min is null or invoice_date_max is null or invoice_date_min<=invoice_date_max)
);

create table alegra.contacts (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references alegra.import_batches(id) on delete restrict,
  source_key text not null unique check(source_key ~ '^[0-9a-f]{64}$'),
  full_name text not null check(length(btrim(full_name)) between 1 and 300),
  identification text,identification_type text,check_digit text,person_type text,tax_responsibility text,
  department text,municipality text,address text,postal_code text,country text,
  phone text,phone_2 text,mobile text,email text,email_2 text,status text,
  receivable_account text,payable_account text,payment_term text,price_list text,salesperson text,
  raw_data jsonb not null,
  imported_at timestamptz not null default clock_timestamp()
);
create index alegra_contacts_batch_name on alegra.contacts(batch_id,full_name);
create index alegra_contacts_identification on alegra.contacts(identification) where identification is not null;

create table alegra.products (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references alegra.import_batches(id) on delete restrict,
  source_code text not null unique,
  name text not null check(length(btrim(name)) between 1 and 300),
  reference text,category text,description text,tax_name text,tax_percentage numeric(9,6),tax_type text,
  unit text,product_service_code text,allow_negative_sale boolean not null default false,
  unit_cost numeric(20,6),barcode text,prices jsonb not null default '{}',warehouse_quantities jsonb not null default '{}',
  raw_data jsonb not null,
  imported_at timestamptz not null default clock_timestamp(),
  check(tax_percentage is null or tax_percentage between 0 and 100),
  check(unit_cost is null or unit_cost>=0)
);
create index alegra_products_batch_name on alegra.products(batch_id,name);

create table alegra.invoices (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references alegra.import_batches(id) on delete restrict,
  external_id text not null unique,
  number text not null,customer text not null,issued_on date not null,due_on date,
  total numeric(20,2) not null check(total>=0),balance numeric(20,2) not null check(balance>=0),
  status text not null check(status in ('Anulada','Borrador','Cobrada','Por cobrar')),
  raw_data jsonb not null,
  imported_at timestamptz not null default clock_timestamp(),
  check(balance<=total)
);
create index alegra_invoices_batch_date on alegra.invoices(batch_id,issued_on desc,external_id desc);
create index alegra_invoices_customer on alegra.invoices(batch_id,customer);
create index alegra_invoices_status on alegra.invoices(batch_id,status,issued_on desc);

alter table alegra.import_batches enable row level security;
alter table alegra.contacts enable row level security;
alter table alegra.products enable row level security;
alter table alegra.invoices enable row level security;
revoke all on all tables in schema alegra from public,anon,authenticated;
alter default privileges in schema alegra revoke all on tables from public,anon,authenticated;
alter default privileges in schema alegra revoke execute on functions from public,anon,authenticated;

create or replace function private.begin_alegra_import(p_id uuid,p_fingerprint text,p_manifest jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
begin
  if p_id is null or p_fingerprint !~ '^[0-9a-f]{64}$' or jsonb_typeof(p_manifest)<>'object' then
    raise exception 'Manifiesto de Alegra inválido.' using errcode='22023';
  end if;
  insert into alegra.import_batches(id,fingerprint,source,status,manifest,completed_at)
  values(p_id,p_fingerprint,coalesce(nullif(p_manifest->>'source',''),'Alegra Colombia'),'importing',p_manifest,null)
  on conflict(id) do update set
    fingerprint=excluded.fingerprint,source=excluded.source,status='importing',manifest=excluded.manifest,
    contacts_count=0,products_count=0,invoices_count=0,invoice_date_min=null,invoice_date_max=null,completed_at=null;
  return p_id;
end;
$$;
revoke all on function private.begin_alegra_import(uuid,text,jsonb) from public,anon,authenticated;

create or replace function private.import_alegra_rows(p_batch uuid,p_kind text,p_rows jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare affected integer;
begin
  if not exists(select 1 from alegra.import_batches b where b.id=p_batch and b.status='importing')
    or jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)>500 then
    raise exception 'Lote de Alegra inválido.' using errcode='22023';
  end if;
  if p_kind='contacts' then
    insert into alegra.contacts(
      batch_id,source_key,full_name,identification,identification_type,check_digit,person_type,tax_responsibility,
      department,municipality,address,postal_code,country,phone,phone_2,mobile,email,email_2,status,
      receivable_account,payable_account,payment_term,price_list,salesperson,raw_data
    ) select p_batch,r.source_key,r.full_name,r.identification,r.identification_type,r.check_digit,r.person_type,r.tax_responsibility,
      r.department,r.municipality,r.address,r.postal_code,r.country,r.phone,r.phone_2,r.mobile,r.email,r.email_2,r.status,
      r.receivable_account,r.payable_account,r.payment_term,r.price_list,r.salesperson,r.raw_data
    from jsonb_to_recordset(p_rows) as r(
      source_key text,full_name text,identification text,identification_type text,check_digit text,person_type text,tax_responsibility text,
      department text,municipality text,address text,postal_code text,country text,phone text,phone_2 text,mobile text,email text,email_2 text,status text,
      receivable_account text,payable_account text,payment_term text,price_list text,salesperson text,raw_data jsonb
    )
    on conflict(source_key) do update set
      batch_id=excluded.batch_id,full_name=excluded.full_name,identification=excluded.identification,
      identification_type=excluded.identification_type,check_digit=excluded.check_digit,person_type=excluded.person_type,
      tax_responsibility=excluded.tax_responsibility,department=excluded.department,municipality=excluded.municipality,
      address=excluded.address,postal_code=excluded.postal_code,country=excluded.country,phone=excluded.phone,phone_2=excluded.phone_2,
      mobile=excluded.mobile,email=excluded.email,email_2=excluded.email_2,status=excluded.status,
      receivable_account=excluded.receivable_account,payable_account=excluded.payable_account,payment_term=excluded.payment_term,
      price_list=excluded.price_list,salesperson=excluded.salesperson,raw_data=excluded.raw_data,imported_at=clock_timestamp();
  elsif p_kind='products' then
    insert into alegra.products(
      batch_id,source_code,name,reference,category,description,tax_name,tax_percentage,tax_type,unit,
      product_service_code,allow_negative_sale,unit_cost,barcode,prices,warehouse_quantities,raw_data
    ) select p_batch,r.source_code,r.name,r.reference,r.category,r.description,r.tax_name,r.tax_percentage,r.tax_type,r.unit,
      r.product_service_code,coalesce(r.allow_negative_sale,false),r.unit_cost,r.barcode,coalesce(r.prices,'{}'),coalesce(r.warehouse_quantities,'{}'),r.raw_data
    from jsonb_to_recordset(p_rows) as r(
      source_code text,name text,reference text,category text,description text,tax_name text,tax_percentage numeric,tax_type text,unit text,
      product_service_code text,allow_negative_sale boolean,unit_cost numeric,barcode text,prices jsonb,warehouse_quantities jsonb,raw_data jsonb
    )
    on conflict(source_code) do update set
      batch_id=excluded.batch_id,name=excluded.name,reference=excluded.reference,category=excluded.category,description=excluded.description,
      tax_name=excluded.tax_name,tax_percentage=excluded.tax_percentage,tax_type=excluded.tax_type,unit=excluded.unit,
      product_service_code=excluded.product_service_code,allow_negative_sale=excluded.allow_negative_sale,unit_cost=excluded.unit_cost,
      barcode=excluded.barcode,prices=excluded.prices,warehouse_quantities=excluded.warehouse_quantities,
      raw_data=excluded.raw_data,imported_at=clock_timestamp();
  elsif p_kind='invoices' then
    insert into alegra.invoices(batch_id,external_id,number,customer,issued_on,due_on,total,balance,status,raw_data)
    select p_batch,r.external_id,r.number,r.customer,r.issued_on,r.due_on,r.total,r.balance,r.status,r.raw_data
    from jsonb_to_recordset(p_rows) as r(
      external_id text,number text,customer text,issued_on date,due_on date,total numeric,balance numeric,status text,raw_data jsonb
    )
    on conflict(external_id) do update set
      batch_id=excluded.batch_id,number=excluded.number,customer=excluded.customer,issued_on=excluded.issued_on,
      due_on=excluded.due_on,total=excluded.total,balance=excluded.balance,status=excluded.status,
      raw_data=excluded.raw_data,imported_at=clock_timestamp();
  else
    raise exception 'Tipo de registro de Alegra inválido.' using errcode='22023';
  end if;
  get diagnostics affected=row_count;
  return affected;
end;
$$;
revoke all on function private.import_alegra_rows(uuid,text,jsonb) from public,anon,authenticated;

create or replace function private.finish_alegra_import(p_batch uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare expected_contacts integer;expected_products integer;expected_invoices integer;
declare actual_contacts integer;actual_products integer;actual_invoices integer;first_date date;last_date date;
begin
  select (manifest#>>'{counts,contacts}')::integer,(manifest#>>'{counts,products}')::integer,
    (manifest#>>'{counts,invoices}')::integer into expected_contacts,expected_products,expected_invoices
  from alegra.import_batches where id=p_batch and status='importing' for update;
  if not found then raise exception 'Importación de Alegra no disponible.' using errcode='22023'; end if;
  select count(*) into actual_contacts from alegra.contacts where batch_id=p_batch;
  select count(*) into actual_products from alegra.products where batch_id=p_batch;
  select count(*),min(issued_on),max(issued_on) into actual_invoices,first_date,last_date from alegra.invoices where batch_id=p_batch;
  if (actual_contacts,actual_products,actual_invoices) is distinct from (expected_contacts,expected_products,expected_invoices) then
    raise exception 'La importación de Alegra no reconcilia: %, %, %.',actual_contacts,actual_products,actual_invoices using errcode='23514';
  end if;
  update alegra.import_batches set status='completed',contacts_count=actual_contacts,products_count=actual_products,
    invoices_count=actual_invoices,invoice_date_min=first_date,invoice_date_max=last_date,completed_at=clock_timestamp()
  where id=p_batch;
  return jsonb_build_object('batch_id',p_batch,'contacts',actual_contacts,'products',actual_products,'invoices',actual_invoices,
    'invoice_date_min',first_date,'invoice_date_max',last_date);
end;
$$;
revoke all on function private.finish_alegra_import(uuid) from public,anon,authenticated;

create or replace function alegra.snapshot(
  p_kind text default 'summary',p_search text default '',p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor workforce.people:=workforce.require_person();batch alegra.import_batches;term text:=left(btrim(coalesce(p_search,'')),120);
declare start_row integer;total_rows bigint;items jsonb;
begin
  if not workforce.has_permission(actor,'alegra_read') then
    raise exception 'Tu rol no permite consultar el histórico de Alegra.' using errcode='42501';
  end if;
  if p_kind not in ('summary','contacts','products','invoices') or p_page not between 1 and 100000 or p_page_size not between 1 and 100 then
    raise exception 'Consulta de Alegra inválida.' using errcode='22023';
  end if;
  select * into batch from alegra.import_batches where status='completed' order by completed_at desc,id desc limit 1;
  if batch.id is null then return jsonb_build_object('ready',false,'kind',p_kind,'items','[]'::jsonb,'total',0); end if;
  if p_kind='summary' then
    return jsonb_build_object('ready',true,'kind','summary','batch',jsonb_build_object(
      'id',batch.id,'source',batch.source,'contacts',batch.contacts_count,'products',batch.products_count,
      'invoices',batch.invoices_count,'invoice_date_min',batch.invoice_date_min,'invoice_date_max',batch.invoice_date_max,
      'completed_at',batch.completed_at));
  end if;
  start_row:=(p_page-1)*p_page_size;
  if p_kind='contacts' then
    select count(*) into total_rows from alegra.contacts c where c.batch_id=batch.id and (
      term='' or c.full_name ilike '%'||term||'%' or coalesce(c.identification,'') ilike '%'||term||'%' or coalesce(c.email,'') ilike '%'||term||'%');
    select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.full_name,row_data.id),'[]'::jsonb) into items from (
      select c.id,c.full_name,c.identification,c.identification_type,c.person_type,c.department,c.municipality,c.address,c.country,
        c.phone,c.mobile,c.email,c.status,c.receivable_account,c.payable_account,c.payment_term,c.price_list,c.salesperson
      from alegra.contacts c where c.batch_id=batch.id and (
        term='' or c.full_name ilike '%'||term||'%' or coalesce(c.identification,'') ilike '%'||term||'%' or coalesce(c.email,'') ilike '%'||term||'%')
      order by c.full_name,c.id offset start_row limit p_page_size
    ) row_data;
  elsif p_kind='products' then
    select count(*) into total_rows from alegra.products p where p.batch_id=batch.id and (
      term='' or p.name ilike '%'||term||'%' or p.source_code ilike '%'||term||'%' or coalesce(p.category,'') ilike '%'||term||'%');
    select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.name,row_data.id),'[]'::jsonb) into items from (
      select p.id,p.source_code,p.name,p.reference,p.category,p.description,p.tax_name,p.tax_percentage,p.unit,
        p.allow_negative_sale,p.unit_cost,p.barcode,p.prices,p.warehouse_quantities
      from alegra.products p where p.batch_id=batch.id and (
        term='' or p.name ilike '%'||term||'%' or p.source_code ilike '%'||term||'%' or coalesce(p.category,'') ilike '%'||term||'%')
      order by p.name,p.id offset start_row limit p_page_size
    ) row_data;
  else
    select count(*) into total_rows from alegra.invoices i where i.batch_id=batch.id and (
      term='' or i.customer ilike '%'||term||'%' or i.number ilike '%'||term||'%' or i.status ilike '%'||term||'%');
    select coalesce(jsonb_agg(to_jsonb(row_data) order by row_data.issued_on desc,row_data.external_id desc),'[]'::jsonb) into items from (
      select i.id,i.external_id,i.number,i.customer,i.issued_on,i.due_on,i.total::text,i.balance::text,i.status
      from alegra.invoices i where i.batch_id=batch.id and (
        term='' or i.customer ilike '%'||term||'%' or i.number ilike '%'||term||'%' or i.status ilike '%'||term||'%')
      order by i.issued_on desc,i.external_id desc offset start_row limit p_page_size
    ) row_data;
  end if;
  return jsonb_build_object('ready',true,'kind',p_kind,'page',p_page,'page_size',p_page_size,'total',total_rows,'items',items);
end;
$$;
revoke all on function alegra.snapshot(text,text,integer,integer) from public,anon,authenticated;
grant execute on function alegra.snapshot(text,text,integer,integer) to authenticated;

create or replace function public.alegra_snapshot(
  p_kind text default 'summary',p_search text default '',p_page integer default 1,p_page_size integer default 50
) returns jsonb language sql stable security invoker set search_path='' as $$
  select alegra.snapshot(p_kind,p_search,p_page,p_page_size)
$$;
revoke all on function public.alegra_snapshot(text,text,integer,integer) from public,anon;
grant execute on function public.alegra_snapshot(text,text,integer,integer) to authenticated;

comment on schema alegra is 'Historical, read-only records imported from Alegra. Never posts operational finance or inventory.';
comment on function public.alegra_snapshot(text,text,integer,integer) is 'Permission-checked read-only access to the latest reconciled Alegra import.';
