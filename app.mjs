import {createSessionMonitor} from './session.mjs?v=20261030-session';
import {createOperations} from './operations.mjs?v=20261030-ui2';
import {createCustomerMap} from './customer-map.mjs?v=20261030-ui2';
import {mergeCustomerSources} from './customer-map-domain.mjs?v=20261030';
import {createInvoiceSource,applySourceToState} from './invoices.mjs?v=20261030-clientes';
import {authenticate} from './access.mjs?v=20261030-session';
import {createCatalogs} from './catalogs.mjs?v=20261030-ui2';
import {localDate} from './domain.mjs';
const $=id=>document.getElementById(id),esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let authContext;try{authContext=await authenticate()}catch(error){document.getElementById('access-message').textContent=error.message;const retry=document.getElementById('access-retry');retry.hidden=false;retry.onclick=()=>location.reload();throw error}
const {supabase,profile,permissions}=authContext;
const day=localDate();const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('bia-preventa-trial-'+profile.id,1);r.onupgradeneeded=()=>r.result.createObjectStore('data');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)});
function read(){return new Promise((resolve,reject)=>{const r=db.transaction('data').objectStore('data').get('state');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error)})}
async function save(){return new Promise((resolve,reject)=>{const t=db.transaction('data','readwrite');t.objectStore('data').put(state,'state');t.oncomplete=()=>resolve();t.onerror=()=>reject(t.error)})}
function initial(){return {version:2,drivers:[],routes:[],clients:[],invoices:[],assignments:[],visits:[],journeys:[],audit:[]}}
let state=await read()||initial();await save();let view=permissions.overview?'overview':permissions.operate?'driver':'invoices',query='',clientPage=0,busy=false;
const catalog=createCatalogs({supabase,profile,permissions,onChange:({routes,drivers})=>{state.routes=routes.filter(r=>r.active).map(r=>r.name);state.drivers=drivers.filter(d=>d.active&&d.worker_kind!=='preventista').map(d=>d.name);},notify:text=>notice(text)});
try{await catalog.refresh()}catch(error){$('access-message').textContent=error.message;throw error}
let invoiceSource;
const customerMap=createCustomerMap({supabase,onRefresh:async()=>{if(invoiceSource)await invoiceSource.refresh()}});
invoiceSource=createInvoiceSource({supabase,getRoutes:()=>catalog.routes,onChange:async(documents,customers,routes)=>{applySourceToState(state,documents,mergeCustomerSources(customers,customerMap.rows),routes);await save()}});
try{await invoiceSource.refresh()}catch(error){$('access-message').textContent=error.message;throw error}
const operations=createOperations({supabase,profile,permissions,getCustomers:()=>customerMap.rows,getInvoices:()=>state.invoices,getRoutes:()=>catalog.routes,repaint:()=>render()});
function allowedView(next){return next==='catalogs'?permissions.manage:next==='planning'?permissions.plan:next==='overview'?permissions.overview:next==='driver'?permissions.operate:next==='clients'||next==='invoices'||next==='map'}
document.querySelectorAll('[data-view]').forEach(b=>b.hidden=!allowedView(b.dataset.view));
$('app-shell').hidden=false;$('access-gate').hidden=true;$('session-name').textContent=profile.nombre_corto;$('session-avatar').textContent=profile.nombre_corto.split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase();

function notice(text,error=false){$('notice').innerHTML=`<div class="notice${error?' error':''}">${esc(text)}</div>`;}
function heading(title,subtitle,actions=''){return `<div class="heading"><div><p class="eyebrow">PREVENTA</p><h1>${title}</h1><p class="subtitle">${subtitle}</p></div><div class="toolbar">${actions}</div></div>`;}
function modal(title,body){$('dialog-content').innerHTML=`<div class="dialog-head"><h2>${title}</h2><button class="close" aria-label="Cerrar diálogo" data-action="close">×</button></div>${body}`;$('dialog').showModal();}
function clients(){const list=state.clients.filter(c=>(c.name+' '+c.code+' '+c.route).toLowerCase().includes(query.toLowerCase()));const last=Math.max(0,Math.ceil(list.length/50)-1);clientPage=Math.min(clientPage,last);return heading('Clientes','Consulta los clientes por código, ruta y ubicación.',`<button class="secondary" data-action="go-map">Ver Mapa</button>`)+`<section class="card"><div class="filters"><label>Buscar cliente, código o ruta<input id="client-query" placeholder="Nombre, código o ruta" value="${esc(query)}"></label></div><div class="table-scroll"><table><thead><tr><th>CLIENTE</th><th>RUTA / SEDE</th><th>UBICACIÓN</th></tr></thead><tbody>${list.slice(clientPage*50,clientPage*50+50).map(c=>`<tr><td>${esc(c.name)}<small>${esc(c.sourceCode||c.code)}${c.provisional?' · provisional':''}</small></td><td>${esc(c.route)}<small>${esc(c.site)}${c.schedule?' · Entrega '+esc(c.schedule.deliveryRoute):''}</small></td><td>${(c.location||c.importedLocation)?`<a class="map" target="_blank" rel="noopener noreferrer" href="https://www.google.com/maps?q=${(c.location||c.importedLocation).lat},${(c.location||c.importedLocation).lng}">Ver ubicación ↗</a><small>${c.location?'Ubicación confirmada · precisión ±'+Math.round(c.location.accuracy)+' m':'Ubicación del archivo'}</small>`:'<span class="pill">Por capturar</span>'}</td></tr>`).join('')}</tbody></table></div><div class="card-body toolbar"><button class="secondary" data-action="clients-prev" ${clientPage===0?'disabled':''}>Anterior</button><span class="muted">${list.length} puntos · Página ${clientPage+1} de ${last+1}</span><button class="secondary" data-action="clients-next" ${clientPage===last?'disabled':''}>Siguiente</button></div></section>`}

function render(){customerMap.unmount();operations.unmount();document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===view));$('content').innerHTML=({overview:()=>operations.overviewHtml(),planning:()=>operations.preparationHtml(),driver:()=>operations.journeyHtml(),clients,map:()=>customerMap.html(),catalogs:()=>catalog.html(),invoices:()=>invoiceSource.html()}[view])();if(view==='map')customerMap.mount($('content'));if(['overview','planning','driver'].includes(view))operations.mount($('content'),view);}
document.addEventListener('click',async event=>{
 const nav=event.target.closest('[data-view]');if(nav){if(allowedView(nav.dataset.view)){view=nav.dataset.view;$('notice').replaceChildren();render();}return;}
 const b=event.target.closest('[data-invoice-action],[data-catalog],[data-action]');if(!b||b.disabled||busy)return;
 try{busy=true;
  if(b.dataset.invoiceAction){const action=b.dataset.invoiceAction;if(action==='refresh'){await invoiceSource.refresh();render();notice(invoiceSource.statusText());}if(action==='detail')modal('Productos de la factura',invoiceSource.detail(b.dataset.number));if(['prev','next'].includes(action)){invoiceSource.navigate(action==='prev'?-1:1);render();}}
  if(b.dataset.catalog){if(!permissions.manage)throw Error('Sin permiso para administrar el catálogo.');if(b.dataset.catalog==='refresh'){await catalog.refresh();await operations.refreshContext();render();}else modal(b.dataset.kind==='route'?'Ruta de Preventa':'Persona operativa',catalog.editor(b.dataset.kind,b.dataset.id));}
  if(b.dataset.action==='close')$('dialog').close();
  if(b.dataset.action==='go-map'){view='map';render();}
  if(b.dataset.action==='clients-prev'){clientPage=Math.max(0,clientPage-1);render();}
  if(b.dataset.action==='clients-next'){clientPage++;render();}
  if(b.dataset.action==='logout'){operations.unmount();const {error}=await supabase.auth.signOut();if(error)throw Error('No se pudo cerrar sesión.');location.replace('/intranet/intranet.html');}
 }catch(error){notice(error.message,true);}finally{busy=false;}
});
document.addEventListener('change',event=>{const el=event.target;if(['invoice-site','invoice-route'].includes(el.id)){invoiceSource.setFilter(el.id==='invoice-site'?'site':'route',el.value);render();}});
document.addEventListener('input',event=>{const el=event.target;if(!['invoice-query','client-query'].includes(el.id))return;const pos=el.selectionStart;if(el.id==='invoice-query')invoiceSource.setFilter('query',el.value);else{query=el.value;clientPage=0;}const id=el.id;render();$(id).focus();$(id).setSelectionRange(pos,pos);});
document.addEventListener('submit',async event=>{if(event.target.id!=='catalog-record-form')return;event.preventDefault();if(busy)return;busy=true;try{await catalog.save(event.target);await operations.refreshContext();$('dialog').close();render();}catch(error){notice(error.message,true);}finally{busy=false;}});
$('today').textContent=new Intl.DateTimeFormat('es-HN',{timeZone:'America/Tegucigalpa',dateStyle:'long'}).format(new Date());render();
customerMap.refresh().then(()=>{if(['clients','map','planning','driver'].includes(view))render();}).catch(error=>{if(view==='map')notice(error.message,true);});
function sessionNotice(message=''){const el=$('session-status');el.hidden=!message;el.textContent=message;}
function sessionExit(reason){try{sessionStorage.setItem('bia-preventa-session-exit',JSON.stringify({reason,at:new Date().toISOString()}));}catch{}operations.unmount();location.replace('/intranet/intranet.html');}
const sessionMonitor=createSessionMonitor({supabase,profile,onTemporary:()=>sessionNotice('No se pudo validar la conexión. Se reintentará automáticamente; los cambios necesitan conexión para guardarse.'),onValid:()=>sessionNotice(),onInvalid:sessionExit,onChanged:()=>location.reload(),onPassword:()=>location.replace('/control-tiempos/cambiar-password.html')});
// Keep auth callbacks synchronous; verification runs outside the auth client's lock.
supabase.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT')sessionMonitor.invalidate('signed_out');else if(['SIGNED_IN','TOKEN_REFRESHED','USER_UPDATED'].includes(event))setTimeout(()=>sessionMonitor.check(),0);});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)sessionMonitor.check();});
window.addEventListener('online',()=>sessionMonitor.check());
window.addEventListener('offline',()=>sessionNotice('Sin conexión. Los cambios necesitan conexión para guardarse. Se reintentará al reconectar.'));
setInterval(()=>{if(!document.hidden)sessionMonitor.check();},60000);
