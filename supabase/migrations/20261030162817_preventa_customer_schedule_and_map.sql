create table public.preventa_customer_schedule (
 site text not null,
 code text not null check(length(btrim(code))>0),
 name text not null check(length(btrim(name))>0),
 business_base text not null,
 presale_route text not null,
 presale_day smallint not null check(presale_day between 1 and 6),
 presale_week smallint not null check(presale_week in (1,2)),
 latitude double precision not null check(latitude between -90 and 90),
 longitude double precision not null check(longitude between -180 and 180),
 census text,
 delivery_route text not null,
 delivery_day smallint not null check(delivery_day between 1 and 6),
 delivery_week smallint not null check(delivery_week in (1,2)),
 start_date date not null,
 active boolean not null default true,
 source_file text not null,
 source_sha256 text not null check(length(source_sha256)=64),
 source_row integer not null check(source_row>1),
 source_data jsonb not null,
 imported_at timestamptz not null default now(),
 primary key(site,code)
);
alter table public.preventa_customer_schedule enable row level security;
revoke all on public.preventa_customer_schedule from public,anon,authenticated;
grant select on public.preventa_customer_schedule to authenticated;
create policy preventa_customer_schedule_read on public.preventa_customer_schedule for select to authenticated
 using ((select auth.uid()) is not null and public.bia_can('preventa','read',site));
create index preventa_customer_schedule_delivery_idx on public.preventa_customer_schedule(site,delivery_route,delivery_week,delivery_day) where active;
create index preventa_customer_schedule_presale_idx on public.preventa_customer_schedule(site,presale_route) where active;
comment on table public.preventa_customer_schedule is 'Cartera de puntos y calendario quincenal importado del Excel. Semana 1 inicia con visitas el 2026-11-03; semanas de lunes a domingo, sin atención dominical.';
notify pgrst,'reload schema';
