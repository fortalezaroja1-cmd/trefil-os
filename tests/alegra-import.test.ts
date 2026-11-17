import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration=new URL('../supabase/migrations/20261117173000_alegra_legacy_import.sql',import.meta.url);
const view=new URL('../src/components/alegra-view.tsx',import.meta.url);
const app=new URL('../src/components/finance-app.tsx',import.meta.url);
const preparer=new URL('../scripts/alegra/prepare_import.py',import.meta.url);

test('Alegra history is isolated, permission checked and cannot post operational movements',async()=>{
  const sql=await readFile(migration,'utf8');
  assert.match(sql,/create schema if not exists alegra/);
  assert.match(sql,/revoke all on schema alegra from public,anon,authenticated/);
  assert.match(sql,/workforce\.has_permission\(actor,'alegra_read'\)/);
  assert.match(sql,/status text not null check\(status in \('importing','completed','failed'\)\)/);
  assert.match(sql,/private\.finish_alegra_import/);
  assert.match(sql,/actual_contacts,actual_products,actual_invoices/);
  assert.doesNotMatch(sql,/insert into public\.(financial_transactions|transaction_entries|accounts|debts)/);
  assert.doesNotMatch(sql,/insert into inventory\./);
});

test('Alegra UI exposes the complete reconciled source as read-only pages',async()=>{
  const source=await readFile(view,'utf8');
  const shell=await readFile(app,'utf8');
  assert.match(shell,/Histórico Alegra/);
  assert.match(shell,/<AlegraView\/>/);
  assert.match(source,/Histórico importado · solo lectura/);
  assert.match(source,/No crean movimientos en Caja/);
  assert.match(source,/Clientes y contactos/);
  assert.match(source,/Productos/);
  assert.match(source,/Facturas/);
  assert.match(source,/p_page_size:50/);
  assert.match(source,/\/acceso\//);
});

test('Alegra normalization preserves every expected source row and produces private seed files',async()=>{
  const source=await readFile(preparer,'utf8');
  assert.match(source,/len\(contacts\) != 545/);
  assert.match(source,/len\(products\) != 317/);
  assert.match(source,/len\(invoices\) != 6881/);
  assert.match(source,/invoice_date_min/);
  assert.match(source,/private\.import_alegra_rows/);
  assert.match(source,/must stay outside Git/);
});
