export const START_DATE='2026-11-03';
export const WEEKDAYS=['','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado','Domingo'];
const DAY=86400000;
function dateValue(value){
 if(!/^\d{4}-\d{2}-\d{2}$/.test(String(value)))throw Error('Selecciona una fecha válida.');
 const date=new Date(value+'T12:00:00Z');
 if(!Number.isFinite(date.getTime())||date.toISOString().slice(0,10)!==value)throw Error('Selecciona una fecha válida.');
 return date;
}
export function hondurasDay(now=new Date()){
 const p=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:'America/Tegucigalpa',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now).map(x=>[x.type,x.value]));
 return `${p.year}-${p.month}-${p.day}`;
}
export function cycleForDate(value,start=START_DATE){
 const date=dateValue(value),first=dateValue(start);
 if(date<first)return null;
 const monday=first.getTime()-((first.getUTCDay()+6)%7)*DAY;
 return {week:Math.floor((date.getTime()-monday)/(7*DAY))%2+1,day:date.getUTCDay()||7};
}
export function scheduledOn(point,date,mode='delivery'){
 const cycle=cycleForDate(date,point.start_date||START_DATE);
 return !!cycle&&cycle.day!==7&&Number(point[mode+'_day'])===cycle.day&&Number(point[mode+'_week'])===cycle.week;
}
export function nextVisit(point,from=START_DATE,mode='delivery'){
 let date=dateValue(from< (point.start_date||START_DATE)?point.start_date||START_DATE:from);
 for(let i=0;i<14;i++){
  const value=date.toISOString().slice(0,10);
  if(scheduledOn(point,value,mode))return value;
  date=new Date(date.getTime()+DAY);
 }
 return null;
}
export function filterPoints(points,filters={}){
 const {deliveryRoute='',presaleRoute='',businessBase='',search='',mode='delivery',date=START_DATE,allDates=false,week='',weekday=''}=filters;
 const q=search.trim().toLocaleLowerCase('es');
 return points.filter(p=>(!deliveryRoute||p.delivery_route===deliveryRoute)&&(!presaleRoute||p.presale_route===presaleRoute)&&(!businessBase||p.business_base===businessBase)&&(!q||[p.code,p.name,p.census].some(v=>String(v??'').toLocaleLowerCase('es').includes(q)))&&(allDates?(!week||Number(p[mode+'_week'])===Number(week))&&(!weekday||Number(p[mode+'_day'])===Number(weekday)):scheduledOn(p,date,mode)));
}
export function scheduleLabel(point,mode='delivery'){
 return `${WEEKDAYS[Number(point[mode+'_day'])]||'Sin día'} · Semana ${point[mode+'_week']||'—'}`;
}
export function validLocation(point){return Number.isFinite(point.latitude)&&Number.isFinite(point.longitude)&&Math.abs(point.latitude)<=90&&Math.abs(point.longitude)<=180;}
export function mergeCustomerSources(customers,points){
 const merged=new Map(customers.map(c=>[c.site+':'+c.code,c]));
 for(const p of points){const key=p.site+':'+p.code;merged.set(key,{...merged.get(key),site:p.site,code:p.code,name:p.name,source_route:p.presale_route,latitude:p.latitude,longitude:p.longitude,schedule:{deliveryRoute:p.delivery_route,deliveryDay:p.delivery_day,deliveryWeek:p.delivery_week,presaleDay:p.presale_day,presaleWeek:p.presale_week,businessBase:p.business_base,startDate:p.start_date}});}
 return [...merged.values()];
}
