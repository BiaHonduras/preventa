-- Administrative removal is reversible logical deletion; source customers, invoices and accounts are never modified.
alter table public.preventa_work_journeys add column deleted_at timestamptz;
alter table public.preventa_work_plans add column deleted_at timestamptz;
alter table public.preventa_work_orders add column deleted_at timestamptz;
alter table public.preventa_work_orders add column version int not null default 1;
alter table public.preventa_work_orders drop constraint preventa_work_orders_invoice_number_key;
create unique index preventa_active_order_invoice on public.preventa_work_orders(invoice_number) where deleted_at is null;
create table bia_acl_private.preventa_operation_removals(id uuid primary key default gen_random_uuid(),site text not null,entity text not null check(entity in ('journeys','plans','orders')),record_id uuid not null,actor uuid not null,at timestamptz not null default now(),reason text not null,snapshot jsonb not null,counts jsonb not null);
alter table bia_acl_private.preventa_operation_removals enable row level security;
revoke all on bia_acl_private.preventa_operation_removals from public,anon,authenticated,preventa_operativo;
create index preventa_removals_date on bia_acl_private.preventa_operation_removals(site,at desc);
create index preventa_active_journey_date on public.preventa_work_journeys(site,day) where deleted_at is null;
create index preventa_active_plan_date on public.preventa_work_plans(site,day) where deleted_at is null;
create index preventa_active_order_date on public.preventa_work_orders(site,taken_at) where deleted_at is null;
alter policy work_orders_read on public.preventa_work_orders using(deleted_at is null and public.bia_can('preventa','read',site));
alter policy work_plans_read on public.preventa_work_plans using(deleted_at is null and (bia_acl_private.preventa_work_manager(site) or (bia_acl_private.preventa_work_role(site,kind) and (status in ('ready','used') or created_by=auth.uid()))));

create function public.preventa_ops_remove_record(p_entity text,p_id uuid,p_version int,p_reason text,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;p public.preventa_work_plans;o public.preventa_work_orders;s text;v int;order_ids uuid[];body jsonb;totals jsonb;result_id uuid;
begin
 if p_entity not in ('journeys','plans','orders') or p_id is null or p_version is null or p_confirmation is distinct from 'ELIMINAR' or length(btrim(coalesce(p_reason,'')))<5 or length(p_reason)>2000 then raise exception 'CONFIRMA_EL_REGISTRO_Y_EL_MOTIVO';end if;
 if p_entity='journeys' then select * into j from public.preventa_work_journeys where id=p_id for update;s=j.site;v=j.version;
 elsif p_entity='plans' then select * into p from public.preventa_work_plans where id=p_id for update;s=p.site;v=p.version;
 else select * into o from public.preventa_work_orders where id=p_id for update;s=o.site;v=o.version;end if;
 if s is null or not bia_acl_private.preventa_work_manager(s) then raise exception 'SOLO_SUPERVISION';end if;
 if v<>p_version then raise exception 'EL_REGISTRO_CAMBIO_ACTUALIZA_EL_HISTORICO';end if;
 if (p_entity='journeys' and j.deleted_at is not null) or (p_entity='plans' and p.deleted_at is not null) or (p_entity='orders' and o.deleted_at is not null) then raise exception 'REGISTRO_YA_ELIMINADO';end if;
 if p_entity='journeys' then
  -- Same order lock family as apply_plan prevents a delivery from acquiring an order during removal.
  select coalesce(array_agg(id),'{}') into order_ids from public.preventa_work_orders where visit_id in(select id from public.preventa_work_visits where journey_id=j.id) and deleted_at is null;
  perform pg_advisory_xact_lock(hashtext('preventa-order-'||x::text)) from (select unnest(order_ids) x order by x) q;
  if exists(select 1 from public.preventa_work_visits v0 join public.preventa_work_journeys j0 on j0.id=v0.journey_id where j0.id<>j.id and j0.deleted_at is null and v0.order_ids&&order_ids)
   or exists(select 1 from public.preventa_work_plan_stops t join public.preventa_work_plans p0 on p0.id=t.plan_id where p0.deleted_at is null and p0.status in ('draft','ready','used') and p0.id is distinct from j.plan_id and p0.journey_id is distinct from j.id and t.order_ids&&order_ids) then raise exception 'HAY_PEDIDOS_UTILIZADOS_EN_OTRO_RECORRIDO';end if;
  totals=jsonb_build_object('journeys',1,'visits',(select count(*) from public.preventa_work_visits where journey_id=j.id),'orders',cardinality(order_ids),'plans',(select count(*) from public.preventa_work_plans where deleted_at is null and (id=j.plan_id or journey_id=j.id)));
  body=jsonb_build_object('journey',to_jsonb(j),'visits',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_visits x where journey_id=j.id),'events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_events x where journey_id=j.id),'orders',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_orders x where id=any(order_ids)),'plans',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_plans x where id=j.plan_id or journey_id=j.id));
  update public.preventa_work_orders set deleted_at=now(),version=version+1 where id=any(order_ids) and deleted_at is null;
  update public.preventa_work_plans set deleted_at=now(),version=version+1 where deleted_at is null and (id=j.plan_id or journey_id=j.id);
  update public.preventa_work_journeys set deleted_at=now(),ended_at=coalesce(ended_at,now()),version=version+1 where id=j.id;
 elsif p_entity='plans' then
  if p.status='used' or exists(select 1 from public.preventa_work_journeys where plan_id=p.id and deleted_at is null) then raise exception 'PREPARACION_UTILIZADA_ELIMINA_LA_JORNADA_ASOCIADA';end if;
  totals=jsonb_build_object('plans',1,'stops',p.stop_count);body=to_jsonb(p)||jsonb_build_object('stops',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_plan_stops x where plan_id=p.id));
  update public.preventa_work_plans set deleted_at=now(),version=version+1 where id=p.id;
 else
  perform pg_advisory_xact_lock(hashtext('preventa-order-'||o.id::text));
  if exists(select 1 from public.preventa_work_visits v0 join public.preventa_work_journeys j0 on j0.id=v0.journey_id where j0.deleted_at is null and o.id=any(v0.order_ids)) or exists(select 1 from public.preventa_work_plan_stops t join public.preventa_work_plans p0 on p0.id=t.plan_id where p0.deleted_at is null and p0.status in ('draft','ready','used') and o.id=any(t.order_ids)) then raise exception 'PEDIDO_UTILIZADO_EN_UN_RECORRIDO';end if;
  totals=jsonb_build_object('orders',1);body=to_jsonb(o);update public.preventa_work_orders set deleted_at=now(),version=version+1 where id=o.id;
 end if;
 insert into bia_acl_private.preventa_operation_removals(site,entity,record_id,actor,reason,snapshot,counts) values(s,p_entity,p_id,auth.uid(),btrim(p_reason),body,totals) returning id into result_id;
 return jsonb_build_object('audit_id',result_id,'counts',totals);
end$$;
revoke all on function public.preventa_ops_remove_record(text,uuid,int,text,text) from public,anon;
grant execute on function public.preventa_ops_remove_record(text,uuid,int,text,text) to authenticated,preventa_operativo;
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
 select * into j from public.preventa_work_journeys where worker_id=p_worker and ended_at is null and deleted_at is null;
 if j.id is not null then if j.actor=auth.uid() then return j.id;else raise exception 'PERSONAL_CON_JORNADA_ACTIVA';end if;end if;
 insert into public.preventa_work_journeys(site,route_code,kind,worker_id,actor) values(w.site,p_route,w.worker_kind,p_worker,auth.uid()) returning id into out_id;
 insert into public.preventa_work_events(journey_id,actor,action) values(out_id,auth.uid(),'INICIAR_JORNADA');return out_id;
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
 if v.state='visiting' and v.photo_path=p_photo then return;end if;
 if v.state<>'pending' then raise exception 'ESTADO_DE_VISITA_INVALIDO';end if;
 if p_lat is null or p_lng is null or p_accuracy is null or not(p_lat between -90 and 90) or not(p_lng between -180 and 180) or not(p_accuracy between 0 and 100000) then raise exception 'GEOREFERENCIA_INVALIDA';end if;
 select * into t from bia_acl_private.preventa_photo_tickets where path=p_photo and visit_id=v.id and user_id=auth.uid() and used_at is null and created_at>now()-interval '15 minutes' for update;
 if t.path is null or not exists(select 1 from storage.objects o where o.bucket_id='preventa-visitas' and o.name=p_photo and o.metadata->>'mimetype'='image/jpeg') then raise exception 'FOTOGRAFIA_DE_CAMARA_REQUERIDA';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and id<>v.id and state='visiting') then raise exception 'FINALIZA_O_PAUSA_EL_CLIENTE_ACTUAL';end if;
 if j.kind='motorista' and exists(select 1 from unnest(v.order_ids) oid left join public.preventa_work_orders o on o.id=oid left join public.preventa_invoices i on i.number=o.invoice_number where o.id is null or o.deleted_at is not null or o.taken_at+interval '48 hours'>now() or not coalesce(i.present_in_source,false)) then raise exception 'NO_SE_CUMPLEN_LAS_48_HORAS';end if;
 update bia_acl_private.preventa_photo_tickets set used_at=now() where path=t.path;
 update public.preventa_work_visits set state='visiting',arrived_at=now(),last_active_at=now(),arrival_lat=p_lat,arrival_lng=p_lng,arrival_accuracy=p_accuracy,photo_path=p_photo,version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'LLEGADA',jsonb_build_object('latitude',p_lat,'longitude',p_lng,'accuracy',p_accuracy,'photo',p_photo));
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_summary(p_day date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not exists(select 1 from bia_acl_private.accounts a where a.user_id=auth.uid() and a.role in ('administrador','coordinador','jefatura_zn','jefatura_zc')) or not public.bia_can('preventa','read') then raise exception 'SOLO_SUPERVISION';end if;
 return jsonb_build_object('server_now',now(),'journeys',(select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('worker_name',w.name) order by j.started_at),'[]') from public.preventa_work_journeys j join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day=p_day and bia_acl_private.preventa_work_manager(j.site)),'visits',(select coalesce(jsonb_agg(to_jsonb(v) order by j.started_at,v.seq),'[]') from public.preventa_work_visits v join public.preventa_work_journeys j on j.id=v.journey_id where j.deleted_at is null and j.day=p_day and bia_acl_private.preventa_work_manager(j.site)),'plans',(select coalesce(jsonb_agg(to_jsonb(p)),'[]') from public.preventa_work_plans p where p.deleted_at is null and p.day=p_day and bia_acl_private.preventa_work_manager(p.site)),'prepared_stops',(select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('state','pending','prepared',true,'site',p.site,'route_code',p.route_code,'kind',p.kind,'worker_id',p.worker_id)),'[]') from public.preventa_work_plan_stops t join public.preventa_work_plans p on p.id=t.plan_id where p.deleted_at is null and p.day=p_day and p.status='ready' and p.journey_id is null and bia_acl_private.preventa_work_manager(p.site)));
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
 if p.id is null or p.deleted_at is not null or p.status<>'ready' or p.site<>j.site or p.kind<>j.kind or p.route_code<>j.route_code or p.day<>j.day or (p.worker_id is not null and p.worker_id<>j.worker_id) or (p.journey_id is not null and p.journey_id<>j.id) then raise exception 'PLAN_NO_CORRESPONDE_A_LA_JORNADA';end if;
 if not bia_acl_private.preventa_worker_route_allowed(j.worker_id,j.route_code) or exists(select 1 from public.preventa_work_plan_stops s join public.preventa_customer_schedule c on c.site=j.site and c.code=s.customer_code where s.plan_id=p.id and not bia_acl_private.preventa_worker_route_allowed(j.worker_id,c.presale_route)) then raise exception 'RUTAS_NO_HABILITADAS_PARA_LA_PERSONA';end if;
 if j.kind='motorista' then perform pg_advisory_xact_lock(hashtext('preventa-order-'||x::text)) from (select distinct unnest(order_ids) as x from public.preventa_work_plan_stops where plan_id=p.id order by x) ids;end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops s cross join lateral unnest(s.order_ids) oid left join public.preventa_work_orders o on o.id=oid left join public.preventa_invoices i on i.number=o.invoice_number where s.plan_id=p.id and (o.id is null or o.deleted_at is not null or o.taken_at+interval '48 hours'>now() or not coalesce(i.present_in_source,false))) then raise exception 'NO_SE_CUMPLEN_LAS_48_HORAS';end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops ps join public.preventa_work_visits v on v.order_ids && ps.order_ids join public.preventa_work_journeys other on other.id=v.journey_id where ps.plan_id=p.id and other.id<>j.id and (other.ended_at is null or v.outcome='entregado')) then raise exception 'PEDIDO_YA_ASIGNADO_O_ENTREGADO';end if;
 insert into public.preventa_work_visits(journey_id,seq,site,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers,expected_leg_seconds,expected_service_seconds) select j.id,s.seq,j.site,s.customer_code,s.customer_name,s.latitude,s.longitude,s.order_ids,s.invoice_numbers,s.leg_seconds,p.service_seconds from public.preventa_work_plan_stops s where s.plan_id=p.id order by s.seq;
 update public.preventa_work_plans set status='used',worker_id=j.worker_id where id=p.id;
 update public.preventa_work_journeys set plan_id=p.id,departed_at=now(),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'INICIAR_RECORRIDO',jsonb_build_object('plan',p.id,'paradas',p.stop_count));
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
 perform pg_advisory_xact_lock(hashtext('preventa-order-'||x.id::text)) from (select id from public.preventa_work_orders where site=p_site and deleted_at is null and (id::text=any(p_keys) or invoice_number=any(p_keys)) order by id) x;
 select count(*) into missing from unnest(p_keys) x where not exists(select 1 from public.preventa_work_orders o join public.preventa_invoices i on i.number=o.invoice_number and i.present_in_source where (o.id::text=x or o.invoice_number=x) and o.site=p_site and o.deleted_at is null and o.taken_at+interval '48 hours'<=p_departure and exists(select 1 from public.preventa_customer_schedule c where c.site=o.site and c.code=o.customer_code and c.active and (p_worker is null or bia_acl_private.preventa_worker_route_allowed(p_worker,c.presale_route))));
 if missing>0 then raise exception 'PEDIDOS_SIN_FACTURA_O_SIN_48_HORAS';end if;
 select count(distinct customer_code) into n from public.preventa_work_orders where deleted_at is null and (id::text=any(p_keys) or invoice_number=any(p_keys));
 end if;
 if n not between 1 and 99 then raise exception 'EL_RECORRIDO_ADMITE_DE_1_A_99_CLIENTES';end if;
 insert into public.preventa_work_plans(site,route_code,kind,day,departure_at,worker_id,created_by,journey_id,stop_count,service_seconds,buffer_seconds) select p_site,p_route,p_kind,p_day,p_departure,p_worker,auth.uid(),p_journey,n,s.service_seconds,p_buffer_minutes*60 from public.preventa_work_settings s where site=p_site returning id into out_id;
 if out_id is null then raise exception 'SEDE_SIN_CONFIGURAR';end if;
 if p_kind='preventista' then
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude from public.preventa_customer_schedule c where c.site=p_site and c.code=any(p_keys);
 else
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude,array_agg(distinct o.id),array_agg(distinct o.invoice_number) from public.preventa_work_orders o join public.preventa_customer_schedule c on c.site=o.site and c.code=o.customer_code where o.site=p_site and o.deleted_at is null and (o.id::text=any(p_keys) or o.invoice_number=any(p_keys)) group by c.code,c.name,c.latitude,c.longitude;
 end if;return out_id;
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_store_route(p_plan uuid, p_actor uuid, p_order uuid[], p_legs jsonb, p_return double precision, p_distance double precision, p_geometry jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.preventa_work_plans;x record;n int;
begin
 select * into p from public.preventa_work_plans where id=p_plan for update;
 if p.id is null or not bia_acl_private.can_for(p_actor,'preventa','read',p.site) or p.status<>'draft' or p.created_by<>p_actor or cardinality(p_order)<>p.stop_count or jsonb_array_length(p_legs)<>p.stop_count or p_return is null or p_distance is null or p_return<0 or p_distance<0 then raise exception 'RESULTADO_DE_RUTA_INVALIDO';end if;
 if p.journey_id is not null and exists(select 1 from public.preventa_work_journeys where id=p.journey_id and (departed_at is not null or ended_at is not null)) then raise exception 'RECORRIDO_YA_INICIADO';end if;
 if (select count(distinct id) from public.preventa_work_plan_stops where plan_id=p_plan and id=any(p_order))<>p.stop_count then raise exception 'PARADAS_INCOMPLETAS';end if;
 -- Avoid intermediate collisions of the unique sequence constraint.
 update public.preventa_work_plan_stops set seq=-seq where plan_id=p_plan;
 for x in select value,ordinality from jsonb_array_elements(p_legs) with ordinality loop
 if (x.value->>'seconds')::double precision<0 or (x.value->>'meters')::double precision<0 then raise exception 'TRAMO_INVALIDO';end if;
 update public.preventa_work_plan_stops set seq=x.ordinality,leg_seconds=(x.value->>'seconds')::double precision,leg_m=(x.value->>'meters')::double precision where plan_id=p_plan and id=p_order[x.ordinality];
 end loop;
 update public.preventa_work_plans set status='superseded',version=version+1 where deleted_at is null and status='ready' and id<>p_plan and site=p.site and kind=p.kind and day=p.day and route_code=p.route_code and worker_id is not distinct from p.worker_id and journey_id is null;
 update public.preventa_work_plans set status='ready',road_seconds=(select sum(leg_seconds) from public.preventa_work_plan_stops where plan_id=p_plan)+p_return,return_seconds=p_return,distance_m=p_distance,geometry=p_geometry,provider='OSRM · vehículo liviano · sin tráfico en vivo',optimized_at=now(),version=version+1 where id=p_plan;
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_record_order(p_site text, p_customer text, p_taken timestamp with time zone, p_reference text, p_invoice text DEFAULT NULL::text, p_order uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare out_id uuid;inv public.preventa_invoices;
begin
 if not bia_acl_private.preventa_work_manager(p_site) then raise exception 'SOLO_SUPERVISION';end if;
 if p_taken is null or p_taken>now() or p_taken<now()-interval '1 year' then raise exception 'FECHA_REAL_DEL_PEDIDO_INVALIDA';end if;
 if not exists(select 1 from public.preventa_customer_schedule where site=p_site and code=p_customer and active) then raise exception 'CLIENTE_NO_DISPONIBLE';end if;
 if nullif(btrim(p_invoice),'') is not null then select * into inv from public.preventa_invoices where number=btrim(p_invoice) and site=p_site and present_in_source;if inv.number is null then raise exception 'FACTURA_NO_DISPONIBLE';end if;end if;
 if p_order is null then
 insert into public.preventa_work_orders(site,customer_code,taken_at,reference,invoice_number,source,created_by) values(p_site,p_customer,p_taken,left(coalesce(p_reference,''),120),nullif(btrim(p_invoice),''),'supervisor',auth.uid()) returning id into out_id;
 else
 update public.preventa_work_orders set invoice_number=nullif(btrim(p_invoice),''),version=version+1 where deleted_at is null and id=p_order and site=p_site and customer_code=p_customer and invoice_number is null returning id into out_id;
 if out_id is null then raise exception 'PEDIDO_NO_DISPONIBLE_PARA_VINCULAR';end if;
 end if;return out_id;
end$function$;
CREATE OR REPLACE FUNCTION bia_acl_private.preventa_work_journey_read(p_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select exists(select 1 from public.preventa_work_journeys j where j.id=p_id and j.deleted_at is null and (bia_acl_private.preventa_work_manager(j.site) or (j.actor=auth.uid() and bia_acl_private.preventa_work_role(j.site,j.kind))))$function$;
CREATE OR REPLACE FUNCTION bia_acl_private.preventa_work_journey_write(p_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$select exists(select 1 from public.preventa_work_journeys j where j.id=p_id and j.deleted_at is null and j.actor=auth.uid() and j.ended_at is null and bia_acl_private.preventa_work_role(j.site,j.kind))$function$;
create function bia_acl_private.preventa_report_check(p_from date,p_to date,p_site text) returns void language plpgsql stable security definer set search_path='' as $$begin
 if not bia_acl_private.preventa_work_manager(p_site) then raise exception 'SOLO_SUPERVISION';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>365 then raise exception 'SELECCIONA_UN_PERIODO_DE_HASTA_UN_ANO';end if;
end$$;
revoke all on function bia_acl_private.preventa_report_check(date,date,text) from public,anon,authenticated,preventa_operativo;

create function public.preventa_ops_dashboard(p_from date,p_to date,p_site text default null,p_kind text default null,p_worker uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 perform bia_acl_private.preventa_report_check(p_from,p_to,p_site);
 with js as (
  select j.*,w.name worker_name,case when p.id is not null then p.road_seconds+p.stop_count*p.service_seconds+p.buffer_seconds end planned_seconds,
  case when j.ended_at is not null and j.departed_at is not null then greatest(0,extract(epoch from j.ended_at-j.departed_at)) end actual_seconds
  from public.preventa_work_journeys j join public.preventa_drivers w on w.id=j.worker_id left join public.preventa_work_plans p on p.id=j.plan_id and p.deleted_at is null
  where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site) and (p_site is null or j.site=p_site) and (p_kind is null or j.kind=p_kind) and (p_worker is null or j.worker_id=p_worker)
 ), vs as (
  select v.*,j.kind,j.worker_id,j.day,coalesce(c.presale_route,j.route_code) customer_route from public.preventa_work_visits v join js j on j.id=v.journey_id left join public.preventa_customer_schedule c on c.site=v.site and c.code=v.customer_code
 ), cv as (
  select site,customer_code,count(*) filter(where arrived_at is not null) visits,count(*) filter(where state in ('visited','failed')) completed,avg(service_seconds) filter(where finished_at is not null) avg_service from vs group by site,customer_code
 ), directory as (
  select c.site,c.code,c.name,c.presale_route,coalesce(cv.visits,0) visits,coalesce(cv.completed,0) completed,cv.avg_service from public.preventa_customer_schedule c left join cv on cv.site=c.site and cv.customer_code=c.code where c.active and bia_acl_private.preventa_work_manager(c.site) and (p_site is null or c.site=p_site)
 )
 select jsonb_build_object('server_now',now(),'from',p_from,'to',p_to,'metrics',jsonb_build_object(
 'journeys',(select count(*) from js),'open_journeys',(select count(*) from js where ended_at is null),'closed_journeys',(select count(*) from js where ended_at is not null),
 'scheduled_visits',(select count(*) from vs),'arrivals',(select count(*) from vs where arrived_at is not null),'completed_visits',(select count(*) from vs where state in ('visited','failed')),'pending_visits',(select count(*) from vs where state in ('pending','paused')),
 'successful_deliveries',(select count(*) from vs where outcome='entregado'),'failed_deliveries',(select count(*) from vs where kind='motorista' and state='failed'),'failed_visits',(select count(*) from vs where state='failed'),
 'orders',(select count(*) from public.preventa_work_orders o join vs v on v.id=o.visit_id where o.deleted_at is null),'customers',(select count(*) from directory),'unique_visited_customers',(select count(*) from directory where visits>0),'unvisited_customers',(select count(*) from directory where visits=0),
 'average_service_seconds',(select coalesce(avg(service_seconds),0) from vs where finished_at is not null),'median_service_seconds',(select coalesce(percentile_cont(0.5) within group(order by service_seconds),0) from vs where finished_at is not null),'over_service_target',(select count(*) from vs where finished_at is not null and service_seconds>expected_service_seconds),
 'closed_actual_seconds',(select coalesce(sum(actual_seconds),0) from js),'non_service_seconds',(select coalesce(sum(greatest(0,j.actual_seconds-(select coalesce(sum(v.service_seconds),0) from vs v where v.journey_id=j.id))),0) from js j where j.actual_seconds is not null),
 'comparable_journeys',(select count(*) from js where planned_seconds is not null and actual_seconds is not null),'comparable_expected_seconds',(select coalesce(sum(planned_seconds),0) from js where planned_seconds is not null and actual_seconds is not null),'comparable_actual_seconds',(select coalesce(sum(actual_seconds),0) from js where planned_seconds is not null and actual_seconds is not null)
 ),'trend',(select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]') from(select d::date as day,(select count(*) from vs where day=d::date and state in ('visited','failed')) completed,(select count(*) from vs where day=d::date) scheduled,(select count(*) from vs where day=d::date and outcome='entregado') deliveries from generate_series(p_from::timestamp,p_to::timestamp,interval '1 day') d)x),
 'routes',(select coalesce(jsonb_agg(to_jsonb(x) order by x.presale_route),'[]') from(select presale_route,count(*) customers,count(*) filter(where visits>0) covered,sum(visits) visits from directory group by presale_route)x),
 'workers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.worker_name),'[]') from(select j.worker_id,j.worker_name,j.kind,count(*) journeys,count(*) filter(where j.ended_at is not null) closed_journeys,avg(j.actual_seconds) avg_journey_seconds,(select count(*) from vs v where v.worker_id=j.worker_id and v.state in ('visited','failed')) visits,(select avg(v.service_seconds) from vs v where v.worker_id=j.worker_id and v.finished_at is not null) avg_service_seconds from js j group by j.worker_id,j.worker_name,j.kind)x),
 'most_visited',(select coalesce(jsonb_agg(to_jsonb(x) order by x.visits desc,x.name),'[]') from(select * from directory where visits>0 order by visits desc,name,code limit 10)x),
 'least_visited',(select coalesce(jsonb_agg(to_jsonb(x) order by x.visits,x.name),'[]') from(select * from directory order by visits,name,code limit 10)x),
 'slowest_customers',(select coalesce(jsonb_agg(to_jsonb(x) order by x.avg_service desc),'[]') from(select * from directory where completed>0 order by avg_service desc nulls last,name limit 10)x),
 'pause_reasons',(select coalesce(jsonb_agg(to_jsonb(x) order by x.count desc),'[]') from(select coalesce(e.details->>'motivo','Sin motivo') reason,count(*) from public.preventa_work_events e join js j on j.id=e.journey_id where e.action='PAUSA' group by e.details->>'motivo' order by count(*) desc limit 10)x)
 ) into result;
 return result;
end$$;

create function public.preventa_ops_history(p_entity text,p_from date,p_to date,p_site text default null,p_kind text default null,p_worker uuid default null,p_route text default null,p_offset int default 0,p_limit int default 50) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rows jsonb;total bigint;
begin
 perform bia_acl_private.preventa_report_check(p_from,p_to,p_site);
 if p_offset<0 or p_limit not between 1 and 100 then raise exception 'PAGINA_INVALIDA';end if;
 if p_entity='journeys' then
  with filtered as(select j.*,w.name worker_name,coalesce(p.road_seconds+p.stop_count*p.service_seconds+p.buffer_seconds,0) expected_seconds,(select count(*) from public.preventa_work_visits v where v.journey_id=j.id) visit_count,(select count(*) from public.preventa_work_visits v where v.journey_id=j.id and v.state in ('visited','failed')) completed_count from public.preventa_work_journeys j join public.preventa_drivers w on w.id=j.worker_id left join public.preventa_work_plans p on p.id=j.plan_id and p.deleted_at is null where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site) and (p_site is null or j.site=p_site) and (p_kind is null or j.kind=p_kind) and (p_worker is null or j.worker_id=p_worker) and (p_route is null or j.route_code=p_route))
  select (select count(*) from filtered),(select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc),'[]') from(select * from filtered order by started_at desc,id limit p_limit offset p_offset)x) into total,rows;
 elsif p_entity='plans' then
  with filtered as(select p.*,w.name worker_name from public.preventa_work_plans p left join public.preventa_drivers w on w.id=p.worker_id where p.deleted_at is null and p.day between p_from and p_to and bia_acl_private.preventa_work_manager(p.site) and (p_site is null or p.site=p_site) and (p_kind is null or p.kind=p_kind) and (p_worker is null or p.worker_id=p_worker) and (p_route is null or p.route_code=p_route))
  select (select count(*) from filtered),(select coalesce(jsonb_agg(to_jsonb(x)-'geometry' order by x.created_at desc),'[]') from(select * from filtered order by created_at desc,id limit p_limit offset p_offset)x) into total,rows;
 elsif p_entity='orders' then
  with filtered as(select o.*,c.name customer_name,c.presale_route route_code from public.preventa_work_orders o join public.preventa_customer_schedule c on c.site=o.site and c.code=o.customer_code where o.deleted_at is null and (o.taken_at at time zone 'America/Tegucigalpa')::date between p_from and p_to and bia_acl_private.preventa_work_manager(o.site) and (p_site is null or o.site=p_site) and (p_route is null or c.presale_route=p_route))
  select (select count(*) from filtered),(select coalesce(jsonb_agg(to_jsonb(x) order by x.taken_at desc),'[]') from(select * from filtered order by taken_at desc,id limit p_limit offset p_offset)x) into total,rows;
 elsif p_entity='removals' then
  with filtered as(select r.id,r.site,r.entity,r.record_id,r.at,r.reason,r.counts,coalesce(a.nombre_corto,'Usuario') actor_name from bia_acl_private.preventa_operation_removals r left join bia_acl_private.accounts a on a.user_id=r.actor where (r.at at time zone 'America/Tegucigalpa')::date between p_from and p_to and bia_acl_private.preventa_work_manager(r.site) and (p_site is null or r.site=p_site))
  select (select count(*) from filtered),(select coalesce(jsonb_agg(to_jsonb(x) order by x.at desc),'[]') from(select * from filtered order by at desc,id limit p_limit offset p_offset)x) into total,rows;
 else raise exception 'TIPO_DE_HISTORICO_INVALIDO';end if;
 return jsonb_build_object('server_now',now(),'total',total,'rows',rows);
end$$;

create function public.preventa_ops_history_detail(p_entity text,p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s text;result jsonb;
begin
 if p_entity='journeys' then select site into s from public.preventa_work_journeys where id=p_id and deleted_at is null;
 elsif p_entity='plans' then select site into s from public.preventa_work_plans where id=p_id and deleted_at is null;
 elsif p_entity='orders' then select site into s from public.preventa_work_orders where id=p_id and deleted_at is null;
 else raise exception 'TIPO_DE_HISTORICO_INVALIDO';end if;
 if s is null or not bia_acl_private.preventa_work_manager(s) then raise exception 'SOLO_SUPERVISION';end if;
 if p_entity='journeys' then
  result=public.preventa_ops_snapshot(p_id);
  return result||jsonb_build_object('worker_name',(select w.name from public.preventa_drivers w join public.preventa_work_journeys j on j.worker_id=w.id where j.id=p_id),'events',(select coalesce(jsonb_agg(to_jsonb(e) order by e.at,e.id),'[]') from public.preventa_work_events e where journey_id=p_id));
 elsif p_entity='plans' then return jsonb_build_object('plan',(select to_jsonb(p)-'geometry' from public.preventa_work_plans p where id=p_id),'stops',(select coalesce(jsonb_agg(to_jsonb(t) order by seq),'[]') from public.preventa_work_plan_stops t where plan_id=p_id));
 else return jsonb_build_object('order',(select to_jsonb(o) from public.preventa_work_orders o where id=p_id));end if;
end$$;
revoke all on function public.preventa_ops_dashboard(date,date,text,text,uuid),public.preventa_ops_history(text,date,date,text,text,uuid,text,int,int),public.preventa_ops_history_detail(text,uuid) from public,anon;
grant execute on function public.preventa_ops_dashboard(date,date,text,text,uuid),public.preventa_ops_history(text,date,date,text,text,uuid,text,int,int),public.preventa_ops_history_detail(text,uuid) to authenticated,preventa_operativo;
notify pgrst,'reload schema';



