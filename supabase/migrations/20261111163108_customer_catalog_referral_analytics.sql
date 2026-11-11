create table if not exists public.customer_catalog_analytics_events (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  visitor_id uuid not null,
  session_id uuid not null,
  event_type text not null check (event_type in (
    'visit',
    'product_consult',
    'delivery_consult',
    'install',
    'notification_granted',
    'notification_denied',
    'push_subscribed'
  )),
  product_id bigint,
  created_at timestamptz not null default now(),
  constraint customer_catalog_analytics_product_event_check check (
    (event_type = 'product_consult' and product_id is not null)
    or (event_type <> 'product_consult' and product_id is null)
  )
);

create index if not exists customer_catalog_analytics_owner_created_idx
  on public.customer_catalog_analytics_events(owner_id, created_at desc);
create index if not exists customer_catalog_analytics_owner_event_created_idx
  on public.customer_catalog_analytics_events(owner_id, event_type, created_at desc);
create index if not exists customer_catalog_analytics_owner_product_idx
  on public.customer_catalog_analytics_events(owner_id, product_id, created_at desc)
  where event_type = 'product_consult';
create unique index if not exists customer_catalog_analytics_visit_session_idx
  on public.customer_catalog_analytics_events(owner_id, session_id)
  where event_type = 'visit';
create unique index if not exists customer_catalog_analytics_one_install_idx
  on public.customer_catalog_analytics_events(owner_id, visitor_id)
  where event_type = 'install';
create unique index if not exists customer_catalog_analytics_one_notification_grant_idx
  on public.customer_catalog_analytics_events(owner_id, visitor_id)
  where event_type = 'notification_granted';
create unique index if not exists customer_catalog_analytics_one_notification_denial_idx
  on public.customer_catalog_analytics_events(owner_id, visitor_id)
  where event_type = 'notification_denied';
create unique index if not exists customer_catalog_analytics_one_push_subscription_idx
  on public.customer_catalog_analytics_events(owner_id, visitor_id)
  where event_type = 'push_subscribed';

alter table public.customer_catalog_analytics_events enable row level security;
revoke all on public.customer_catalog_analytics_events from public, anon, authenticated;

create or replace function public.record_customer_catalog_analytics_event(
  p_token uuid,
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
declare
  v_owner_id uuid;
begin
  if p_token is null or p_visitor_id is null or p_session_id is null or p_event_type is null then
    return false;
  end if;

  if p_event_type not in (
    'visit', 'product_consult', 'delivery_consult', 'install',
    'notification_granted', 'notification_denied', 'push_subscribed'
  ) then
    return false;
  end if;

  if (p_event_type = 'product_consult') <> (p_product_id is not null) then
    return false;
  end if;

  select l.owner_id into v_owner_id
  from public.customer_sale_referral_links l
  join public.staff_sales_verifications verification
    on verification.user_id = l.owner_id and verification.is_verified = true
  where l.token = p_token and l.expires_at > now()
  limit 1;

  if v_owner_id is null then
    return false;
  end if;

  if p_event_type = 'product_consult' and not exists (
    select 1 from public.products p where p.id = p_product_id and p.active = true
  ) then
    return false;
  end if;

  -- Bound high-frequency anonymous event spam per link and visitor.
  if p_event_type in ('product_consult', 'delivery_consult') and (
    select count(*) from public.customer_catalog_analytics_events e
    where e.owner_id = v_owner_id
      and e.visitor_id = p_visitor_id
      and e.event_type = p_event_type
      and e.created_at >= now() - interval '1 hour'
  ) >= 120 then
    return false;
  end if;

  insert into public.customer_catalog_analytics_events(
    owner_id, visitor_id, session_id, event_type, product_id
  ) values (
    v_owner_id, p_visitor_id, p_session_id, p_event_type, p_product_id
  ) on conflict do nothing;

  return found;
end;
$function$;

create or replace function public.admin_list_customer_catalog_analytics(
  p_from date default null,
  p_to date default null,
  p_owner_id uuid default null
)
returns table(
  owner_id uuid,
  display_name text,
  role_label text,
  visits bigint,
  unique_visitors bigint,
  installs bigint,
  notification_grants bigint,
  notification_denials bigint,
  push_subscriptions bigint,
  product_consults bigint,
  delivery_consults bigint,
  top_products jsonb
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
    raise exception 'El período debe ser válido y no superar 366 días';
  end if;

  v_start := v_from::timestamp at time zone 'America/Argentina/Buenos_Aires';
  v_end := (v_to + 1)::timestamp at time zone 'America/Argentina/Buenos_Aires';

  return query
  with referral_owners as (
    select distinct l.owner_id
    from public.customer_sale_referral_links l
    where p_owner_id is null or l.owner_id = p_owner_id
  ),
  event_totals as (
    select e.owner_id,
      count(*) filter (where e.event_type = 'visit')::bigint as visits,
      count(distinct e.visitor_id) filter (where e.event_type = 'visit')::bigint as unique_visitors,
      count(*) filter (where e.event_type = 'install')::bigint as installs,
      count(*) filter (where e.event_type = 'notification_granted')::bigint as notification_grants,
      count(*) filter (where e.event_type = 'notification_denied')::bigint as notification_denials,
      count(*) filter (where e.event_type = 'push_subscribed')::bigint as push_subscriptions,
      count(*) filter (where e.event_type = 'product_consult')::bigint as product_consults,
      count(*) filter (where e.event_type = 'delivery_consult')::bigint as delivery_consults
    from public.customer_catalog_analytics_events e
    where e.created_at >= v_start and e.created_at < v_end
      and (p_owner_id is null or e.owner_id = p_owner_id)
    group by e.owner_id
  ),
  products_by_owner as (
    select ranked.owner_id,
      jsonb_agg(jsonb_build_object('product_id', ranked.product_id, 'name', ranked.name, 'consults', ranked.consults)
        order by ranked.consults desc, ranked.name) as top_products
    from (
      select e.owner_id, e.product_id, p.name, count(*)::bigint as consults,
        row_number() over (partition by e.owner_id order by count(*) desc, p.name) as rank
      from public.customer_catalog_analytics_events e
      join public.products p on p.id = e.product_id
      where e.event_type = 'product_consult'
        and e.created_at >= v_start and e.created_at < v_end
        and (p_owner_id is null or e.owner_id = p_owner_id)
      group by e.owner_id, e.product_id, p.name
    ) ranked
    where ranked.rank <= 5
    group by ranked.owner_id
  )
  select ro.owner_id,
    coalesce(nullif(btrim(vp.full_name), ''), nullif(btrim(sp.name), ''), nullif(btrim(ap.display_name), ''), nullif(btrim(st.name), ''), 'Sin nombre')::text,
    case
      when ap.role = 'admin' then 'Admin'
      when ap.role = 'supervisor' then 'Supervisor'
      when ap.role = 'custom' then coalesce(nullif(btrim(cr.name), ''), 'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location = 'local' then 'Local'
      when st.location = 'deposito' then 'Logística'
      else 'Usuario'
    end::text,
    coalesce(et.visits, 0), coalesce(et.unique_visitors, 0), coalesce(et.installs, 0),
    coalesce(et.notification_grants, 0), coalesce(et.notification_denials, 0),
    coalesce(et.push_subscriptions, 0), coalesce(et.product_consults, 0),
    coalesce(et.delivery_consults, 0), coalesce(po.top_products, '[]'::jsonb)
  from referral_owners ro
  left join event_totals et on et.owner_id = ro.owner_id
  left join products_by_owner po on po.owner_id = ro.owner_id
  left join public.verified_staff_profiles vp on vp.user_id = ro.owner_id
  left join public.seller_profiles sp on sp.user_id = ro.owner_id
  left join public.admin_profiles ap on ap.user_id = ro.owner_id
  left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
  left join public.stock_profiles st on st.user_id = ro.owner_id
  order by coalesce(et.visits, 0) desc, 2;
end;
$function$;

revoke all on function public.record_customer_catalog_analytics_event(uuid, uuid, uuid, text, bigint) from public;
grant execute on function public.record_customer_catalog_analytics_event(uuid, uuid, uuid, text, bigint) to anon, authenticated;
revoke all on function public.admin_list_customer_catalog_analytics(date, date, uuid) from public, anon;
grant execute on function public.admin_list_customer_catalog_analytics(date, date, uuid) to authenticated;

comment on table public.customer_catalog_analytics_events is
  'Pseudonymous activity events attributed to verified users customer catalog referral links. No IP address or directly identifying visitor data is stored.';
comment on function public.record_customer_catalog_analytics_event(uuid, uuid, uuid, text, bigint) is
  'Records a limited, pseudonymous event only when its permanent referral token belongs to an actively verified user.';
comment on function public.admin_list_customer_catalog_analytics(date, date, uuid) is
  'Returns customer-catalog referral metrics only to administrator accounts.';
notify pgrst, 'reload schema';
