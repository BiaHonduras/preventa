import {test} from 'node:test';
import assert from 'node:assert/strict';
import {optimizeRoadOrder,routeCost,plannedTotals,eligibleOrder,elapsedService,mapStatus} from './operations-domain.mjs';
test('70 clients retain every stop and depot roundtrip using asymmetric costs',()=>{
 const n=71,m=Array.from({length:n},(_,a)=>Array.from({length:n},(_,b)=>a===b?0:60+((a*7919+b*127+a*b*31)%5400)));
 const baseline=[0,...Array.from({length:70},(_,i)=>i+1),0];const {order,cost}=optimizeRoadOrder(m);
 assert.equal(order.length,72);assert.equal(order[0],0);assert.equal(order.at(-1),0);
 assert.deepEqual([...order.slice(1,-1)].sort((a,b)=>a-b),baseline.slice(1,-1));
 assert.equal(cost,routeCost(order,m));assert.ok(cost<=routeCost(baseline,m));
});
test('missing road connections reject, never substitute aerial distances',()=>{
 assert.throws(()=>optimizeRoadOrder([[0,null],[5,0]]));assert.throws(()=>optimizeRoadOrder([[0,Infinity],[5,0]]));
});
test('70 visits use seven hours service plus road roundtrip and separate buffer',()=>{
 assert.deepEqual(plannedTotals(Array(70).fill(60),360,1800,600),{visits:70,travel:4800,service:25200,buffer:1800,total:31800});
});
test('48 hours are exact across Honduras dates',()=>{
 const taken='2026-11-03T14:00:00-06:00';assert.equal(eligibleOrder(taken,'2026-11-05T13:59:59-06:00'),false);assert.equal(eligibleOrder(taken,'2026-11-05T14:00:00-06:00'),true);assert.equal(eligibleOrder('invalid',taken),false);
});
test('paused intervals are not active service and map states are distinct',()=>{
 assert.equal(elapsedService({state:'paused',service_seconds:120,last_active_at:null},new Date()),120);
 assert.equal(elapsedService({state:'visiting',service_seconds:120,last_active_at:'2026-11-03T20:00:00Z'},new Date('2026-11-03T20:01:00Z')),180);
 assert.equal(mapStatus({state:'paused'}).color,'#dc2626');assert.equal(mapStatus({state:'visiting'}).color,'#eab308');assert.equal(mapStatus({state:'failed'}).color,'#16a34a');
});
