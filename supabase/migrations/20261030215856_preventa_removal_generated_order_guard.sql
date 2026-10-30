create or replace function public.preventa_ops_remove_record(p_entity text,p_id uuid,p_version int,p_reason text,p_confirmation text) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.preventa_work_journeys;p public.preventa_work_plans;o public.preventa_work_orders;s text;v int;generated_order_ids uuid[];body jsonb;totals jsonb;result_id uuid;
begin
 if p_entity is null or p_entity not in ('journeys','plans','orders') or p_id is null or p_version is null or p_confirmation is distinct from 'ELIMINAR' or length(btrim(coalesce(p_reason,'')))<5 or length(p_reason)>2000 then raise exception 'CONFIRMA_EL_REGISTRO_Y_EL_MOTIVO';end if;
 if p_entity='journeys' then select * into j from public.preventa_work_journeys where id=p_id for update;s=j.site;v=j.version;
 elsif p_entity='plans' then select * into p from public.preventa_work_plans where id=p_id for update;s=p.site;v=p.version;
 else select * into o from public.preventa_work_orders where id=p_id for update;s=o.site;v=o.version;end if;
 if s is null or not bia_acl_private.preventa_work_manager(s) then raise exception 'SOLO_SUPERVISION';end if;
 if v<>p_version then raise exception 'EL_REGISTRO_CAMBIO_ACTUALIZA_EL_HISTORICO';end if;
 if (p_entity='journeys' and j.deleted_at is not null) or (p_entity='plans' and p.deleted_at is not null) or (p_entity='orders' and o.deleted_at is not null) then raise exception 'REGISTRO_YA_ELIMINADO';end if;
 if p_entity='journeys' then
  -- Same order lock family as apply_plan prevents a delivery from acquiring an order during removal.
  select coalesce(array_agg(id),'{}') into generated_order_ids from public.preventa_work_orders where visit_id in(select id from public.preventa_work_visits where journey_id=j.id) and deleted_at is null;
  perform pg_advisory_xact_lock(hashtext('preventa-order-'||x::text)) from (select unnest(generated_order_ids) x order by x) q;
  if exists(select 1 from public.preventa_work_visits v0 join public.preventa_work_journeys j0 on j0.id=v0.journey_id where j0.id<>j.id and j0.deleted_at is null and v0.order_ids&&generated_order_ids)
   or exists(select 1 from public.preventa_work_plan_stops t join public.preventa_work_plans p0 on p0.id=t.plan_id where p0.deleted_at is null and p0.status in ('draft','ready','used') and p0.id is distinct from j.plan_id and p0.journey_id is distinct from j.id and t.order_ids&&generated_order_ids) then raise exception 'HAY_PEDIDOS_UTILIZADOS_EN_OTRO_RECORRIDO';end if;
  totals=jsonb_build_object('journeys',1,'visits',(select count(*) from public.preventa_work_visits where journey_id=j.id),'orders',cardinality(generated_order_ids),'plans',(select count(*) from public.preventa_work_plans where deleted_at is null and (id=j.plan_id or journey_id=j.id)));
  body=jsonb_build_object('journey',to_jsonb(j),'visits',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_visits x where journey_id=j.id),'events',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_events x where journey_id=j.id),'orders',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_orders x where id=any(generated_order_ids)),'plans',(select coalesce(jsonb_agg(to_jsonb(x)),'[]') from public.preventa_work_plans x where id=j.plan_id or journey_id=j.id));
  update public.preventa_work_orders set deleted_at=now(),version=version+1 where id=any(generated_order_ids) and deleted_at is null;
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
