-- Shared operational storage; client data remains protected by site and role.
alter table public.preventa_drivers add column worker_kind text not null default 'motorista' check(worker_kind in ('preventista','motorista'));
alter table public.preventa_drivers add column assigned_route text references public.preventa_routes(code);
insert into public.preventa_drivers(name,site,worker_kind,assigned_route,active) values ('Preventista 1','SPS','preventista','501',false),('Preventista 2','SPS','preventista','561',false),('Preventista 3','SPS','preventista','564',false) on conflict(name) do nothing;
create table bia_acl_private.preventa_operator_access(user_id uuid primary key references auth.users(id),kind text not null check(kind in ('preventista','motorista')));
alter table bia_acl_private.preventa_operator_access enable row level security;
revoke all on bia_acl_private.preventa_operator_access from public,anon,authenticated,preventa_operativo;
insert into bia_acl_private.preventa_operator_access select id,'motorista' from auth.users where email='motoristas.preventa@intranet.invalid' on conflict(user_id) do nothing;
create function bia_acl_private.preventa_work_manager(p_site text) returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and public.bia_can('preventa','catalogs',p_site) and exists(select 1 from bia_acl_private.accounts a where a.user_id=auth.uid() and a.role in ('administrador','coordinador','jefatura_zn','jefatura_zc')) $$;
create function bia_acl_private.preventa_work_role(p_site text,p_kind text) returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and public.bia_can('preventa','read',p_site) and (bia_acl_private.preventa_work_manager(p_site) or exists(select 1 from bia_acl_private.preventa_operator_access a where a.user_id=auth.uid() and a.kind=p_kind)) $$;
revoke all on function bia_acl_private.preventa_work_manager(text),bia_acl_private.preventa_work_role(text,text) from public,anon;
grant execute on function bia_acl_private.preventa_work_manager(text),bia_acl_private.preventa_work_role(text,text) to authenticated,preventa_operativo;
create table public.preventa_work_settings(site text primary key,depot_lat double precision not null check(depot_lat between -90 and 90),depot_lng double precision not null check(depot_lng between -180 and 180),service_seconds int not null default 360 check(service_seconds between 60 and 7200),provider text not null default 'osrm_car_static');
-- La ubicación de la sede se configura mediante una carga privada, fuera del código público.
create table public.preventa_work_orders(id uuid primary key default gen_random_uuid(),site text not null,customer_code text not null,taken_at timestamptz not null,reference text not null default '',invoice_number text unique references public.preventa_invoices(number),visit_id uuid unique,source text not null check(source in ('visita','supervisor')),created_by uuid not null,created_at timestamptz not null default now(),foreign key(site,customer_code) references public.preventa_customer_schedule(site,code));
create table public.preventa_work_plans(id uuid primary key default gen_random_uuid(),site text not null references public.preventa_work_settings(site),route_code text not null references public.preventa_routes(code),kind text not null check(kind in ('preventista','motorista')),day date not null,departure_at timestamptz not null,worker_id uuid references public.preventa_drivers(id),created_by uuid not null,created_at timestamptz not null default now(),status text not null default 'draft' check(status in ('draft','ready','used','superseded')),stop_count int not null default 0,service_seconds int not null default 360,buffer_seconds int not null default 0 check(buffer_seconds between 0 and 86400),road_seconds double precision,return_seconds double precision,distance_m double precision,geometry jsonb,provider text,optimized_at timestamptz,version int not null default 1);
create table public.preventa_work_plan_stops(id uuid primary key default gen_random_uuid(),plan_id uuid not null references public.preventa_work_plans(id),seq int not null,customer_code text not null,customer_name text not null,latitude double precision not null,longitude double precision not null,order_ids uuid[] not null default '{}',invoice_numbers text[] not null default '{}',leg_seconds double precision,leg_m double precision,unique(plan_id,customer_code),unique(plan_id,seq));
create table public.preventa_work_journeys(id uuid primary key default gen_random_uuid(),site text not null,route_code text not null,kind text not null check(kind in ('preventista','motorista')),worker_id uuid not null references public.preventa_drivers(id),actor uuid not null,day date not null default (now() at time zone 'America/Tegucigalpa')::date,started_at timestamptz not null default now(),departed_at timestamptz,ended_at timestamptz,end_reason text,plan_id uuid references public.preventa_work_plans(id),version int not null default 1);
create unique index preventa_one_open_worker on public.preventa_work_journeys(worker_id) where ended_at is null;
alter table public.preventa_work_plans add column journey_id uuid references public.preventa_work_journeys(id);
create table public.preventa_work_visits(id uuid primary key default gen_random_uuid(),journey_id uuid not null references public.preventa_work_journeys(id),seq int not null,site text not null,customer_code text not null,customer_name text not null,latitude double precision not null,longitude double precision not null,order_ids uuid[] not null default '{}',invoice_numbers text[] not null default '{}',expected_leg_seconds double precision not null default 0,expected_service_seconds int not null default 360,state text not null default 'pending' check(state in ('pending','visiting','paused','visited','failed')),arrived_at timestamptz,finished_at timestamptz,last_active_at timestamptz,service_seconds double precision not null default 0,pause_started_at timestamptz,pause_reason text,expected_wait_minutes int check(expected_wait_minutes between 1 and 1440),paused_seconds double precision not null default 0,arrival_lat double precision,arrival_lng double precision,arrival_accuracy double precision,photo_path text,outcome text,notes text,disposition text,version int not null default 1,unique(journey_id,customer_code),unique(journey_id,seq));
create unique index preventa_one_active_visit on public.preventa_work_visits(journey_id) where state='visiting';
create table public.preventa_work_events(id bigint generated always as identity primary key,journey_id uuid not null references public.preventa_work_journeys(id),visit_id uuid references public.preventa_work_visits(id),actor uuid not null,action text not null,at timestamptz not null default now(),details jsonb not null default '{}');
create table bia_acl_private.preventa_photo_tickets(path text primary key,user_id uuid not null,visit_id uuid not null references public.preventa_work_visits(id),created_at timestamptz not null default now(),used_at timestamptz);
alter table bia_acl_private.preventa_photo_tickets enable row level security;
revoke all on bia_acl_private.preventa_photo_tickets from public,anon,authenticated,preventa_operativo;
create table bia_acl_private.preventa_routing_gate(id boolean primary key default true,next_at timestamptz not null default now());
insert into bia_acl_private.preventa_routing_gate default values;
alter table bia_acl_private.preventa_routing_gate enable row level security;
revoke all on bia_acl_private.preventa_routing_gate from public,anon,authenticated,preventa_operativo;
create function bia_acl_private.preventa_work_journey_read(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.preventa_work_journeys j where j.id=p_id and (bia_acl_private.preventa_work_manager(j.site) or (j.actor=auth.uid() and bia_acl_private.preventa_work_role(j.site,j.kind))))$$;
create function bia_acl_private.preventa_work_journey_write(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.preventa_work_journeys j where j.id=p_id and j.actor=auth.uid() and j.ended_at is null and bia_acl_private.preventa_work_role(j.site,j.kind))$$;
revoke all on function bia_acl_private.preventa_work_journey_read(uuid),bia_acl_private.preventa_work_journey_write(uuid) from public,anon;
grant execute on function bia_acl_private.preventa_work_journey_read(uuid),bia_acl_private.preventa_work_journey_write(uuid) to authenticated,preventa_operativo;
do $$declare t text;begin foreach t in array array['preventa_work_settings','preventa_work_orders','preventa_work_plans','preventa_work_plan_stops','preventa_work_journeys','preventa_work_visits','preventa_work_events'] loop execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated,preventa_operativo',t);execute format('grant select on public.%I to authenticated,preventa_operativo',t);execute format('grant all on public.%I to service_role',t);end loop;end$$;
create policy work_settings_read on public.preventa_work_settings for select to authenticated,preventa_operativo using(public.bia_can('preventa','read',site));
create policy work_orders_read on public.preventa_work_orders for select to authenticated,preventa_operativo using(public.bia_can('preventa','read',site));
create policy work_plans_read on public.preventa_work_plans for select to authenticated,preventa_operativo using(bia_acl_private.preventa_work_manager(site) or (bia_acl_private.preventa_work_role(site,kind) and (status in ('ready','used') or created_by=auth.uid())));
create policy work_plan_stops_read on public.preventa_work_plan_stops for select to authenticated,preventa_operativo using(exists(select 1 from public.preventa_work_plans p where p.id=plan_id));
create policy work_journeys_read on public.preventa_work_journeys for select to authenticated,preventa_operativo using(bia_acl_private.preventa_work_journey_read(id));
create policy work_visits_read on public.preventa_work_visits for select to authenticated,preventa_operativo using(bia_acl_private.preventa_work_journey_read(journey_id));
create policy work_events_read on public.preventa_work_events for select to authenticated,preventa_operativo using(bia_acl_private.preventa_work_journey_read(journey_id));
create index work_visits_journey on public.preventa_work_visits(journey_id,seq);
create index work_events_journey on public.preventa_work_events(journey_id,at);
create index work_journeys_day on public.preventa_work_journeys(site,day);
notify pgrst,'reload schema';

create function public.preventa_ops_context() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare k text;
begin
 if auth.uid() is null or not public.bia_can('preventa','read') then raise exception 'SIN_ACCESO_PREVENTA';end if;
 select kind into k from bia_acl_private.preventa_operator_access where user_id=auth.uid();
 return jsonb_build_object('kind',k,'workers',(select coalesce(jsonb_agg(to_jsonb(w) order by w.worker_kind,w.name),'[]') from public.preventa_drivers w where w.active and public.bia_can('preventa','read',w.site) and (bia_acl_private.preventa_work_manager(w.site) or w.worker_kind=k)), 'settings',(select coalesce(jsonb_agg(to_jsonb(s)),'[]') from public.preventa_work_settings s where public.bia_can('preventa','read',s.site)));
end$$;
create function public.preventa_ops_start(p_worker uuid,p_route text) returns uuid language plpgsql security definer set search_path='' as $$
declare w public.preventa_drivers;j public.preventa_work_journeys;out_id uuid;
begin
 select * into w from public.preventa_drivers where id=p_worker and active;
 if w.id is null or not bia_acl_private.preventa_work_role(w.site,w.worker_kind) then raise exception 'PERSONAL_NO_AUTORIZADO';end if;
 if not exists(select 1 from public.preventa_routes where code=p_route and site=w.site and active) then raise exception 'RUTA_NO_DISPONIBLE';end if;
 if w.worker_kind='preventista' and w.assigned_route is distinct from p_route then raise exception 'RUTA_NO_ASIGNADA_AL_PREVENTISTA';end if;
 perform pg_advisory_xact_lock(hashtext('preventa-worker-'||p_worker));
 select * into j from public.preventa_work_journeys where worker_id=p_worker and ended_at is null;
 if j.id is not null then if j.actor=auth.uid() then return j.id;else raise exception 'PERSONAL_CON_JORNADA_ACTIVA';end if;end if;
 insert into public.preventa_work_journeys(site,route_code,kind,worker_id,actor) values(w.site,p_route,w.worker_kind,p_worker,auth.uid()) returning id into out_id;
 insert into public.preventa_work_events(journey_id,actor,action) values(out_id,auth.uid(),'INICIAR_JORNADA');return out_id;
end$$;
create function public.preventa_ops_record_order(p_site text,p_customer text,p_taken timestamptz,p_reference text,p_invoice text default null,p_order uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare out_id uuid;inv public.preventa_invoices;
begin
 if not bia_acl_private.preventa_work_manager(p_site) then raise exception 'SOLO_SUPERVISION';end if;
 if p_taken is null or p_taken>now() or p_taken<now()-interval '1 year' then raise exception 'FECHA_REAL_DEL_PEDIDO_INVALIDA';end if;
 if not exists(select 1 from public.preventa_customer_schedule where site=p_site and code=p_customer and active) then raise exception 'CLIENTE_NO_DISPONIBLE';end if;
 if nullif(btrim(p_invoice),'') is not null then select * into inv from public.preventa_invoices where number=btrim(p_invoice) and site=p_site and present_in_source;if inv.number is null then raise exception 'FACTURA_NO_DISPONIBLE';end if;end if;
 if p_order is null then
 insert into public.preventa_work_orders(site,customer_code,taken_at,reference,invoice_number,source,created_by) values(p_site,p_customer,p_taken,left(coalesce(p_reference,''),120),nullif(btrim(p_invoice),''),'supervisor',auth.uid()) returning id into out_id;
 else
 update public.preventa_work_orders set invoice_number=nullif(btrim(p_invoice),'') where id=p_order and site=p_site and customer_code=p_customer and invoice_number is null returning id into out_id;
 if out_id is null then raise exception 'PEDIDO_NO_DISPONIBLE_PARA_VINCULAR';end if;
 end if;return out_id;
end$$;
create function public.preventa_ops_create_plan(p_kind text,p_site text,p_route text,p_day date,p_departure timestamptz,p_keys text[],p_worker uuid default null,p_journey uuid default null,p_buffer_minutes int default 0) returns uuid language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;out_id uuid;n int;missing int;
begin
 if p_kind not in ('preventista','motorista') or p_site<>'SPS' or p_day is null or (p_departure at time zone 'America/Tegucigalpa')::date<>p_day or extract(isodow from p_day)=7 then raise exception 'DATOS_DE_PLAN_INVALIDOS';end if;
 if p_buffer_minutes not between 0 and 1440 or coalesce(cardinality(p_keys),0) not between 1 and 300 then raise exception 'SELECCION_DE_CLIENTES_INVALIDA';end if;
 if p_journey is null then if not bia_acl_private.preventa_work_manager(p_site) then raise exception 'SOLO_SUPERVISION';end if;
 else
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(p_journey) or j.departed_at is not null or j.site<>p_site or j.kind<>p_kind or j.route_code<>p_route or j.day<>p_day then raise exception 'JORNADA_NO_ADMITE_PREPARACION';end if;
 p_worker:=j.worker_id;
 end if;
 if not exists(select 1 from public.preventa_routes where code=p_route and site=p_site and active) then raise exception 'RUTA_NO_DISPONIBLE';end if;
 if p_worker is not null and not exists(select 1 from public.preventa_drivers w where w.id=p_worker and w.active and w.site=p_site and w.worker_kind=p_kind and (p_kind<>'preventista' or w.assigned_route=p_route)) then raise exception 'PERSONAL_NO_CORRESPONDE_AL_PLAN';end if;
 if p_kind='preventista' then
 select count(distinct code) into n from public.preventa_customer_schedule where site=p_site and presale_route=p_route and active and code=any(p_keys);
 if n<>(select count(distinct x) from unnest(p_keys) x) then raise exception 'CLIENTES_FUERA_DE_RUTA';end if;
 else
 select count(*) into missing from unnest(p_keys) x where not exists(select 1 from public.preventa_work_orders o join public.preventa_invoices i on i.number=o.invoice_number and i.present_in_source where o.id::text=x and o.site=p_site and o.taken_at+interval '48 hours'<=p_departure);
 if missing>0 then raise exception 'PEDIDOS_SIN_FACTURA_O_SIN_48_HORAS';end if;
 select count(distinct customer_code) into n from public.preventa_work_orders where id::text=any(p_keys);
 end if;
 if n not between 1 and 99 then raise exception 'EL_RECORRIDO_ADMITE_DE_1_A_99_CLIENTES';end if;
 insert into public.preventa_work_plans(site,route_code,kind,day,departure_at,worker_id,created_by,journey_id,stop_count,service_seconds,buffer_seconds) select p_site,p_route,p_kind,p_day,p_departure,p_worker,auth.uid(),p_journey,n,s.service_seconds,p_buffer_minutes*60 from public.preventa_work_settings s where site=p_site returning id into out_id;
 if out_id is null then raise exception 'SEDE_SIN_CONFIGURAR';end if;
 if p_kind='preventista' then
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude from public.preventa_customer_schedule c where c.site=p_site and c.code=any(p_keys);
 else
 insert into public.preventa_work_plan_stops(plan_id,seq,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers) select out_id,row_number() over(order by c.code),c.code,c.name,c.latitude,c.longitude,array_agg(distinct o.id),array_agg(distinct o.invoice_number) from public.preventa_work_orders o join public.preventa_customer_schedule c on c.site=o.site and c.code=o.customer_code where o.site=p_site and o.id::text=any(p_keys) group by c.code,c.name,c.latitude,c.longitude;
 end if;return out_id;
end$$;
-- Service-only routing write: users cannot forge elapsed road estimates.
create function public.preventa_ops_store_route(p_plan uuid,p_actor uuid,p_order uuid[],p_legs jsonb,p_return double precision,p_distance double precision,p_geometry jsonb) returns void language plpgsql security definer set search_path='' as $$
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
 update public.preventa_work_plans set status='superseded',version=version+1 where status='ready' and id<>p_plan and site=p.site and kind=p.kind and day=p.day and route_code=p.route_code and worker_id is not distinct from p.worker_id and journey_id is null;
 update public.preventa_work_plans set status='ready',road_seconds=(select sum(leg_seconds) from public.preventa_work_plan_stops where plan_id=p_plan)+p_return,return_seconds=p_return,distance_m=p_distance,geometry=p_geometry,provider='OSRM · vehículo liviano · sin tráfico en vivo',optimized_at=now(),version=version+1 where id=p_plan;
end$$;
revoke all on function public.preventa_ops_store_route(uuid,uuid,uuid[],jsonb,double precision,double precision,jsonb) from public,anon,authenticated,preventa_operativo;
grant execute on function public.preventa_ops_store_route(uuid,uuid,uuid[],jsonb,double precision,double precision,jsonb) to service_role;
create function public.preventa_ops_routing_slot() returns timestamptz language plpgsql security definer set search_path='' as $$declare t timestamptz;begin update bia_acl_private.preventa_routing_gate set next_at=greatest(next_at,clock_timestamp())+interval '1.1 seconds' returning next_at-interval '1.1 seconds' into t;return t;end$$;
revoke all on function public.preventa_ops_routing_slot() from public,anon,authenticated,preventa_operativo;
grant execute on function public.preventa_ops_routing_slot() to service_role;
create function public.preventa_ops_apply_plan(p_journey uuid,p_plan uuid) returns void language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;p public.preventa_work_plans;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if j.plan_id=p_plan then return;end if;
 if j.departed_at is not null then raise exception 'RECORRIDO_YA_INICIADO';end if;
 select * into p from public.preventa_work_plans where id=p_plan for update;
 if p.id is null or p.status<>'ready' or p.site<>j.site or p.kind<>j.kind or p.route_code<>j.route_code or p.day<>j.day or (p.worker_id is not null and p.worker_id<>j.worker_id) or (p.journey_id is not null and p.journey_id<>j.id) then raise exception 'PLAN_NO_CORRESPONDE_A_LA_JORNADA';end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops s cross join lateral unnest(s.order_ids) oid left join public.preventa_work_orders o on o.id=oid left join public.preventa_invoices i on i.number=o.invoice_number where s.plan_id=p.id and (o.id is null or o.taken_at+interval '48 hours'>now() or not coalesce(i.present_in_source,false))) then raise exception 'NO_SE_CUMPLEN_LAS_48_HORAS';end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops ps join public.preventa_work_visits v on v.order_ids && ps.order_ids join public.preventa_work_journeys other on other.id=v.journey_id where ps.plan_id=p.id and other.id<>j.id and (other.ended_at is null or v.outcome='entregado')) then raise exception 'PEDIDO_YA_ASIGNADO_O_ENTREGADO';end if;
 insert into public.preventa_work_visits(journey_id,seq,site,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers,expected_leg_seconds,expected_service_seconds) select j.id,s.seq,j.site,s.customer_code,s.customer_name,s.latitude,s.longitude,s.order_ids,s.invoice_numbers,s.leg_seconds,p.service_seconds from public.preventa_work_plan_stops s where s.plan_id=p.id order by s.seq;
 update public.preventa_work_plans set status='used',worker_id=j.worker_id where id=p.id;
 update public.preventa_work_journeys set plan_id=p.id,departed_at=now(),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'INICIAR_RECORRIDO',jsonb_build_object('plan',p.id,'paradas',p.stop_count));
end$$;

create function public.preventa_ops_photo_begin(p_visit uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;j public.preventa_work_journeys;p text;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) or v.state<>'pending' then raise exception 'VISITA_NO_DISPONIBLE';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state='visiting') then raise exception 'FINALIZA_O_PAUSA_EL_CLIENTE_ACTUAL';end if;
 p:=auth.uid()::text||'/'||j.id::text||'/'||v.id::text||'/'||gen_random_uuid()::text||'.jpg';
 insert into bia_acl_private.preventa_photo_tickets(path,user_id,visit_id) values(p,auth.uid(),v.id);
 return jsonb_build_object('bucket','preventa-visitas','path',p);
end$$;
create function bia_acl_private.preventa_photo_read(p_path text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from bia_acl_private.preventa_photo_tickets t join public.preventa_work_visits v on v.id=t.visit_id where t.path=p_path and bia_acl_private.preventa_work_journey_read(v.journey_id))$$;
create function bia_acl_private.preventa_photo_upload(p_path text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from bia_acl_private.preventa_photo_tickets t join public.preventa_work_visits v on v.id=t.visit_id where t.path=p_path and t.user_id=auth.uid() and t.used_at is null and t.created_at>now()-interval '15 minutes' and v.state='pending' and bia_acl_private.preventa_work_journey_write(v.journey_id))$$;
revoke all on function bia_acl_private.preventa_photo_read(text),bia_acl_private.preventa_photo_upload(text) from public,anon;
grant execute on function bia_acl_private.preventa_photo_read(text),bia_acl_private.preventa_photo_upload(text) to authenticated,preventa_operativo;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('preventa-visitas','preventa-visitas',false,5242880,array['image/jpeg']) on conflict(id) do nothing;
grant usage on schema storage to preventa_operativo;
grant select,insert on storage.objects to preventa_operativo;
create policy preventa_photo_read on storage.objects for select to authenticated,preventa_operativo using(bucket_id='preventa-visitas' and bia_acl_private.preventa_photo_read(name));
create policy preventa_photo_upload on storage.objects for insert to authenticated,preventa_operativo with check(bucket_id='preventa-visitas' and bia_acl_private.preventa_photo_upload(name));
create policy preventa_storage_isolation on storage.objects as restrictive for all to preventa_operativo using(bucket_id='preventa-visitas') with check(bucket_id='preventa-visitas');
create function public.preventa_ops_arrive(p_visit uuid,p_photo text,p_lat double precision,p_lng double precision,p_accuracy double precision) returns void language plpgsql security definer set search_path='' as $$
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
 if j.kind='motorista' and exists(select 1 from unnest(v.order_ids) oid left join public.preventa_work_orders o on o.id=oid left join public.preventa_invoices i on i.number=o.invoice_number where o.id is null or o.taken_at+interval '48 hours'>now() or not coalesce(i.present_in_source,false)) then raise exception 'NO_SE_CUMPLEN_LAS_48_HORAS';end if;
 update bia_acl_private.preventa_photo_tickets set used_at=now() where path=t.path;
 update public.preventa_work_visits set state='visiting',arrived_at=now(),last_active_at=now(),arrival_lat=p_lat,arrival_lng=p_lng,arrival_accuracy=p_accuracy,photo_path=p_photo,version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'LLEGADA',jsonb_build_object('latitude',p_lat,'longitude',p_lng,'accuracy',p_accuracy,'photo',p_photo));
end$$;
create function public.preventa_ops_pause(p_visit uuid,p_reason text,p_minutes int default null,p_notes text default '') returns void language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;j public.preventa_work_journeys;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state<>'visiting' or nullif(btrim(p_reason),'') is null or length(p_reason)>200 or (p_minutes is not null and p_minutes not between 1 and 1440) then raise exception 'PAUSA_INVALIDA';end if;
 update public.preventa_work_visits set state='paused',service_seconds=service_seconds+greatest(0,extract(epoch from now()-last_active_at)),last_active_at=null,pause_started_at=now(),pause_reason=btrim(p_reason),expected_wait_minutes=p_minutes,notes=left(p_notes,2000),version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'PAUSA',jsonb_build_object('motivo',p_reason,'minutos_estimados',p_minutes,'notas',left(p_notes,2000)));
end$$;
create function public.preventa_ops_resume(p_visit uuid) returns void language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;j public.preventa_work_journeys;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state<>'paused' then raise exception 'LA_VISITA_NO_ESTA_PAUSADA';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state='visiting') then raise exception 'FINALIZA_O_PAUSA_EL_CLIENTE_ACTUAL';end if;
 update public.preventa_work_visits set state='visiting',last_active_at=now(),paused_seconds=paused_seconds+greatest(0,extract(epoch from now()-pause_started_at)),pause_started_at=null,version=version+1 where id=v.id;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action) values(j.id,v.id,auth.uid(),'REANUDAR');
end$$;
create function public.preventa_ops_finish_visit(p_visit uuid,p_outcome text,p_notes text default '',p_order_reference text default '') returns void language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;j public.preventa_work_journeys;oid uuid;
begin
 select * into v from public.preventa_work_visits where id=p_visit;select * into j from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state<>'visiting' then raise exception 'LA_VISITA_NO_ESTA_EN_ATENCION';end if;
 if (j.kind='preventista' and p_outcome not in ('pedido','sin_pedido','fallido')) or (j.kind='motorista' and p_outcome not in ('entregado','fallido')) or p_outcome is null then raise exception 'RESULTADO_NO_PERMITIDO_PARA_ESTE_ACCESO';end if;
 if p_outcome='fallido' and nullif(btrim(p_notes),'') is null then raise exception 'JUSTIFICACION_OBLIGATORIA';end if;
 update public.preventa_work_visits set state=case when p_outcome='fallido' then 'failed' else 'visited' end,finished_at=now(),service_seconds=service_seconds+greatest(0,extract(epoch from now()-last_active_at)),last_active_at=null,outcome=p_outcome,notes=left(p_notes,2000),version=version+1 where id=v.id;
 if p_outcome='pedido' then insert into public.preventa_work_orders(site,customer_code,taken_at,reference,visit_id,source,created_by) values(j.site,v.customer_code,now(),left(p_order_reference,120),v.id,'visita',auth.uid()) returning id into oid;end if;
 insert into public.preventa_work_events(journey_id,visit_id,actor,action,details) values(j.id,v.id,auth.uid(),'FINALIZAR_VISITA',jsonb_build_object('resultado',p_outcome,'notas',left(p_notes,2000),'pedido',oid));
end$$;
create function public.preventa_ops_end(p_journey uuid,p_reason text default '') returns void language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state='visiting') then raise exception 'FINALIZA_O_PAUSA_EL_CLIENTE_ACTUAL';end if;
 if exists(select 1 from public.preventa_work_visits where journey_id=j.id and state in ('pending','paused')) and nullif(btrim(p_reason),'') is null then raise exception 'INDICA_LA_DISPOSICION_DE_LOS_PENDIENTES';end if;
 update public.preventa_work_visits set disposition=left(p_reason,2000),paused_seconds=paused_seconds+case when pause_started_at is not null then greatest(0,extract(epoch from now()-pause_started_at)) else 0 end,pause_started_at=null where journey_id=j.id and state in ('pending','paused');
 update public.preventa_work_journeys set ended_at=now(),end_reason=left(p_reason,2000),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'FINALIZAR_JORNADA',jsonb_build_object('motivo',left(p_reason,2000)));
end$$;
create function public.preventa_ops_snapshot(p_journey uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not bia_acl_private.preventa_work_journey_read(p_journey) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 return jsonb_build_object('server_now',now(),'journey',(select to_jsonb(j) from public.preventa_work_journeys j where id=p_journey),'visits',(select coalesce(jsonb_agg(to_jsonb(v) order by seq),'[]') from public.preventa_work_visits v where journey_id=p_journey),'plan',(select to_jsonb(p) from public.preventa_work_plans p join public.preventa_work_journeys j on j.plan_id=p.id where j.id=p_journey));
end$$;

-- Private dashboard data: the shared operational accounts cannot call this function.
create function public.preventa_ops_summary(p_day date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from bia_acl_private.accounts a where a.user_id=auth.uid() and a.role in ('administrador','coordinador','jefatura_zn','jefatura_zc')) or not public.bia_can('preventa','read') then raise exception 'SOLO_SUPERVISION';end if;
 return jsonb_build_object('server_now',now(),'journeys',(select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('worker_name',w.name) order by j.started_at),'[]') from public.preventa_work_journeys j join public.preventa_drivers w on w.id=j.worker_id where j.day=p_day and bia_acl_private.preventa_work_manager(j.site)),'visits',(select coalesce(jsonb_agg(to_jsonb(v) order by j.started_at,v.seq),'[]') from public.preventa_work_visits v join public.preventa_work_journeys j on j.id=v.journey_id where j.day=p_day and bia_acl_private.preventa_work_manager(j.site)),'plans',(select coalesce(jsonb_agg(to_jsonb(p)),'[]') from public.preventa_work_plans p where p.day=p_day and bia_acl_private.preventa_work_manager(p.site)),'prepared_stops',(select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('state','pending','prepared',true,'site',p.site,'route_code',p.route_code,'kind',p.kind,'worker_id',p.worker_id)),'[]') from public.preventa_work_plan_stops t join public.preventa_work_plans p on p.id=t.plan_id where p.day=p_day and p.status='ready' and p.journey_id is null and bia_acl_private.preventa_work_manager(p.site)));
end$$;
create function public.preventa_ops_finish_setup(p_target uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from auth.users where id=p_target and email='preventistas.preventa@intranet.invalid' and role='preventa_operativo' and raw_app_meta_data->>'module_only'='preventa') then raise exception 'CUENTA_OPERATIVA_INVALIDA';end if;
 insert into bia_acl_private.accounts(user_id,nombre_corto,role,sites,apps) values(p_target,'Preventistas Preventa','verificador',array['SPS'],array['preventa']) on conflict(user_id) do nothing;
 insert into bia_acl_private.preventa_operator_access(user_id,kind) values(p_target,'preventista') on conflict(user_id) do nothing;
end$$;
revoke all on function public.preventa_ops_finish_setup(uuid) from public,anon,authenticated,preventa_operativo;
grant execute on function public.preventa_ops_finish_setup(uuid) to service_role;
do $$declare r record;begin for r in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'preventa_ops_%' and proname not in ('preventa_ops_store_route','preventa_ops_routing_slot','preventa_ops_finish_setup') loop execute format('revoke all on function %s from public,anon',r.signature);execute format('grant execute on function %s to authenticated,preventa_operativo',r.signature);end loop;end$$;
notify pgrst,'reload schema';
