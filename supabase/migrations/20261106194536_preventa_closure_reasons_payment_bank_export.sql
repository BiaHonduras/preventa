alter table public.preventa_work_visits add column closure_reason text check(closure_reason in ('Exitoso','Fallido','Devolucion')), add column sub_reason text check(sub_reason in ('Negocio Cerrado','Sin Efectivo','No le interesa')), add column payment_method text check(payment_method in ('Efectivo','Pago con Tarjeta','Link de Pago'));
create table public.preventa_bank_stops(journey_id uuid primary key references public.preventa_work_journeys(id),started_at timestamptz,finished_at timestamptz,latitude double precision,longitude double precision,check(finished_at is null or (started_at is not null and finished_at>=started_at)));
alter table public.preventa_bank_stops enable row level security;
revoke all on public.preventa_bank_stops from public,anon,authenticated,preventa_operativo;
grant select on public.preventa_bank_stops to authenticated,preventa_operativo;
grant all on public.preventa_bank_stops to service_role;
create policy bank_stop_read on public.preventa_bank_stops for select to authenticated,preventa_operativo using(bia_acl_private.preventa_work_journey_read(journey_id));
create function bia_acl_private.preventa_add_bank_stop() returns trigger language plpgsql security definer set search_path='' as $$begin if new.kind='motorista' and new.departed_at is not null then insert into public.preventa_bank_stops(journey_id) values(new.id) on conflict do nothing;end if;return new;end$$;
revoke all on function bia_acl_private.preventa_add_bank_stop() from public,anon,authenticated,preventa_operativo;
create trigger preventa_bank_after_departure after update of departed_at on public.preventa_work_journeys for each row execute function bia_acl_private.preventa_add_bank_stop();
insert into public.preventa_bank_stops(journey_id) select id from public.preventa_work_journeys where kind='motorista' and departed_at is not null and ended_at is null and deleted_at is null on conflict do nothing;
create function public.preventa_ops_bank(p_journey uuid,p_action text,p_lat double precision default null,p_lng double precision default null) returns void language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;b public.preventa_bank_stops;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) or j.kind<>'motorista' or j.departed_at is null then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if p_lat is not null and (not(p_lat between -90 and 90) or p_lng is null or not(p_lng between -180 and 180)) then raise exception 'GEOREFERENCIA_INVALIDA';end if;
 select * into b from public.preventa_bank_stops where journey_id=j.id for update;
 if b.journey_id is null then raise exception 'BANCO_NO_DISPONIBLE';end if;
 if p_action='start' then
 if b.started_at is not null then return;end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state in ('visiting','paused')) then raise exception 'FINALIZA_EL_CLIENTE_ACTUAL';end if;
 update public.preventa_bank_stops set started_at=now(),latitude=p_lat,longitude=p_lng where journey_id=j.id;
 elsif p_action='finish' then
 if b.started_at is null then raise exception 'INICIA_BANCO_PRIMERO';end if;
 if b.finished_at is not null then return;end if;
 update public.preventa_bank_stops set finished_at=now() where journey_id=j.id;
 else raise exception 'ACCION_NO_PERMITIDA';end if;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),case when p_action='start' then 'INICIAR_BANCO' else 'FINALIZAR_BANCO' end,jsonb_build_object('misma_fecha',j.day=(now() at time zone 'America/Tegucigalpa')::date));
end$$;
revoke all on function public.preventa_ops_bank(uuid,text,double precision,double precision) from public,anon;
grant execute on function public.preventa_ops_bank(uuid,text,double precision,double precision) to authenticated,preventa_operativo;
CREATE OR REPLACE FUNCTION public.preventa_ops_finish_visit(p_visit uuid, p_outcome text, p_notes text DEFAULT ''::text, p_order_reference text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.preventa_work_visits;j public.preventa_work_journeys;oid uuid;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state<>'visiting' then raise exception 'LA_VISITA_NO_ESTA_EN_ATENCION';end if;
 if (j.kind='preventista' and p_outcome not in ('pedido','sin_pedido','fallido','devolucion')) or (j.kind='motorista' and p_outcome not in ('entregado','fallido','devolucion')) or p_outcome is null then raise exception 'RESULTADO_NO_PERMITIDO_PARA_ESTE_ACCESO';end if;
 if nullif(btrim(p_notes),'') is null then raise exception 'JUSTIFICACION_OBLIGATORIA';end if;
 if v.photo_path is null then raise exception 'FOTOGRAFIA_DE_CIERRE_REQUERIDA';end if;
 update public.preventa_work_visits set state=case when p_outcome in ('fallido','devolucion') then 'failed' else 'visited' end,finished_at=now(),service_seconds=service_seconds+greatest(0,extract(epoch from now()-last_active_at)),last_active_at=null,outcome=p_outcome,notes=left(p_notes,2000),version=version+1 where id=v.id;
 if p_outcome='pedido' then insert into public.preventa_work_orders(site,customer_code,taken_at,reference,visit_id,source,created_by) values(j.site,v.customer_code,now(),left(p_order_reference,120),v.id,'visita',auth.uid()) returning id into oid;end if;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'FINALIZAR_VISITA',jsonb_build_object('resultado',p_outcome,'notas',left(p_notes,2000),'pedido',oid));
end$function$;
create function public.preventa_ops_close_visit(p_visit uuid,p_reason text,p_subreason text default null,p_payment text default null,p_comment text default '',p_reference text default '') returns void language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;j public.preventa_work_journeys;result text;
begin
 select * into v from public.preventa_work_visits where id=p_visit; select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 if p_reason is null or p_reason not in ('Exitoso','Fallido','Devolucion') then raise exception 'MOTIVO_INVALIDO';end if;
 if p_reason='Fallido' and (p_subreason is null or p_subreason not in ('Negocio Cerrado','Sin Efectivo','No le interesa')) then raise exception 'SUBMOTIVO_OBLIGATORIO';end if;
 if p_payment is not null and p_payment not in ('Efectivo','Pago con Tarjeta','Link de Pago') then raise exception 'MODO_DE_PAGO_INVALIDO';end if;
 if j.kind='motorista' and p_reason='Exitoso' and p_payment is null then raise exception 'MODO_DE_PAGO_OBLIGATORIO';end if;
 result:=case when p_reason='Fallido' then 'fallido' when p_reason='Devolucion' then 'devolucion' when j.kind='motorista' then 'entregado' else 'pedido' end;
 perform public.preventa_ops_finish_visit(p_visit,result,coalesce(nullif(btrim(p_comment),''),p_reason),p_reference);
 update public.preventa_work_visits set closure_reason=p_reason,sub_reason=case when p_reason='Fallido' then p_subreason else null end,payment_method=p_payment,notes=left(p_comment,2000) where id=p_visit;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'MOTIVO_Y_PAGO',jsonb_build_object('motivo',p_reason,'submotivo',p_subreason,'pago',p_payment,'comentario',left(p_comment,2000)));
end$$;
revoke all on function public.preventa_ops_close_visit(uuid,text,text,text,text,text) from public,anon;
grant execute on function public.preventa_ops_close_visit(uuid,text,text,text,text,text) to authenticated,preventa_operativo;
CREATE OR REPLACE FUNCTION public.preventa_ops_snapshot(p_journey uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not bia_acl_private.preventa_work_journey_read(p_journey) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 return jsonb_build_object('server_now',now(),'bank',(select to_jsonb(b) from public.preventa_bank_stops b where journey_id=p_journey),'journey',(select to_jsonb(j) from public.preventa_work_journeys j where id=p_journey),'visits',(select coalesce(jsonb_agg(to_jsonb(v) order by seq),'[]') from public.preventa_work_visits v where journey_id=p_journey),'plan',(select to_jsonb(p) from public.preventa_work_plans p join public.preventa_work_journeys j on j.plan_id=p.id where j.id=p_journey));
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
 if exists(select 1 from public.preventa_bank_stops where journey_id=j.id and started_at is not null and finished_at is null) then raise exception 'FINALIZA_BANCO_PRIMERO';end if;
 if j.departed_at is null then raise exception 'GUARDA_EL_RECORRIDO_PRIMERO';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and id<>v.id and state in ('visiting','paused')) then raise exception 'FINALIZA_EL_CLIENTE_ACTUAL';end if;
 select * into t from bia_acl_private.preventa_photo_tickets where path=p_photo and visit_id=v.id and user_id=auth.uid() and used_at is null and created_at>now()-interval '15 minutes' for update;
 if t.path is null or not exists(select 1 from storage.objects where bucket_id='preventa-visitas' and name=p_photo and metadata->>'mimetype'='image/jpeg') then raise exception 'FOTOGRAFIA_DE_INICIO_REQUERIDA';end if;
 update bia_acl_private.preventa_photo_tickets set used_at=now() where path=p_photo;
 update public.preventa_customer_schedule set latitude=p_lat,longitude=p_lng where site=v.site and code=v.customer_code and (latitude is distinct from p_lat or longitude is distinct from p_lng);
 update public.preventa_work_visits set state='visiting',arrived_at=now(),last_active_at=now(),arrival_lat=p_lat,arrival_lng=p_lng,arrival_accuracy=p_accuracy,photo_path=p_photo,version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'LLEGADA',jsonb_build_object('latitude',p_lat,'longitude',p_lng,'accuracy',p_accuracy,'photo',p_photo));
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_end(p_journey uuid, p_reason text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.preventa_work_journeys;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state='visiting') then raise exception 'FINALIZA_O_PAUSA_EL_CLIENTE_ACTUAL';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state in ('pending','paused')) and nullif(btrim(p_reason),'') is null then raise exception 'INDICA_LA_DISPOSICION_DE_LOS_PENDIENTES';end if;
 if j.kind='motorista' and j.departed_at is not null and not exists(select 1 from public.preventa_bank_stops where journey_id=j.id and finished_at is not null) then raise exception 'FINALIZA_LA_PARADA_BANCO';end if;
 update public.preventa_work_visits set disposition=left(p_reason,2000),paused_seconds=paused_seconds+case when pause_started_at is not null then greatest(0,extract(epoch from now()-pause_started_at)) else 0 end,pause_started_at=null where journey_id=j.id and state in ('pending','paused');
 update public.preventa_work_journeys set ended_at=now(),end_reason=left(p_reason,2000),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'FINALIZAR_JORNADA',jsonb_build_object('motivo',left(p_reason,2000)));
end$function$;
create function public.preventa_ops_export(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.preventa_work_settings where bia_acl_private.preventa_work_manager(site)) then raise exception 'SIN_PERMISO_DE_EXPORTACION';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'RANGO_MAXIMO_366_DIAS';end if;
 return jsonb_build_object('generated_at',now(),
 'journeys',(select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('worker_name',w.name)),'[]') from public.preventa_work_journeys j join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site)),
 'visits',(select coalesce(jsonb_agg(to_jsonb(v)||jsonb_build_object('worker_name',w.name,'kind',j.kind,'day',j.day,'route_code',j.route_code,'worker_id',j.worker_id)),'[]') from public.preventa_work_visits v join public.preventa_work_journeys j on j.id=v.journey_id join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site)),
 'bank',(select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('worker_name',w.name,'day',j.day,'site',j.site,'worker_id',j.worker_id,'kind',j.kind,'route_code',j.route_code)),'[]') from public.preventa_bank_stops b join public.preventa_work_journeys j on j.id=b.journey_id join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site)));
end$$;
revoke all on function public.preventa_ops_export(date,date) from public,anon;
grant execute on function public.preventa_ops_export(date,date) to authenticated;
notify pgrst,'reload schema';