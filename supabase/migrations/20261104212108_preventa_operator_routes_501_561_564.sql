create function bia_acl_private.preventa_route_scope(p_site text,p_route text) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and (not exists(select 1 from bia_acl_private.preventa_operator_access where user_id=auth.uid()) or (p_site='SPS' and p_route in ('501','561','564')))
$$;
revoke all on function bia_acl_private.preventa_route_scope(text,text) from public,anon;
grant execute on function bia_acl_private.preventa_route_scope(text,text) to authenticated,preventa_operativo;
create policy preventa_operator_route_scope on public.preventa_invoices as restrictive for select to authenticated,preventa_operativo using(bia_acl_private.preventa_route_scope(site,source_route));
create policy preventa_operator_route_scope on public.preventa_customers as restrictive for select to authenticated,preventa_operativo using(bia_acl_private.preventa_route_scope(site,source_route));
create policy preventa_operator_route_scope on public.preventa_customer_schedule as restrictive for select to authenticated,preventa_operativo using(bia_acl_private.preventa_route_scope(site,presale_route));
create policy preventa_operator_route_scope on public.preventa_routes as restrictive for select to authenticated,preventa_operativo using(bia_acl_private.preventa_route_scope(site,code));
CREATE OR REPLACE FUNCTION bia_acl_private.preventa_worker_route_allowed(p_worker uuid, p_route text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
select exists(select 1 from public.preventa_drivers w join public.preventa_routes r on r.site=w.site and r.code=p_route and r.active where w.id=p_worker and w.active and r.code in ('501','561','564') and (w.worker_kind='motorista' or w.assigned_route=r.code or exists(select 1 from bia_acl_private.preventa_worker_routes x where x.worker_id=w.id and x.route_code=r.code)))
$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_link_invoice_point(p_invoice text, p_customer text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not bia_acl_private.preventa_work_role('SPS','motorista') then raise exception 'SIN_PERMISO';end if;
 perform pg_advisory_xact_lock(hashtext('preventa-invoice-'||p_invoice));
 if not exists(select 1 from public.preventa_invoices where number=p_invoice and site='SPS' and present_in_source and bia_acl_private.preventa_route_scope(site,source_route)) or not exists(select 1 from public.preventa_customer_schedule where site='SPS' and code=p_customer and active and bia_acl_private.preventa_route_scope(site,presale_route)) then raise exception 'FACTURA_O_CLIENTE_NO_DISPONIBLE';end if;
 if exists(select 1 from public.preventa_work_visits v join public.preventa_work_journeys j on j.id=v.journey_id where p_invoice=any(v.invoice_numbers) and j.deleted_at is null and (j.ended_at is null or v.outcome='entregado')) then raise exception 'FACTURA_YA_ASIGNADA_O_ENTREGADA';end if;
 if exists(select 1 from public.preventa_work_orders where invoice_number=p_invoice and deleted_at is null and customer_code<>p_customer) then raise exception 'CLIENTE_DIFIERE_DEL_PEDIDO';end if;
 insert into public.preventa_invoice_points(invoice_number,site,customer_code,linked_by) values(p_invoice,'SPS',p_customer,auth.uid()) on conflict(invoice_number) do update set customer_code=excluded.customer_code,linked_by=excluded.linked_by,linked_at=now();
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_create_plan(p_kind text, p_site text, p_route text, p_day date, p_departure timestamp with time zone, p_keys text[], p_worker uuid DEFAULT NULL::uuid, p_journey uuid DEFAULT NULL::uuid, p_buffer_minutes integer DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare j public.preventa_work_journeys;out_id uuid;n int;missing int;
begin
 if not bia_acl_private.preventa_route_scope(p_site,p_route) then raise exception 'RUTA_NO_AUTORIZADA';end if;
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
 select count(distinct code) into n from public.preventa_customer_schedule where site=p_site and active and bia_acl_private.preventa_route_scope(site,presale_route) and code=any(p_keys) and exists(select 1 from public.preventa_routes r where r.code=preventa_customer_schedule.presale_route and r.site=p_site and r.active) and (p_worker is null or bia_acl_private.preventa_worker_route_allowed(p_worker,presale_route));
 if n<>(select count(distinct x) from unnest(p_keys) x) then raise exception 'CLIENTES_FUERA_DE_LAS_RUTAS_PERMITIDAS';end if;
 else
 perform pg_advisory_xact_lock(hashtext('preventa-invoice-'||x)) from (select distinct unnest(p_keys) x order by x) keys;
 select count(*) into missing from unnest(p_keys) x where not exists(select 1 from public.preventa_invoices i left join public.preventa_work_orders o on o.invoice_number=i.number and o.deleted_at is null left join public.preventa_invoice_points ip on ip.invoice_number=i.number join public.preventa_customer_schedule c on c.site=i.site and c.code=coalesce(o.customer_code,ip.customer_code,i.client_code) and c.active where i.number=x and i.site=p_site and i.present_in_source and bia_acl_private.preventa_route_scope(i.site,i.source_route) and bia_acl_private.preventa_route_scope(c.site,c.presale_route));
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
