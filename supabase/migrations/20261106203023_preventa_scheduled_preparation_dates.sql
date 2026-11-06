
alter table public.preventa_work_journeys add column prepared_plan_id uuid references public.preventa_work_plans(id);
create function public.preventa_ops_schedule_day(p_journey uuid,p_day date) returns void language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;today date:=(now() at time zone 'America/Tegucigalpa')::date;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if j.departed_at is not null then raise exception 'NO_SE_PUEDE_CAMBIAR_FECHA_EN_RECORRIDO';end if;
 if p_day is null or p_day<today or p_day>today+366 or extract(isodow from p_day)=7 then raise exception 'FECHA_INVALIDA_SELECCIONA_UN_DIA_DE_LUNES_A_SABADO';end if;
 if j.day is distinct from p_day then
 update public.preventa_work_journeys set day=p_day,prepared_plan_id=null,version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'PROGRAMAR_FECHA',jsonb_build_object('fecha',p_day));
 end if;
end$$;
revoke all on function public.preventa_ops_schedule_day(uuid,date) from public,anon;
grant execute on function public.preventa_ops_schedule_day(uuid,date) to authenticated,preventa_operativo;
create function public.preventa_ops_start_dated(p_worker uuid,p_route text,p_day date) returns uuid language plpgsql security definer set search_path='' as $$
declare jid uuid;
begin
 jid:=public.preventa_ops_start(p_worker,p_route);
 perform public.preventa_ops_schedule_day(jid,p_day);
 return jid;
end$$;
revoke all on function public.preventa_ops_start_dated(uuid,text,date) from public,anon;
grant execute on function public.preventa_ops_start_dated(uuid,text,date) to authenticated,preventa_operativo;
create function public.preventa_ops_save_preparation(p_journey uuid,p_plan uuid) returns void language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;p public.preventa_work_plans;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) or j.departed_at is not null then raise exception 'JORNADA_NO_ADMITE_PREPARACION';end if;
 select * into p from public.preventa_work_plans where id=p_plan for update;
 if p.id is null or p.deleted_at is not null or p.status<>'ready' or p.site<>j.site or p.kind<>j.kind or p.route_code<>j.route_code or p.day<>j.day or (p.worker_id is not null and p.worker_id<>j.worker_id) or (p.journey_id is not null and p.journey_id<>j.id) then raise exception 'PLAN_NO_CORRESPONDE_A_LA_JORNADA';end if;
 update public.preventa_work_journeys set prepared_plan_id=p.id,version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'GUARDAR_PREPARACION',jsonb_build_object('plan',p.id,'fecha',j.day));
end$$;
revoke all on function public.preventa_ops_save_preparation(uuid,uuid) from public,anon;
grant execute on function public.preventa_ops_save_preparation(uuid,uuid) to authenticated,preventa_operativo;
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
 if j.day<>(now() at time zone 'America/Tegucigalpa')::date then raise exception 'EL_RECORRIDO_SOLO_PUEDE_INICIARSE_EN_LA_FECHA_PROGRAMADA';end if;
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
 update public.preventa_work_journeys set plan_id=p.id,departed_at=now(),started_at=case when (started_at at time zone 'America/Tegucigalpa')::date<>j.day then now() else started_at end,version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'INICIAR_RECORRIDO',jsonb_build_object('plan',p.id,'paradas',p.stop_count));
end$function$;
CREATE OR REPLACE FUNCTION public.preventa_ops_snapshot(p_journey uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not bia_acl_private.preventa_work_journey_read(p_journey) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 return jsonb_build_object('server_now',now(),'bank',(select to_jsonb(b) from public.preventa_bank_stops b where journey_id=p_journey),'journey',(select to_jsonb(j) from public.preventa_work_journeys j where id=p_journey),'visits',(select coalesce(jsonb_agg(to_jsonb(v) order by seq),'[]') from public.preventa_work_visits v where journey_id=p_journey),'plan',(select to_jsonb(p) from public.preventa_work_plans p join public.preventa_work_journeys j on coalesce(j.plan_id,j.prepared_plan_id)=p.id where j.id=p_journey));
end$function$;
notify pgrst,'reload schema';