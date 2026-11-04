create table public.preventa_invoice_points (
 invoice_number text primary key references public.preventa_invoices(number),
 site text not null check(site='SPS'), customer_code text not null,
 linked_by uuid not null, linked_at timestamptz not null default now(),
 foreign key(site,customer_code) references public.preventa_customer_schedule(site,code));
alter table public.preventa_invoice_points enable row level security;
revoke all on public.preventa_invoice_points from public,anon,authenticated,preventa_operativo;
grant select on public.preventa_invoice_points to authenticated,preventa_operativo;
grant all on public.preventa_invoice_points to service_role;
create policy invoice_points_read on public.preventa_invoice_points for select to authenticated,preventa_operativo using(public.bia_can('preventa','read',site));
create function public.preventa_ops_link_invoice_point(p_invoice text,p_customer text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not bia_acl_private.preventa_work_role('SPS','motorista') then raise exception 'SIN_PERMISO';end if;
 perform pg_advisory_xact_lock(hashtext('preventa-invoice-'||p_invoice));
 if not exists(select 1 from public.preventa_invoices where number=p_invoice and site='SPS' and present_in_source) or not exists(select 1 from public.preventa_customer_schedule where site='SPS' and code=p_customer and active) then raise exception 'FACTURA_O_CLIENTE_NO_DISPONIBLE';end if;
 if exists(select 1 from public.preventa_work_visits v join public.preventa_work_journeys j on j.id=v.journey_id where p_invoice=any(v.invoice_numbers) and j.deleted_at is null and (j.ended_at is null or v.outcome='entregado')) then raise exception 'FACTURA_YA_ASIGNADA_O_ENTREGADA';end if;
 if exists(select 1 from public.preventa_work_orders where invoice_number=p_invoice and deleted_at is null and customer_code<>p_customer) then raise exception 'CLIENTE_DIFIERE_DEL_PEDIDO';end if;
 insert into public.preventa_invoice_points(invoice_number,site,customer_code,linked_by) values(p_invoice,'SPS',p_customer,auth.uid()) on conflict(invoice_number) do update set customer_code=excluded.customer_code,linked_by=excluded.linked_by,linked_at=now();
end$$;
revoke all on function public.preventa_ops_link_invoice_point(text,text) from public,anon;
grant execute on function public.preventa_ops_link_invoice_point(text,text) to authenticated,preventa_operativo;


CREATE OR REPLACE FUNCTION public.preventa_ops_create_plan(p_kind text, p_site text, p_route text, p_day date, p_departure timestamp with time zone, p_keys text[], p_worker uuid DEFAULT NULL::uuid, p_journey uuid DEFAULT NULL::uuid, p_buffer_minutes integer DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.preventa_work_journeys;out_id uuid;n int;missing int;
begin
 if p_kind not in ('preventista','motorista') or p_site<>'SPS' or p_day is null or (p_departure at time zone 'America/Tegucigalpa')::date<>p_day or extract(isodow from p_day)=7 then raise exception 'DATOS_DE_PLAN_INVALIDOS';end if;
 if p_buffer_minutes not between 0 and 1440 or coalesce(cardinality(p_keys),0) not between 1 and 300 then raise exception 'SELECCION_DE_CLIENTES_INVALIDA';end if;
 if p_journey is null then if not bia_acl_private.preventa_work_role(p_site,p_kind) then raise exception 'PREPARACION_NO_AUTORIZADA';end if;if not bia_acl_private.preventa_work_manager(p_site) and p_worker is null then raise exception 'SELECCIONA_LA_PERSONA_OPERATIVA';end if;
 else
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(p_journey) or j.departed_at is not null or j.site<>p_site or j.kind<>p_kind or j.route_code<>p_route or j.day<>p_day then raise exception 'JORNADA_NO_ADMITE_PREPARACION';end if;
 p_worker:=j.worker_id;
 end if;
 if not exists(select 1 from public.preventa_routes where code=p_route and site=p_site and active) then raise exception 'RUTA_NO_DISPONIBLE';end if;
 if p_worker is not null and not exists(select 1 from public.preventa_drivers w where w.id=p_worker and w.active and w.site=p_site and w.worker_kind=p_kind and bia_acl_private.preventa_worker_route_allowed(w.id,p_route) and (p_kind<>'preventista' or w.assigned_route=p_route)) then raise exception 'PERSONAL_NO_CORRESPONDE_AL_PLAN';end if;
 if p_kind='preventista' then
 select count(distinct code) into n from public.preventa_customer_schedule where site=p_site and active and code=any(p_keys) and exists(select 1 from public.preventa_routes r where r.code=preventa_customer_schedule.presale_route and r.site=p_site and r.active) and (p_worker is null or bia_acl_private.preventa_worker_route_allowed(p_worker,presale_route));
 if n<>(select count(distinct x) from unnest(p_keys) x) then raise exception 'CLIENTES_FUERA_DE_LAS_RUTAS_PERMITIDAS';end if;
 else
 perform pg_advisory_xact_lock(hashtext('preventa-invoice-'||x)) from (select distinct unnest(p_keys) x order by x) keys;
 select count(*) into missing from unnest(p_keys) x where not exists(select 1 from public.preventa_invoices i left join public.preventa_work_orders o on o.invoice_number=i.number and o.deleted_at is null left join public.preventa_invoice_points ip on ip.invoice_number=i.number join public.preventa_customer_schedule c on c.site=i.site and c.code=coalesce(o.customer_code,ip.customer_code,i.client_code) and c.active where i.number=x and i.site=p_site and i.present_in_source);
 if missing>0 then raise exception 'FACTURA_SIN_CLIENTE_VERIFICADO';end if;
 select count(distinct c.code) into n from public.preventa_invoices i left join public.preventa_work_orders o on o.invoice_number=i.number and o.deleted_at is null left join public.preventa_invoice_points ip on ip.invoice_number=i.number join public.preventa_customer_schedule c on c.site=i.site and c.code=coalesce(o.customer_code,ip.customer_code,i.client_code) and c.active where i.site=p_site and i.number=any(p_keys) and i.present_in_source;
 end if;
 if n not between 1 and 99 then raise exception 'EL_RECORRIDO_ADMITE_DE_1_A_99_CLIENTES';end if;
 insert into public.preventa_work_plans(site,route_code,kind,day,departure_at,worker_id,created_by,journey_id,stop_count,service_seconds,buffer_seconds) select p_site,p_route,p_kind,p_day,p_departure,p_worker,auth.uid(),p_journey,n,s.service_seconds,p_buffer_minutes*60 from public.preventa_work_settings s where site=p_site returning id into out_id;
 if out_id is null then raise exception 'SEDE_SIN_CONFIGURAR';end if;
 if p_kind='preventista' then
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude from public.preventa_customer_schedule c where c.site=p_site and c.code=any(p_keys);
 else
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers)
 select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude,coalesce(array_agg(distinct o.id) filter(where o.id is not null),'{}'::uuid[]),array_agg(distinct i.number)
 from public.preventa_invoices i left join public.preventa_work_orders o on o.invoice_number=i.number and o.deleted_at is null left join public.preventa_invoice_points ip on ip.invoice_number=i.number join public.preventa_customer_schedule c on c.site=i.site and c.code=coalesce(o.customer_code,ip.customer_code,i.client_code) and c.active where i.site=p_site and i.number=any(p_keys) and i.present_in_source group by c.code,c.name,c.latitude,c.longitude;
 end if;return out_id;
end$function$;


CREATE OR REPLACE FUNCTION bia_acl_private.preventa_worker_route_allowed(p_worker uuid, p_route text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
select exists(select 1 from public.preventa_drivers w join public.preventa_routes r on r.site=w.site and r.code=p_route and r.active where w.id=p_worker and w.active and (w.worker_kind='motorista' or w.assigned_route=r.code or exists(select 1 from bia_acl_private.preventa_worker_routes x where x.worker_id=w.id and x.route_code=r.code)))
$function$;


CREATE OR REPLACE FUNCTION public.preventa_ops_apply_plan(p_journey uuid, p_plan uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.preventa_work_journeys;p public.preventa_work_plans;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if j.plan_id=p_plan then return;end if;
 if j.departed_at is not null then raise exception 'RECORRIDO_YA_INICIADO';end if;
 select * into p from public.preventa_work_plans where id=p_plan for update;
 if p.id is null or p.deleted_at is not null or p.status<>'ready' or p.site<>j.site or p.kind<>j.kind or p.route_code<>j.route_code or p.day<>j.day or (p.worker_id is not null and p.worker_id<>j.worker_id) or (p.journey_id is not null and p.journey_id<>j.id) then raise exception 'PLAN_NO_CORRESPONDE_A_LA_JORNADA';end if;
 if not bia_acl_private.preventa_worker_route_allowed(j.worker_id,j.route_code) or exists(select 1 from public.preventa_work_plan_stops s join public.preventa_customer_schedule c on c.site=j.site and c.code=s.customer_code where s.plan_id=p.id and not bia_acl_private.preventa_worker_route_allowed(j.worker_id,c.presale_route)) then raise exception 'RUTAS_NO_HABILITADAS_PARA_LA_PERSONA';end if;
 if j.kind='motorista' then
 perform pg_advisory_xact_lock(hashtext('preventa-invoice-'||x)) from (select distinct unnest(invoice_numbers) x from public.preventa_work_plan_stops where plan_id=p.id order by x) keys;
 if exists(select 1 from public.preventa_work_plan_stops ps cross join lateral unnest(ps.invoice_numbers) num left join public.preventa_invoices i on i.number=num where ps.plan_id=p.id and not coalesce(i.present_in_source,false)) then raise exception 'FACTURA_NO_DISPONIBLE';end if;
 if exists(select 1 from public.preventa_work_plan_stops ps join public.preventa_work_visits v on v.invoice_numbers && ps.invoice_numbers join public.preventa_work_journeys other on other.id=v.journey_id where ps.plan_id=p.id and other.id<>j.id and other.deleted_at is null and (other.ended_at is null or v.outcome='entregado')) then raise exception 'FACTURA_YA_ASIGNADA_O_ENTREGADA';end if;
 end if;
 insert into public.preventa_work_visits(journey_id,seq,site,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers,expected_leg_seconds,expected_service_seconds) select j.id,s.seq,j.site,s.customer_code,s.customer_name,s.latitude,s.longitude,s.order_ids,s.invoice_numbers,s.leg_seconds,p.service_seconds from public.preventa_work_plan_stops s where s.plan_id=p.id order by s.seq;
 update public.preventa_work_plans set status='used',worker_id=j.worker_id where id=p.id;
 update public.preventa_work_journeys set plan_id=p.id,departed_at=now(),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'INICIAR_RECORRIDO',jsonb_build_object('plan',p.id,'paradas',p.stop_count));
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
 update public.preventa_customer_schedule set latitude=p_lat,longitude=p_lng where site=v.site and code=v.customer_code and (latitude is distinct from p_lat or longitude is distinct from p_lng);
 update public.preventa_work_visits set state='visiting',arrived_at=now(),last_active_at=now(),arrival_lat=p_lat,arrival_lng=p_lng,arrival_accuracy=p_accuracy,version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'LLEGADA',jsonb_build_object('latitude',p_lat,'longitude',p_lng,'accuracy',p_accuracy,'photo_at_finish',true));
end$function$;


CREATE OR REPLACE FUNCTION public.preventa_ops_photo_begin(p_visit uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.preventa_work_visits;j public.preventa_work_journeys;p text;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) or v.state<>'visiting' then raise exception 'VISITA_NO_DISPONIBLE';end if;

 p:=auth.uid()::text||'/'||j.id::text||'/'||v.id::text||'/'||gen_random_uuid()::text||'.jpg';
 insert into bia_acl_private.preventa_photo_tickets(path,user_id,visit_id) values(p,auth.uid(),v.id);
 return jsonb_build_object('bucket','preventa-visitas','path',p);
end$function$;


CREATE OR REPLACE FUNCTION bia_acl_private.preventa_photo_upload(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select exists(select 1 from bia_acl_private.preventa_photo_tickets t join public.preventa_work_visits v on v.id=t.visit_id where t.path=p_path and t.user_id=auth.uid() and t.used_at is null and t.created_at>now()-interval '15 minutes' and v.state='visiting' and bia_acl_private.preventa_work_journey_write(v.journey_id))$function$;


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
 if (j.kind='preventista' and p_outcome not in ('pedido','sin_pedido','fallido')) or (j.kind='motorista' and p_outcome not in ('entregado','fallido')) or p_outcome is null then raise exception 'RESULTADO_NO_PERMITIDO_PARA_ESTE_ACCESO';end if;
 if nullif(btrim(p_notes),'') is null then raise exception 'JUSTIFICACION_OBLIGATORIA';end if;
 if v.photo_path is null then raise exception 'FOTOGRAFIA_DE_CIERRE_REQUERIDA';end if;
 update public.preventa_work_visits set state=case when p_outcome='fallido' then 'failed' else 'visited' end,finished_at=now(),service_seconds=service_seconds+greatest(0,extract(epoch from now()-last_active_at)),last_active_at=null,outcome=p_outcome,notes=left(p_notes,2000),version=version+1 where id=v.id;
 if p_outcome='pedido' then insert into public.preventa_work_orders(site,customer_code,taken_at,reference,visit_id,source,created_by) values(j.site,v.customer_code,now(),left(p_order_reference,120),v.id,'visita',auth.uid()) returning id into oid;end if;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'FINALIZAR_VISITA',jsonb_build_object('resultado',p_outcome,'notas',left(p_notes,2000),'pedido',oid));
end$function$;


create function public.preventa_ops_finish_with_photo(p_visit uuid,p_photo text,p_outcome text,p_notes text,p_order_reference text default '') returns void language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;t bia_acl_private.preventa_photo_tickets;
begin
 select * into v from public.preventa_work_visits where id=p_visit;
 perform 1 from public.preventa_work_journeys where id=v.journey_id for update;
 if auth.uid() is null or not bia_acl_private.preventa_work_journey_write(v.journey_id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state<>'visiting' then raise exception 'LA_VISITA_NO_ESTA_EN_ATENCION';end if;
 select * into t from bia_acl_private.preventa_photo_tickets where path=p_photo and visit_id=p_visit and user_id=auth.uid() and used_at is null and created_at>now()-interval '15 minutes' for update;
 if t.path is null or not exists(select 1 from storage.objects where bucket_id='preventa-visitas' and name=p_photo and metadata->>'mimetype'='image/jpeg') then raise exception 'FOTOGRAFIA_DE_CIERRE_REQUERIDA';end if;
 update public.preventa_work_visits set photo_path=p_photo where id=p_visit;
 perform public.preventa_ops_finish_visit(p_visit,p_outcome,p_notes,p_order_reference);
 update bia_acl_private.preventa_photo_tickets set used_at=now() where path=p_photo;
end$$;
revoke all on function public.preventa_ops_finish_with_photo(uuid,text,text,text,text) from public,anon;
grant execute on function public.preventa_ops_finish_with_photo(uuid,text,text,text,text) to authenticated,preventa_operativo;
notify pgrst,'reload schema';