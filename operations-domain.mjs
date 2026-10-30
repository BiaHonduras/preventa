export const SERVICE_SECONDS=360;
export const MIN_ORDER_AGE_SECONDS=48*3600;
export function durationText(seconds){const minutes=Math.max(0,Math.round(Number(seconds||0)/60));return `${Math.floor(minutes/60)} h ${String(minutes%60).padStart(2,'0')} min`;}
export function eligibleOrder(taken,departure){const a=Date.parse(taken),b=Date.parse(departure);return Number.isFinite(a)&&Number.isFinite(b)&&b-a>=MIN_ORDER_AGE_SECONDS*1000;}
export function plannedTotals(legs,serviceSeconds=SERVICE_SECONDS,bufferSeconds=0,returnSeconds=0){if(!Array.isArray(legs)||!legs.every(v=>Number.isFinite(v)&&v>=0)||![serviceSeconds,bufferSeconds,returnSeconds].every(v=>Number.isFinite(v)&&v>=0))throw Error('Tiempos inválidos');const travel=legs.reduce((a,b)=>a+b,0)+returnSeconds,service=legs.length*serviceSeconds;return {visits:legs.length,travel,service,buffer:bufferSeconds,total:travel+service+bufferSeconds};}
export function elapsedService(visit,now=new Date()){let seconds=Number(visit.service_seconds||0);if(visit.state==='visiting'&&visit.last_active_at)seconds+=Math.max(0,(Number(now)-Date.parse(visit.last_active_at))/1000);return seconds;}
export function mapStatus(visit){return ['visited','failed'].includes(visit.state)?{color:'#16a34a',label:'Visitado'}:visit.state==='visiting'?{color:'#eab308',label:'Visitando al Cliente'}:{color:'#dc2626',label:visit.state==='paused'?'Pendiente · pausado':'Pendiente'};}
export function routeCost(order,matrix){let sum=0;for(let i=1;i<order.length;i++)sum+=matrix[order[i-1]][order[i]];return sum;}
// Directed road-time matrix: never replace missing routes with straight-line estimates.
export function optimizeRoadOrder(matrix){
 const n=matrix.length;
 if(n<2||n>100||matrix.some(row=>!Array.isArray(row)||row.length!==n||row.some(x=>!Number.isFinite(x)||x<0)))throw Error('Hay clientes sin conexión de carretera. Revisa las ubicaciones.');
 const firsts=Array.from({length:n-1},(_,i)=>i+1).sort((a,b)=>matrix[0][a]-matrix[0][b]||a-b).slice(0,5);
 let best=[0,...Array.from({length:n-1},(_,i)=>i+1),0],bestCost=routeCost(best,matrix);
 for(const first of firsts){
  const left=new Set(Array.from({length:n-1},(_,i)=>i+1));const order=[0,first];left.delete(first);
  while(left.size){const current=order[order.length-1];let next=-1,cost=Infinity;for(const index of left)if(matrix[current][index]<cost){cost=matrix[current][index];next=index;}order.push(next);left.delete(next);}order.push(0);
  let cost=routeCost(order,matrix);
  for(let pass=0;pass<15;pass++){
   let change=false;
   outer:for(let a=1;a<order.length-2;a++)for(let b=a+1;b<order.length-1;b++){
    const candidate=[...order.slice(0,a),...order.slice(a,b+1).reverse(),...order.slice(b+1)];const candidateCost=routeCost(candidate,matrix);
    if(candidateCost+0.001<cost){order.splice(0,order.length,...candidate);cost=candidateCost;change=true;break outer;}
   }
   if(!change)break;
  }
  if(cost<bestCost){bestCost=cost;best=order;}
 }
 return {order:best,cost:bestCost};
}
