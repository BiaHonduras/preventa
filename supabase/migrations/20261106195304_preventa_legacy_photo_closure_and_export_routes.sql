CREATE OR REPLACE FUNCTION public.preventa_ops_export(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not exists(select 1 from public.preventa_work_settings where bia_acl_private.preventa_work_manager(site)) then raise exception 'SIN_PERMISO_DE_EXPORTACION';end if;
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'RANGO_MAXIMO_366_DIAS';end if;
 return jsonb_build_object('generated_at',now(),
 'journeys',(select coalesce(jsonb_agg(to_jsonb(j)||jsonb_build_object('worker_name',w.name)),'[]') from public.preventa_work_journeys j join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site)),
 'visits',(select coalesce(jsonb_agg(to_jsonb(v)||jsonb_build_object('worker_name',w.name,'kind',j.kind,'day',j.day,'route_code',coalesce(c.presale_route,j.route_code),'worker_id',j.worker_id)),'[]') from public.preventa_work_visits v left join public.preventa_customer_schedule c on c.site=v.site and c.code=v.customer_code join public.preventa_work_journeys j on j.id=v.journey_id join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site)),
 'bank',(select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('worker_name',w.name,'day',j.day,'site',j.site,'worker_id',j.worker_id,'kind',j.kind,'route_code',j.route_code)),'[]') from public.preventa_bank_stops b join public.preventa_work_journeys j on j.id=b.journey_id join public.preventa_drivers w on w.id=j.worker_id where j.deleted_at is null and j.day between p_from and p_to and bia_acl_private.preventa_work_manager(j.site)));
end$function$;
create function public.preventa_ops_close_with_photo(p_visit uuid,p_photo text,p_reason text,p_subreason text default null,p_payment text default null,p_comment text default '',p_reference text default '') returns void language plpgsql security definer set search_path='' as $$
declare v public.preventa_work_visits;t bia_acl_private.preventa_photo_tickets;
begin
 select * into v from public.preventa_work_visits where id=p_visit;perform 1 from public.preventa_work_journeys where id=v.journey_id for update;
 if not bia_acl_private.preventa_work_journey_write(v.journey_id) then raise exception 'VISITA_NO_AUTORIZADA';end if;
 select * into v from public.preventa_work_visits where id=p_visit for update;
 if v.state<>'visiting' then raise exception 'LA_VISITA_NO_ESTA_EN_ATENCION';end if;
 select * into t from bia_acl_private.preventa_photo_tickets where path=p_photo and visit_id=p_visit and user_id=auth.uid() and used_at is null and created_at>now()-interval '15 minutes' for update;
 if t.path is null or not exists(select 1 from storage.objects where bucket_id='preventa-visitas' and name=p_photo and metadata->>'mimetype'='image/jpeg') then raise exception 'FOTOGRAFIA_REQUERIDA';end if;
 update public.preventa_work_visits set photo_path=p_photo where id=p_visit;
 perform public.preventa_ops_close_visit(p_visit,p_reason,p_subreason,p_payment,p_comment,p_reference);
 update bia_acl_private.preventa_photo_tickets set used_at=now() where path=p_photo;
end$$;
revoke all on function public.preventa_ops_close_with_photo(uuid,text,text,text,text,text,text) from public,anon;
grant execute on function public.preventa_ops_close_with_photo(uuid,text,text,text,text,text,text) to authenticated,preventa_operativo;
notify pgrst,'reload schema';