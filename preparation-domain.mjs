import {scheduledOn} from './customer-map-domain.mjs';
import {eligibleOrder} from './operations-domain.mjs';
export function preparationRows({kind,route,day,departure,fullCycle=false,customers=[],invoices=[],orders=[],query=''}){
 const q=query.trim().toLocaleLowerCase('es'),clients=new Map(customers.filter(c=>c.site==='SPS'&&c.active!==false).map(c=>[c.code,c]));
 const matches=row=>[row.name,row.code,row.invoice||''].join(' ').toLocaleLowerCase('es').includes(q);
 if(kind==='preventista')return [...clients.values()].filter(c=>(!route||c.presale_route===route)&&(fullCycle||scheduledOn(c,day,'presale'))).map(c=>({key:c.code,code:c.code,name:c.name,route:c.presale_route,detail:'Cliente · '+c.business_base,selectable:true})).filter(matches);
 const byInvoice=new Map(orders.filter(o=>o.site==='SPS'&&o.invoice_number).map(o=>[o.invoice_number,o]));
 return invoices.filter(i=>i.site==='SPS'&&i.presentInSource&&(!route||i.sourceRoute===route)).map(i=>{
  const order=byInvoice.get(i.number),c=order?clients.get(order.customer_code):null;
  const mature=!!order&&eligibleOrder(order.taken_at,departure);
  const reason=!order?'Pendiente de vincular con el pedido':!c?'Pendiente de vincular el punto de entrega':!mature?'El pedido aún no cumple 48 horas':'Disponible para entrega';
  return {key:i.number,invoice:i.number,code:c?.code||i.sourceClientCode||'',name:c?.name||i.clientName,route:i.sourceRoute,detail:'Factura '+i.number+' · '+reason,selectable:!!c&&mature};
 }).filter(matches);
}
export function combineSelection(selected,rows){return new Set([...selected,...rows.filter(r=>r.selectable).map(r=>r.key)]);}
