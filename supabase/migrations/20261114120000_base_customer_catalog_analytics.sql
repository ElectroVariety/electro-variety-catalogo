create table if not exists public.base_customer_catalog_analytics_events (
  id bigint generated always as identity primary key,
  visitor_id uuid not null,
  session_id uuid not null,
  event_type text not null check (event_type = any (array[
    'visit','product_consult','delivery_consult','install',
    'notification_granted','notification_denied','push_subscribed'
  ])),
  product_id bigint references public.products(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.base_customer_catalog_analytics_events enable row level security;
revoke all on public.base_customer_catalog_analytics_events from public, anon, authenticated;

create index if not exists base_customer_catalog_analytics_created_idx
  on public.base_customer_catalog_analytics_events(created_at desc, event_type);
create index if not exists base_customer_catalog_analytics_session_idx
  on public.base_customer_catalog_analytics_events(session_id, created_at desc);
create index if not exists base_customer_catalog_analytics_product_idx
  on public.base_customer_catalog_analytics_events(product_id, created_at desc)
  where event_type = 'product_consult';
create unique index if not exists base_customer_catalog_analytics_one_visit_per_session
  on public.base_customer_catalog_analytics_events(session_id)
  where event_type = 'visit';
create unique index if not exists base_customer_catalog_analytics_one_consent_event_per_visitor
  on public.base_customer_catalog_analytics_events(visitor_id, event_type)
  where event_type in ('install','notification_granted','notification_denied','push_subscribed');

create or replace function public.record_base_customer_catalog_event(
  p_visitor_id uuid,
  p_session_id uuid,
  p_event_type text,
  p_product_id bigint default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_visitor_id is null or p_session_id is null then
    return false;
  end if;

  if p_event_type not in (
    'visit','product_consult','delivery_consult','install',
    'notification_granted','notification_denied','push_subscribed'
  ) then
    raise exception 'Tipo de actividad no permitido' using errcode = '22023';
  end if;

  if p_event_type = 'product_consult'
     and (p_product_id is null or not exists (
       select 1 from public.products p where p.id = p_product_id and p.active
     )) then
    return false;
  end if;

  if (
    select count(*) from public.base_customer_catalog_analytics_events e
    where e.session_id = p_session_id
      and e.created_at >= now() - interval '1 hour'
  ) >= 180 then
    return false;
  end if;

  insert into public.base_customer_catalog_analytics_events(
    visitor_id, session_id, event_type, product_id
  ) values (
    p_visitor_id, p_session_id, p_event_type,
    case when p_event_type = 'product_consult' then p_product_id else null end
  ) on conflict do nothing;

  return found;
end;
$function$;

create or replace function public.admin_get_base_customer_catalog_analytics(
  p_from date default null,
  p_to date default null
)
returns table(
  visits bigint,
  unique_visitors bigint,
  product_consults bigint,
  delivery_consults bigint,
  installs bigint,
  notification_grants bigint,
  notification_denials bigint,
  push_subscriptions bigint,
  top_products jsonb,
  daily jsonb
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_from date := coalesce(p_from, (now() at time zone 'America/Argentina/Buenos_Aires')::date - 29);
  v_to date := coalesce(p_to, (now() at time zone 'America/Argentina/Buenos_Aires')::date);
  v_start timestamptz;
  v_end timestamptz;
begin
  if not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede consultar estas estadísticas' using errcode = '42501';
  end if;

  if v_from > v_to or v_to - v_from > 365 then
    raise exception 'El período debe ser válido y no superar 366 días' using errcode = '22023';
  end if;

  v_start := v_from::timestamp at time zone 'America/Argentina/Buenos_Aires';
  v_end := (v_to + 1)::timestamp at time zone 'America/Argentina/Buenos_Aires';

  return query
  with filtered as (
    select e.*, (e.created_at at time zone 'America/Argentina/Buenos_Aires')::date as local_date
    from public.base_customer_catalog_analytics_events e
    where e.created_at >= v_start and e.created_at < v_end
  ),
  daily_rollup as (
    select f.local_date,
      count(*) filter (where f.event_type = 'visit')::bigint as day_visits,
      count(*) filter (where f.event_type = 'product_consult')::bigint as day_product_consults,
      count(*) filter (where f.event_type = 'delivery_consult')::bigint as day_delivery_consults,
      count(*) filter (where f.event_type = 'install')::bigint as day_installs,
      count(*) filter (where f.event_type = 'notification_granted')::bigint as day_notification_grants
    from filtered f
    group by f.local_date
  )
  select
    count(*) filter (where f.event_type = 'visit')::bigint,
    count(distinct f.visitor_id)::bigint,
    count(*) filter (where f.event_type = 'product_consult')::bigint,
    count(*) filter (where f.event_type = 'delivery_consult')::bigint,
    count(*) filter (where f.event_type = 'install')::bigint,
    count(*) filter (where f.event_type = 'notification_granted')::bigint,
    count(*) filter (where f.event_type = 'notification_denied')::bigint,
    (select count(*) from public.client_push_subscriptions s where s.active)::bigint,
    coalesce((
      select jsonb_agg(jsonb_build_object('name', p.name, 'consults', x.consults) order by x.consults desc, p.name)
      from (
        select f2.product_id, count(*)::bigint as consults
        from filtered f2
        where f2.event_type = 'product_consult' and f2.product_id is not null
        group by f2.product_id
        order by count(*) desc
        limit 10
      ) x
      join public.products p on p.id = x.product_id
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', d.local_date,
        'visits', d.day_visits,
        'product_consults', d.day_product_consults,
        'delivery_consults', d.day_delivery_consults,
        'installs', d.day_installs,
        'notification_grants', d.day_notification_grants
      ) order by d.local_date)
      from daily_rollup d
    ), '[]'::jsonb)
  from filtered f;
end;
$function$;

revoke all on function public.record_base_customer_catalog_event(uuid, uuid, text, bigint) from public;
grant execute on function public.record_base_customer_catalog_event(uuid, uuid, text, bigint) to anon, authenticated;
revoke all on function public.admin_get_base_customer_catalog_analytics(date, date) from public, anon;
grant execute on function public.admin_get_base_customer_catalog_analytics(date, date) to authenticated;

comment on table public.base_customer_catalog_analytics_events is
  'Anonymous pseudonymous activity events for the general customer catalog. Stores no IP address or direct visitor identifiers.';
comment on function public.admin_get_base_customer_catalog_analytics(date, date) is
  'Returns aggregate general-catalog activity metrics to administrators only.';

