import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.95.0';
import {optimizeRoadOrder} from './operations-domain.mjs';
const headers={'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':'https://biahonduras.github.io','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
const answer=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers});
 if(req.method!=='POST')return answer({error:'METODO_NO_PERMITIDO'},405);
 try{
  const authorization=req.headers.get('Authorization')||'';if(!authorization.startsWith('Bearer '))return answer({error:'INICIA_SESION'},401);
  const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const userClient=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:auth,error:authError}=await userClient.auth.getUser();if(authError||!auth?.user)return answer({error:'SESION_INVALIDA'},401);
  const body=await req.json();if(typeof body.plan_id!=='string'||!/^[a-f0-9-]{36}$/i.test(body.plan_id))return answer({error:'PLAN_INVALIDO'},400);
  const {data:plan,error}=await userClient.from('preventa_work_plans').select('*').eq('id',body.plan_id).single();if(error||!plan)return answer({error:'PLAN_NO_DISPONIBLE'},403);
  if(['ready','used'].includes(plan.status))return answer({ok:true,plan_id:plan.id,cached:true});if(plan.status!=='draft')return answer({error:'PLAN_NO_DISPONIBLE'},409);
  if(plan.created_by!==auth.user.id)return answer({error:'SOLO_EL_CREADOR_PUEDE_CALCULAR_EL_BORRADOR'},403);
  const [{data:stops,error:stopError},{data:settings,error:settingError}]=await Promise.all([userClient.from('preventa_work_plan_stops').select('*').eq('plan_id',plan.id).order('seq'),userClient.from('preventa_work_settings').select('*').eq('site',plan.site).single()]);
  if(stopError||settingError||!settings||!stops?.length||stops.length>99)throw Error('NO_SE_PUEDE_PREPARAR_EL_RECORRIDO');
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  async function road(path:string){
   const {data:slot,error}=await admin.rpc('preventa_ops_routing_slot');if(error)throw Error('NO_SE_PUDO_RESERVAR_EL_CALCULO');const delay=Math.max(0,Date.parse(slot)-Date.now());if(delay>25000)throw Error('HAY_OTROS_CALCULOS_EN_CURSO_INTENTA_EN_UN_MINUTO');if(delay)await new Promise(r=>setTimeout(r,delay));
   const response=await fetch('https://routing.openstreetmap.de/routed-car/'+path,{headers:{'User-Agent':'BIA-Preventa/1.0 (+https://biahonduras.github.io/preventa/)','Referer':'https://biahonduras.github.io/preventa/'},signal:AbortSignal.timeout(45000)});
   if(!response.ok)throw Error('EL_SERVICIO_DE_CARRETERAS_NO_ESTA_DISPONIBLE');const result=await response.json();if(result.code!=='Ok')throw Error('HAY_UBICACIONES_SIN_CONEXION_DE_CARRETERA');return result;
  }
  const coordinates=[[settings.depot_lng,settings.depot_lat],...stops.map(s=>[s.longitude,s.latitude])];
  const table=await road('table/v1/driving/'+coordinates.map(p=>p.join(',')).join(';')+'?annotations=duration');
  const optimized=optimizeRoadOrder(table.durations);
  const orderedCoords=optimized.order.map(i=>coordinates[i]);
  // Split long roundtrips without changing stop order; adjacent chunks share a boundary point.
  const parts=[];
  for(let start=0;start<orderedCoords.length-1;start+=89){const chunk=orderedCoords.slice(start,start+90);const response=await road('route/v1/driving/'+chunk.map(p=>p.join(',')).join(';')+'?overview=full&geometries=geojson&steps=false');const part=response.routes?.[0];if(!part||part.legs?.length!==chunk.length-1||!part.geometry?.coordinates?.length)throw Error('RESPUESTA_DE_CARRETERAS_INCOMPLETA');parts.push(part);}
  const result={legs:parts.flatMap(p=>p.legs),distance:parts.reduce((n,p)=>n+p.distance,0),geometry:{type:'LineString',coordinates:parts.flatMap((p,i)=>i?p.geometry.coordinates.slice(1):p.geometry.coordinates)}};if(!result||result.legs?.length!==stops.length+1||result.legs.some(l=>!Number.isFinite(l.duration)||l.duration<0||!Number.isFinite(l.distance)||l.distance<0)||!result.geometry?.coordinates?.length)throw Error('RESPUESTA_DE_CARRETERAS_INCOMPLETA');
  const legs=result.legs.slice(0,-1).map(l=>({seconds:l.duration,meters:l.distance}));
  const ordered=optimized.order.slice(1,-1).map(i=>stops[i-1].id);
  const saved=await admin.rpc('preventa_ops_store_route',{p_plan:plan.id,p_actor:auth.user.id,p_order:ordered,p_legs:legs,p_return:result.legs.at(-1).duration,p_distance:result.distance,p_geometry:result.geometry});if(saved.error)throw Error(saved.error.message);
  return answer({ok:true,plan_id:plan.id,provider:'OSRM',traffic:false});
 }catch(error){return answer({error:error instanceof Error?error.message:'NO_SE_PUDO_CALCULAR_LA_RUTA'},400);}
});
