-- User explicitly requested that Preventistas and Motoristas combine selections across routes 501, 561 and 564.
-- Keep the assigned initial-route guard unchanged. Add explicit per-worker preparation grants, not access to every future route.
create table bia_acl_private.preventa_worker_routes(worker_id uuid not null references public.preventa_drivers(id),route_code text not null references public.preventa_routes(code),created_at timestamptz not null default now(),primary key(worker_id,route_code));
alter table bia_acl_private.preventa_worker_routes enable row level security;
revoke all on bia_acl_private.preventa_worker_routes from public,anon,authenticated,preventa_operativo;
insert into bia_acl_private.preventa_worker_routes(worker_id,route_code)
select w.id,r.code from public.preventa_drivers w join public.preventa_routes r on r.site=w.site where w.site='SPS' and w.worker_kind in ('preventista','motorista') and r.code in ('501','561','564') and r.active;
create function bia_acl_private.preventa_worker_route_allowed(p_worker uuid,p_route text) returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from public.preventa_drivers w join public.preventa_routes r on r.site=w.site and r.code=p_route and r.active where w.id=p_worker and w.active and (w.assigned_route=r.code or exists(select 1 from bia_acl_private.preventa_worker_routes x where x.worker_id=w.id and x.route_code=r.code)))
$$;
revoke all on function bia_acl_private.preventa_worker_route_allowed(uuid,text) from public,anon,authenticated,preventa_operativo;
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
 if p_worker is not null and not exists(select 1 from public.preventa_drivers w where w.id=p_worker and w.active and w.site=p_site and w.worker_kind=p_kind and (p_kind<>'preventista' or w.assigned_route=p_route)) then raise exception 'PERSONAL_NO_CORRESPONDE_AL_PLAN';end if;
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
CREATE OR REPLACE FUNCTION public.preventa_ops_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare k text;
begin
 if auth.uid() is null or not public.bia_can('preventa','read') then raise exception 'SIN_ACCESO_PREVENTA';end if;
 select kind into k from bia_acl_private.preventa_operator_access where user_id=auth.uid();
 return jsonb_build_object('kind',k,'workers',(select coalesce(jsonb_agg(to_jsonb(w)||jsonb_build_object('allowed_routes',(select coalesce(jsonb_agg(r.code order by r.code),'[]') from public.preventa_routes r where bia_acl_private.preventa_worker_route_allowed(w.id,r.code))) order by w.worker_kind,w.name),'[]') from public.preventa_drivers w where w.active and public.bia_can('preventa','read',w.site) and (bia_acl_private.preventa_work_manager(w.site) or w.worker_kind=k)), 'settings',(select coalesce(jsonb_agg(to_jsonb(s)),'[]') from public.preventa_work_settings s where public.bia_can('preventa','read',s.site)));
end$function$;
notify pgrst,'reload schema';

