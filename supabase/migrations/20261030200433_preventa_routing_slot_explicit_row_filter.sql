create or replace function public.preventa_ops_routing_slot() returns timestamptz language plpgsql security definer set search_path='' as $$
declare t timestamptz;
begin
 update bia_acl_private.preventa_routing_gate
 set next_at=greatest(next_at,clock_timestamp())+interval '1.1 seconds'
 where id=true
 returning next_at-interval '1.1 seconds' into t;
 if t is null then raise exception 'CONTROL_DE_CALCULOS_NO_CONFIGURADO';end if;
 return t;
end$$;
revoke all on function public.preventa_ops_routing_slot() from public,anon,authenticated,preventa_operativo;
grant execute on function public.preventa_ops_routing_slot() to service_role;
notify pgrst,'reload schema';
