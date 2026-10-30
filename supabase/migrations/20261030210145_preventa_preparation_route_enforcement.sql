CREATE OR REPLACE FUNCTION public.preventa_ops_start(p_worker uuid, p_route text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.preventa_drivers;j public.preventa_work_journeys;out_id uuid;
begin
 select * into w from public.preventa_drivers where id=p_worker and active for share;
 if w.id is null or not bia_acl_private.preventa_work_role(w.site,w.worker_kind) then raise exception 'PERSONAL_NO_AUTORIZADO';end if;
 if not exists(select 1 from public.preventa_routes where code=p_route and site=w.site and active) then raise exception 'RUTA_NO_DISPONIBLE';end if;
 if not bia_acl_private.preventa_worker_route_allowed(w.id,p_route) then raise exception 'RUTA_NO_HABILITADA_PARA_LA_PERSONA';end if;
 if w.worker_kind='preventista' and w.assigned_route is distinct from p_route then raise exception 'RUTA_NO_ASIGNADA_AL_PREVENTISTA';end if;
 perform pg_advisory_xact_lock(hashtext('preventa-worker-'||p_worker));
 select * into j from public.preventa_work_journeys where worker_id=p_worker and ended_at is null;
 if j.id is not null then if j.actor=auth.uid() then return j.id;else raise exception 'PERSONAL_CON_JORNADA_ACTIVA';end if;end if;
 insert into public.preventa_work_journeys(site,route_code,kind,worker_id,actor) values(w.site,p_route,w.worker_kind,p_worker,auth.uid()) returning id into out_id;
 insert into public.preventa_work_events(journey_id,actor,action) values(out_id,auth.uid(),'INICIAR_JORNADA');return out_id;
end$function$;
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
 select count(*) into missing from unnest(p_keys) x where not exists(select 1 from public.preventa_work_orders o join public.preventa_invoices i on i.number=o.invoice_number and i.present_in_source where (o.id::text=x or o.invoice_number=x) and o.site=p_site and o.taken_at+interval '48 hours'<=p_departure and exists(select 1 from public.preventa_customer_schedule c where c.site=o.site and c.code=o.customer_code and c.active and (p_worker is null or bia_acl_private.preventa_worker_route_allowed(p_worker,c.presale_route))));
 if missing>0 then raise exception 'PEDIDOS_SIN_FACTURA_O_SIN_48_HORAS';end if;
 select count(distinct customer_code) into n from public.preventa_work_orders where id::text=any(p_keys) or invoice_number=any(p_keys);
 end if;
 if n not between 1 and 99 then raise exception 'EL_RECORRIDO_ADMITE_DE_1_A_99_CLIENTES';end if;
 insert into public.preventa_work_plans(site,route_code,kind,day,departure_at,worker_id,created_by,journey_id,stop_count,service_seconds,buffer_seconds) select p_site,p_route,p_kind,p_day,p_departure,p_worker,auth.uid(),p_journey,n,s.service_seconds,p_buffer_minutes*60 from public.preventa_work_settings s where site=p_site returning id into out_id;
 if out_id is null then raise exception 'SEDE_SIN_CONFIGURAR';end if;
 if p_kind='preventista' then
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude from public.preventa_customer_schedule c where c.site=p_site and c.code=any(p_keys);
 else
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude,array_agg(distinct o.id),array_agg(distinct o.invoice_number) from public.preventa_work_orders o join public.preventa_customer_schedule c on c.site=o.site and c.code=o.customer_code where o.site=p_site and (o.id::text=any(p_keys) or o.invoice_number=any(p_keys)) group by c.code,c.name,c.latitude,c.longitude;
 end if;return out_id;
end$function$;
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
 if p.id is null or p.status<>'ready' or p.site<>j.site or p.kind<>j.kind or p.route_code<>j.route_code or p.day<>j.day or (p.worker_id is not null and p.worker_id<>j.worker_id) or (p.journey_id is not null and p.journey_id<>j.id) then raise exception 'PLAN_NO_CORRESPONDE_A_LA_JORNADA';end if;
 if not bia_acl_private.preventa_worker_route_allowed(j.worker_id,j.route_code) or exists(select 1 from public.preventa_work_plan_stops s join public.preventa_customer_schedule c on c.site=j.site and c.code=s.customer_code where s.plan_id=p.id and not bia_acl_private.preventa_worker_route_allowed(j.worker_id,c.presale_route)) then raise exception 'RUTAS_NO_HABILITADAS_PARA_LA_PERSONA';end if;
 if j.kind='motorista' then perform pg_advisory_xact_lock(hashtext('preventa-order-'||x::text)) from (select distinct unnest(order_ids) as x from public.preventa_work_plan_stops where plan_id=p.id order by x) ids;end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops s cross join lateral unnest(s.order_ids) oid left join public.preventa_work_orders o on o.id=oid left join public.preventa_invoices i on i.number=o.invoice_number where s.plan_id=p.id and (o.id is null or o.taken_at+interval '48 hours'>now() or not coalesce(i.present_in_source,false))) then raise exception 'NO_SE_CUMPLEN_LAS_48_HORAS';end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops ps join public.preventa_work_visits v on v.order_ids && ps.order_ids join public.preventa_work_journeys other on other.id=v.journey_id where ps.plan_id=p.id and other.id<>j.id and (other.ended_at is null or v.outcome='entregado')) then raise exception 'PEDIDO_YA_ASIGNADO_O_ENTREGADO';end if;
 insert into public.preventa_work_visits(journey_id,seq,site,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers,expected_leg_seconds,expected_service_seconds) select j.id,s.seq,j.site,s.customer_code,s.customer_name,s.latitude,s.longitude,s.order_ids,s.invoice_numbers,s.leg_seconds,p.service_seconds from public.preventa_work_plan_stops s where s.plan_id=p.id order by s.seq;
 update public.preventa_work_plans set status='used',worker_id=j.worker_id where id=p.id;
 update public.preventa_work_journeys set plan_id=p.id,departed_at=now(),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'INICIAR_RECORRIDO',jsonb_build_object('plan',p.id,'paradas',p.stop_count));
end$function$;
notify pgrst,'reload schema';
