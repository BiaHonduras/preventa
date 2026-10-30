create function bia_acl_private.preventa_worker_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.worker_kind='preventista' and (new.assigned_route is null or not exists(select 1 from public.preventa_routes r where r.code=new.assigned_route and r.site=new.site and r.active)) then raise exception 'ASIGNA_UNA_RUTA_VALIDA_AL_PREVENTISTA';end if;
 if tg_op='UPDATE' and (new.worker_kind is distinct from old.worker_kind or new.assigned_route is distinct from old.assigned_route or new.site is distinct from old.site) and exists(select 1 from public.preventa_work_journeys j where j.worker_id=old.id and j.ended_at is null) then raise exception 'FINALIZA_LA_JORNADA_ANTES_DE_CAMBIAR_LA_ASIGNACION';end if;
 return new;
end$$;
revoke all on function bia_acl_private.preventa_worker_guard() from public,anon,authenticated,preventa_operativo;
create trigger preventa_worker_guard before insert or update on public.preventa_drivers for each row execute function bia_acl_private.preventa_worker_guard();
create or replace function public.preventa_ops_start(p_worker uuid,p_route text) returns uuid language plpgsql security definer set search_path='' as $$
declare w public.preventa_drivers;j public.preventa_work_journeys;out_id uuid;
begin
 select * into w from public.preventa_drivers where id=p_worker and active for share;
 if w.id is null or not bia_acl_private.preventa_work_role(w.site,w.worker_kind) then raise exception 'PERSONAL_NO_AUTORIZADO';end if;
 if not exists(select 1 from public.preventa_routes where code=p_route and site=w.site and active) then raise exception 'RUTA_NO_DISPONIBLE';end if;
 if w.worker_kind='preventista' and w.assigned_route is distinct from p_route then raise exception 'RUTA_NO_ASIGNADA_AL_PREVENTISTA';end if;
 perform pg_advisory_xact_lock(hashtext('preventa-worker-'||p_worker));
 select * into j from public.preventa_work_journeys where worker_id=p_worker and ended_at is null;
 if j.id is not null then if j.actor=auth.uid() then return j.id;else raise exception 'PERSONAL_CON_JORNADA_ACTIVA';end if;end if;
 insert into public.preventa_work_journeys(site,route_code,kind,worker_id,actor) values(w.site,p_route,w.worker_kind,p_worker,auth.uid()) returning id into out_id;
 insert into public.preventa_work_events(journey_id,actor,action) values(out_id,auth.uid(),'INICIAR_JORNADA');return out_id;
end$$;
create or replace function public.preventa_ops_apply_plan(p_journey uuid,p_plan uuid) returns void language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;p public.preventa_work_plans;
begin
 select * into j from public.preventa_work_journeys where id=p_journey for update;
 if not bia_acl_private.preventa_work_journey_write(j.id) then raise exception 'JORNADA_NO_AUTORIZADA';end if;
 if j.plan_id=p_plan then return;end if;
 if j.departed_at is not null then raise exception 'RECORRIDO_YA_INICIADO';end if;
 select * into p from public.preventa_work_plans where id=p_plan for update;
 if p.id is null or p.status<>'ready' or p.site<>j.site or p.kind<>j.kind or p.route_code<>j.route_code or p.day<>j.day or (p.worker_id is not null and p.worker_id<>j.worker_id) or (p.journey_id is not null and p.journey_id<>j.id) then raise exception 'PLAN_NO_CORRESPONDE_A_LA_JORNADA';end if;
 if j.kind='motorista' then perform pg_advisory_xact_lock(hashtext('preventa-order-'||x::text)) from (select distinct unnest(order_ids) as x from public.preventa_work_plan_stops where plan_id=p.id order by x) ids;end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops s cross join lateral unnest(s.order_ids) oid left join public.preventa_work_orders o on o.id=oid left join public.preventa_invoices i on i.number=o.invoice_number where s.plan_id=p.id and (o.id is null or o.taken_at+interval '48 hours'>now() or not coalesce(i.present_in_source,false))) then raise exception 'NO_SE_CUMPLEN_LAS_48_HORAS';end if;
 if j.kind='motorista' and exists(select 1 from public.preventa_work_plan_stops ps join public.preventa_work_visits v on v.order_ids && ps.order_ids join public.preventa_work_journeys other on other.id=v.journey_id where ps.plan_id=p.id and other.id<>j.id and (other.ended_at is null or v.outcome='entregado')) then raise exception 'PEDIDO_YA_ASIGNADO_O_ENTREGADO';end if;
 insert into public.preventa_work_visits(journey_id,seq,site,customer_code,customer_name,latitude,longitude,order_ids,invoice_numbers,expected_leg_seconds,expected_service_seconds) select j.id,s.seq,j.site,s.customer_code,s.customer_name,s.latitude,s.longitude,s.order_ids,s.invoice_numbers,s.leg_seconds,p.service_seconds from public.preventa_work_plan_stops s where s.plan_id=p.id order by s.seq;
 update public.preventa_work_plans set status='used',worker_id=j.worker_id where id=p.id;
 update public.preventa_work_journeys set plan_id=p.id,departed_at=now(),version=version+1 where id=j.id;
 insert into public.preventa_work_events(journey_id,actor,action,details) values(j.id,auth.uid(),'INICIAR_RECORRIDO',jsonb_build_object('plan',p.id,'paradas',p.stop_count));
end$$;

notify pgrst,'reload schema';