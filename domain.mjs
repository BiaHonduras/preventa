export const invoicePattern=/^\d{8}-\d{8}$/;
export function localDate(date=new Date()){return new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Tegucigalpa',year:'numeric',month:'2-digit',day:'2-digit'}).format(date)}
export function mondayOf(value){const d=new Date(value+'T12:00:00Z');const offset=(d.getUTCDay()+6)%7;d.setUTCDate(d.getUTCDate()-offset);return d.toISOString().slice(0,10)}
export function weeklyDeadline(monday){const d=new Date(monday+'T12:00:00Z');d.setUTCDate(d.getUTCDate()-3);return d.toISOString().slice(0,10)}
export function minutes(start,end){return Math.max(0,Math.round((new Date(end)-new Date(start))/60000))}
export function normalizeSite(site){return String(site).trim().toUpperCase()==='LA CEIBA'?'CBA':String(site).trim().toUpperCase()}
export function normalizeInvoices(rows){
 const invoices=new Map(),warnings=[];
 for(const row of rows){if(String(row.Comentario??'').trim().toLowerCase()!=='contado')continue;const number=String(row.NumDoc??'').trim();if(!invoicePattern.test(number)){warnings.push('Número inválido: '+number);continue}const sheet=String(row.Hoja??'').toUpperCase();if(!['FACTURAS_NC','FACTURAS_CONT'].includes(sheet)){warnings.push('Hoja desconocida: '+number);continue}
 let entry=invoices.get(number);if(!entry){entry={number,clientCode:null,clientName:'',route:String(row.RUTA_NUM??'').trim(),site:normalizeSite(row.Sucursal??''),date:String(row.FechaDoc??''),accounted:false,items:[],_source:sheet};invoices.set(number,entry)}
 if(sheet==='FACTURAS_NC'){entry.clientCode=String(row.ClienteNomb??'').trim()||entry.clientCode;entry.clientName=String(row.NomCliente??'').trim()||entry.clientName}else{entry.clientName=entry.clientName||String(row.ClienteNomb??'').trim();entry.accounted=true}
 // When a document exists in both sheets, use only CONT items. Never deduplicate repeated SKU lines within one sheet.
 if(sheet==='FACTURAS_CONT'&&entry._source==='FACTURAS_NC'){entry.items=[];entry._source=sheet}
 if(sheet!==entry._source)continue;const quantity=Number(row.Cantidad);if(!Number.isFinite(quantity)){warnings.push('Cantidad inválida: '+number);continue}entry.items.push({sku:String(row.ArtCodigo??''),description:String(row.ArtDescrip??''),quantity});
 }
 return {invoices:[...invoices.values()].map(({_source,...entry})=>entry),warnings};
}
export function mergeInvoices(existing,incoming){const map=new Map(existing.map(x=>[x.number,x]));for(const x of incoming){const old=map.get(x.number);map.set(x.number,{...old,...x,clientCode:x.clientCode||old?.clientCode||null,accounted:x.accounted||old?.accounted||false})}return [...map.values()]}
export function haversine(a,b){const rad=x=>x*Math.PI/180;const p=rad(b.lat-a.lat),q=rad(b.lng-a.lng);const value=Math.min(1,Math.max(0,Math.sin(p/2)**2+Math.cos(rad(a.lat))*Math.cos(rad(b.lat))*Math.sin(q/2)**2));return 6371*2*Math.atan2(Math.sqrt(value),Math.sqrt(1-value))}
export function suggestOrder(visits,clients,origin){const pending=visits.filter(v=>v.status==='pendiente');const located=pending.filter(v=>clients.find(c=>c.code===v.clientCode)?.location);const unlocated=pending.filter(v=>!located.includes(v));let point=origin||clients.find(c=>c.code===located[0]?.clientCode)?.location;const sorted=[];while(located.length){located.sort((a,b)=>haversine(point,clients.find(c=>c.code===a.clientCode).location)-haversine(point,clients.find(c=>c.code===b.clientCode).location));const visit=located.shift();sorted.push(visit);point=clients.find(c=>c.code===visit.clientCode).location}return [...sorted,...unlocated]}
