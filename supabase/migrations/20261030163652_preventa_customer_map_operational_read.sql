grant select on public.preventa_customer_schedule to preventa_operativo;
alter policy preventa_customer_schedule_read on public.preventa_customer_schedule to authenticated,preventa_operativo;
notify pgrst,'reload schema';
