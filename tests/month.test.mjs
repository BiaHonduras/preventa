import test from 'node:test';
import assert from 'node:assert/strict';
import {createInvoiceSource} from '../invoices.mjs';
import {createReporting} from '../reporting.mjs';

for(const [instant,from,to,next] of [
 ['2026-11-05T18:00:00Z','2026-11-01','2026-11-30','2026-12-01'],
 ['2026-12-31T18:00:00Z','2026-12-01','2026-12-31','2027-01-01'],
 ['2028-02-15T18:00:00Z','2028-02-01','2028-02-29','2028-03-01'],
 ['2026-03-01T02:00:00Z','2026-02-01','2026-02-28','2026-03-01']
]){
 test('monthly GP query and dashboard in Honduras: '+instant,async t=>{
  t.mock.timers.enable({apis:['Date'],now:new Date(instant)});
  const calls=[];
  const supabase={from(table){
   const q={select(){return this},order(){return this},range(){return this},
    eq(...args){calls.push([table,'eq',...args]);return this},
    gte(...args){calls.push([table,'gte',...args]);return this},
    lt(...args){calls.push([table,'lt',...args]);return this},
    maybeSingle(){return Promise.resolve({data:null,error:null})},
    then(resolve,reject){return Promise.resolve({data:[],error:null}).then(resolve,reject)}};
   return q;
  }};
  await createInvoiceSource({supabase,getRoutes:()=>[],onChange:()=>{}}).refresh();
  assert.ok(calls.some(c=>JSON.stringify(c)===JSON.stringify(['preventa_invoices','gte','issue_date',from])));
  assert.ok(calls.some(c=>JSON.stringify(c)===JSON.stringify(['preventa_invoices','lt','issue_date',next])));
  assert.ok(calls.some(c=>JSON.stringify(c)===JSON.stringify(['preventa_invoices','eq','present_in_source',true])));
  assert.ok(!calls.some(c=>c[0]==='preventa_customers'&&['gte','lt'].includes(c[1])));
  const report=createReporting({supabase,profile:{sedes:['SPS']},permissions:{manage:true},getWorkers:()=>[],getRoutes:()=>[]});
  const html=report.dashboardHtml();
  assert.ok(html.includes('value="'+from+'"'));
  assert.ok(html.includes('value="'+to+'"'));
 });
}

test('activity chart retains all 31 days and displays day numbers',async()=>{
 const trend=Array.from({length:31},(_,i)=>({day:'2026-12-'+String(i+1).padStart(2,'0'),completed:1,scheduled:2,deliveries:0}));
 const supabase={rpc:async()=>({data:{metrics:{},trend,most_visited:[],least_visited:[],slowest_customers:[],pause_reasons:[],routes:[],workers:[]},error:null})};
 const report=createReporting({supabase,profile:{sedes:['SPS']},permissions:{manage:true},getWorkers:()=>[],getRoutes:()=>[],repaint:()=>{}});
 const root={addEventListener(){},querySelector(){return null}};
 await report.mount(root,'dashboard');
 const html=report.dashboardHtml();
 assert.equal((html.match(/class="report-bar-col"/g)||[]).length,31);
 assert.ok(html.includes('<small>1</small>'));
 assert.ok(html.includes('<small>31</small>'));
 assert.ok(html.includes('title="2026-12-01:'));
 report.unmount();
});

