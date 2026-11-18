import { add, fromCents, money, toCents, validateDate } from '../finance';
import type { Actor, Money, Support } from '../finance/types';
import type { SalesReceipt, SalesReceiptApplication, SalesReceiptMovement, SalesReceiptStatus, SalesWorkspace } from './types';

const now=()=>new Date().toISOString();
const id=()=>crypto.randomUUID();

function auth(state:SalesWorkspace,actor:Actor){
  if(!state.members.some(row=>row.id===actor.id&&row.active&&row.role===actor.role))throw new Error('El usuario no está activo en este espacio.');
  if(!['owner','admin','treasury','accounting','sales'].includes(actor.role))throw new Error('Tu usuario no tiene permiso para gestionar recaudos.');
}
function text(value:string,label:string,minimum=1){const clean=value.trim();if(clean.length<minimum||clean.length>2000)throw new Error(`${label} es obligatorio.`);return clean;}
function support(value:Support){if(!value?.name||!['application/pdf','image/png','image/jpeg','image/webp'].includes(value.type)||value.size<=0||value.size>5*1024*1024||!value.dataUrl?.startsWith(`data:${value.type};base64,`))throw new Error('Adjunta el comprobante real en PDF, PNG, JPG o WebP, máximo 5 MB.');}
function stateWithReceipts(state:SalesWorkspace){const next=structuredClone(state) as SalesWorkspace&{salesModule:NonNullable<SalesWorkspace['salesModule']>};if(!next.salesModule)throw new Error('El módulo de Ventas no está disponible.');next.salesModule.receipts??=[];return next;}
function receipt(state:SalesWorkspace,receiptId:string){const row=(state.salesModule?.receipts??[]).find(item=>item.id===receiptId);if(!row)throw new Error('El recaudo no existe.');return row;}
function account(state:SalesWorkspace,accountId:string){const row=state.accounts.find(item=>item.id===accountId&&item.active&&item.kind!=='ledger');if(!row)throw new Error('Selecciona una cuenta receptora activa.');return row;}
function invoice(state:SalesWorkspace,invoiceId:string){const row=state.salesModule?.invoices.find(item=>item.id===invoiceId&&item.status!=='annulled');if(!row)throw new Error('La factura no está disponible.');return row;}
function audit(state:SalesWorkspace,actor:Actor,action:string,entityId:string,reason?:string){state.audit.unshift({id:id(),action,entityType:'sales_receipt',entityId,actorId:actor.id,actorName:actor.name,timestamp:now(),reason});}
function movementApplied(row:SalesReceipt,movementId:string){return add(...row.applications.filter(item=>item.movementId===movementId).map(item=>item.amount));}
function verifiedTotal(row:SalesReceipt){return add(...row.movements.filter(item=>item.status==='verified').map(item=>item.amount));}
function appliedTotal(row:SalesReceipt){return add(...row.applications.map(item=>item.amount));}
function deriveStatus(row:SalesReceipt):SalesReceiptStatus{
  const verified=row.movements.filter(item=>item.status==='verified').length;
  if(!verified)return'reported';
  if(verified<row.movements.length)return'partially_verified';
  const applied=toCents(appliedTotal(row));
  if(!applied)return'verified';
  return applied===toCents(verifiedTotal(row))?'applied':'partially_applied';
}

export interface ReportSalesReceiptInput {customerId:string;date:string;notes:string;movements:{accountId:string;amount:Money;method:'bank'|'cash'|'wallet';reference:string;support:Support;notes?:string}[]}

export function reportSalesReceipt(state:SalesWorkspace,input:ReportSalesReceiptInput,actor:Actor):SalesWorkspace{
  auth(state,actor);validateDate(input.date);
  if(!state.salesModule?.customers.some(row=>row.id===input.customerId&&row.active))throw new Error('Selecciona un cliente activo.');
  if(!input.movements.length)throw new Error('Agrega al menos un ingreso al recaudo.');
  const observations=input.notes.trim();
  if(input.movements.length>1&&observations.length<5)throw new Error('Explica en observaciones por qué el recaudo entró en varias cuentas.');
  const existing=(state.salesModule.receipts??[]).flatMap(row=>row.movements);
  const seen=new Set<string>();
  const movements:SalesReceiptMovement[]=input.movements.map(item=>{
    account(state,item.accountId);support(item.support);
    const amount=money(item.amount);if(toCents(amount)<=0n)throw new Error('Cada ingreso debe ser mayor que cero.');
    const reference=text(item.reference,'La referencia bancaria o de caja');
    const duplicateKey=`${item.accountId}:${reference.toUpperCase()}`;
    if(seen.has(duplicateKey)||existing.some(row=>`${row.accountId}:${row.reference.toUpperCase()}`===duplicateKey))throw new Error(`La referencia ${reference} ya fue registrada en esa cuenta.`);
    seen.add(duplicateKey);
    return{id:id(),accountId:item.accountId,amount,method:item.method,reference,support:item.support,notes:item.notes?.trim()??'',status:'reported'};
  });
  const next=stateWithReceipts(state);
  const record:SalesReceipt={id:id(),reference:`REC-${String(next.salesModule.receipts.length+1).padStart(5,'0')}`,customerId:input.customerId,date:input.date,notes:observations,status:'reported',movements,applications:[],createdBy:actor.id,createdAt:now()};
  next.salesModule.receipts.push(record);audit(next,actor,'Recaudo reportado; factura sin modificar',record.id,`${record.reference}: ${movements.length} ingreso(s)`);return next;
}

export function verifySalesReceiptMovement(state:SalesWorkspace,input:{receiptId:string;movementId:string;cashTransactionId:string;notes?:string},actor:Actor):SalesWorkspace{
  auth(state,actor);const source=receipt(state,input.receiptId);const movement=source.movements.find(row=>row.id===input.movementId);
  if(!movement||movement.status!=='reported')throw new Error('El ingreso no está pendiente de verificación.');
  const cash=state.transactions.find(row=>row.id===input.cashTransactionId&&row.kind==='income'&&row.status==='posted'&&!row.reversedBy);
  if(!cash||cash.amount!==movement.amount||!cash.entries.some(entry=>entry.accountId===movement.accountId&&entry.debit===movement.amount))throw new Error('Vincula un ingreso real de Caja por el mismo valor y en la misma cuenta.');
  const alreadyUsed=(state.salesModule?.receipts??[]).some(row=>row.movements.some(item=>item.cashTransactionId===cash.id));
  if(alreadyUsed||state.salesModule?.paymentReports.some(row=>row.cashTransactionId===cash.id))throw new Error('Ese ingreso de Caja ya verifica otro recaudo.');
  if(source.createdBy===actor.id&&!['owner','admin'].includes(actor.role))throw new Error('La verificación requiere otra persona autorizada.');
  const next=stateWithReceipts(state);const stored=next.salesModule.receipts.find(row=>row.id===source.id)!;const row=stored.movements.find(item=>item.id===movement.id)!;
  row.status='verified';row.cashTransactionId=cash.id;row.verifiedBy=actor.id;row.verifiedAt=now();if(input.notes?.trim())row.notes=[row.notes,input.notes.trim()].filter(Boolean).join(' · ');stored.status=deriveStatus(stored);
  audit(next,actor,source.createdBy===actor.id?'Ingreso verificado por administrador con excepción':'Ingreso verificado contra Caja',stored.id,`${row.reference} · ${cash.reference}`);return next;
}

export function applySalesReceipt(state:SalesWorkspace,input:{receiptId:string;applications:{movementId:string;invoiceId:string;amount:Money}[];notes?:string},actor:Actor):SalesWorkspace{
  auth(state,actor);const source=receipt(state,input.receiptId);if(!input.applications.length)throw new Error('Distribuye el recaudo al menos en una factura.');
  const invoiceCount=new Set(input.applications.map(row=>row.invoiceId)).size;
  if((invoiceCount>1||source.movements.length>1)&&`${source.notes} ${input.notes??''}`.trim().length<5)throw new Error('Las aplicaciones múltiples requieren una observación.');
  const next=stateWithReceipts(state);const stored=next.salesModule.receipts.find(row=>row.id===source.id)!;
  const movementTotals=new Map<string,bigint>();const invoiceTotals=new Map<string,bigint>();
  for(const application of input.applications){
    const movement=stored.movements.find(row=>row.id===application.movementId&&row.status==='verified');if(!movement)throw new Error('Cada aplicación debe usar un ingreso verificado.');
    const bill=invoice(next,application.invoiceId);if(bill.customerId!==stored.customerId)throw new Error('La factura no pertenece al cliente del recaudo.');
    const amount=money(application.amount);if(toCents(amount)<=0n)throw new Error('Cada aplicación debe ser mayor que cero.');
    movementTotals.set(movement.id,(movementTotals.get(movement.id)??0n)+toCents(amount));invoiceTotals.set(bill.id,(invoiceTotals.get(bill.id)??0n)+toCents(amount));
  }
  for(const[movementId,total]of movementTotals){const movement=stored.movements.find(row=>row.id===movementId)!;const remaining=toCents(movement.amount)-toCents(movementApplied(stored,movementId));if(total>remaining)throw new Error(`La distribución supera el saldo verificado del ingreso ${movement.reference}.`);}
  for(const[invoiceId,total]of invoiceTotals){const bill=invoice(next,invoiceId);if(total>toCents(bill.total)-toCents(bill.paid))throw new Error(`La distribución supera el saldo de la factura ${bill.reference}.`);}
  const appliedAt=now();
  for(const application of input.applications){const amount=money(application.amount);const record:SalesReceiptApplication={id:id(),movementId:application.movementId,invoiceId:application.invoiceId,amount,appliedBy:actor.id,appliedAt};stored.applications.push(record);const bill=invoice(next,application.invoiceId);bill.paid=fromCents(toCents(bill.paid)+toCents(amount));bill.status=bill.paid===bill.total?'paid':'partially_paid';bill.history.push({at:appliedAt,actorId:actor.id,action:`Recaudo ${stored.reference} aplicado`,reason:input.notes?.trim()||stored.notes||undefined});}
  stored.status=deriveStatus(stored);audit(next,actor,'Recaudo verificado aplicado a cartera',stored.id,input.notes?.trim()||`${input.applications.length} aplicación(es)`);return next;
}

export function getSalesReceipts(state:SalesWorkspace):SalesReceipt[]{return state.salesModule?.receipts??[];}
export function getReceiptTotal(row:SalesReceipt):Money{return add(...row.movements.map(item=>item.amount));}
export function getReceiptVerified(row:SalesReceipt):Money{return verifiedTotal(row);}
export function getReceiptApplied(row:SalesReceipt):Money{return appliedTotal(row);}
export function getReceiptUnapplied(row:SalesReceipt):Money{return fromCents(toCents(verifiedTotal(row))-toCents(appliedTotal(row)));}
export function getMovementUnapplied(row:SalesReceipt,movementId:string):Money{const movement=row.movements.find(item=>item.id===movementId);return movement?fromCents(toCents(movement.amount)-toCents(movementApplied(row,movementId))):'0.00';}
