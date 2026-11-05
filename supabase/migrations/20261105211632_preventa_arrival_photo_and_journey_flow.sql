CREATE OR REPLACE FUNCTION bia_acl_private.preventa_photo_upload(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select exists(select 1 from bia_acl_private.preventa_photo_tickets t join public.preventa_work_visits v on v.id=t.visit_id where t.path=p_path and t.user_id=auth.uid() and t.used_at is null and t.created_at>now()-interval '15 minutes' and v.state in ('pending','visiting') and bia_acl_private.preventa_work_journey_write(v.journey_id))$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_photo_begin(p_visit uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.preventa_work_visits;j public.preventa_work_journeys;p text;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) or v.state not in ('pending','visiting') then raise exception 'VISITA_NO_DISPONIBLE';end if;

 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and id<>v.id and state in ('visiting','paused')) then raise exception 'FINALIZA_EL_CLIENTE_ACTUAL';end if;
 p:=auth.uid()::text||'/'||j.id::text||'/'||v.id::text||'/'||gen_random_uuid()::text||'.jpg';
 insert into bia_acl_private.preventa_photo_tickets(path,user_id,visit_id) values(p,auth.uid(),v.id);
 return jsonb_build_object('bucket','preventa-visitas','path',p);
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_arrive(p_visit uuid, p_photo text, p_lat double precision, p_lng double precision, p_accuracy double precision)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.preventa_work_visits;j public.preventa_work_journeys;t bia_acl_private.preventa_photo_tickets;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state='visiting' then return;end if;
 if v.state<>'pending' then raise exception 'ESTADO_DE_VISITA_INVALIDO';end if;
 if p_lat is null or p_lng is null or p_accuracy is null or not(p_lat between -90 and 90) or not(p_lng between -180 and 180) or not(p_accuracy between 0 and 100000) then raise exception 'GEOREFERENCIA_INVALIDA';end if;
 if j.departed_at is null then raise exception 'GUARDA_EL_RECORRIDO_PRIMERO';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and id<>v.id and state in ('visiting','paused')) then raise exception 'FINALIZA_EL_CLIENTE_ACTUAL';end if;
 select * into t from bia_acl_private.preventa_photo_tickets where path=p_photo and visit_id=v.id and user_id=auth.uid() and used_at is null and created_at>now()-interval '15 minutes' for update;
 if t.path is null or not exists(select 1 from storage.objects where bucket_id='preventa-visitas' and name=p_photo and metadata->>'mimetype'='image/jpeg') then raise exception 'FOTOGRAFIA_DE_INICIO_REQUERIDA';end if;
 update bia_acl_private.preventa_photo_tickets set used_at=now() where path=p_photo;
 update public.preventa_customer_schedule set latitude=p_lat,longitude=p_lng where site=v.site and code=v.customer_code and (latitude is distinct from p_lat or longitude is distinct from p_lng);
 update public.preventa_work_visits set state='visiting',arrived_at=now(),last_active_at=now(),arrival_lat=p_lat,arrival_lng=p_lng,arrival_accuracy=p_accuracy,photo_path=p_photo,version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'LLEGADA',jsonb_build_object('latitude',p_lat,'longitude',p_lng,'accuracy',p_accuracy,'photo',p_photo));
end$function$;
notify pgrst,'reload schema';