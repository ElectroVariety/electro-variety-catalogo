create or replace function public.supervisor_get_assigned_customer_catalog_analytics(
  p_owner_id uuid,
  p_from date default null,
  p_to date default null
)
returns table(
  owner_id uuid,
  has_link boolean,
  period_from date,
  period_to date,
  visits bigint,
  unique_visitors bigint,
  installs bigint,
  notification_grants bigint,
  notification_denials bigint,
  push_subscriptions bigint,
  product_consults bigint,
  delivery_consults bigint,
  top_products jsonb,
  daily_activity jsonb
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
  if not exists(select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
    or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo supervisores verificados pueden ver estas estadísticas' using errcode = '42501';
  end if;
  if p_owner_id is null or not exists(
    select 1 from public.supervisor_sellers ss where ss.supervisor_id = auth.uid() and ss.seller_id = p_owner_id
  ) then
    raise exception 'Solo podés consultar estadísticas de vendedores asignados a tu equipo' using errcode = '42501';
  end if;
  if v_from > v_to or v_to - v_from > 365 then
    raise exception 'El período debe ser válido y no superar 366 días';
  end if;

  v_start := v_from::timestamp at time zone 'America/Argentina/Buenos_Aires';
  v_end := (v_to + 1)::timestamp at time zone 'America/Argentina/Buenos_Aires';

  return query
  with events as (
    select e.owner_id,e.visitor_id,e.event_type,e.product_id,
      (e.created_at at time zone 'America/Argentina/Buenos_Aires')::date as activity_date
    from public.customer_catalog_analytics_events e
    where e.owner_id = p_owner_id and e.created_at >= v_start and e.created_at < v_end
  ),
  product_counts as (
    select e.product_id,coalesce(max(p.name),'Producto #' || e.product_id::text)::text as product_name,count(*)::bigint as consults
    from events e left join public.products p on p.id = e.product_id
    where e.event_type = 'product_consult'
    group by e.product_id
  ),
  daily_counts as (
    select e.activity_date,
      count(*) filter(where e.event_type = 'visit')::bigint as visits,
      count(distinct e.visitor_id) filter(where e.event_type = 'visit')::bigint as unique_visitors,
      count(*) filter(where e.event_type = 'install')::bigint as installs,
      count(*) filter(where e.event_type = 'notification_granted')::bigint as notification_grants,
      count(*) filter(where e.event_type = 'notification_denied')::bigint as notification_denials,
      count(*) filter(where e.event_type = 'push_subscribed')::bigint as push_subscriptions,
      count(*) filter(where e.event_type = 'product_consult')::bigint as product_consults,
      count(*) filter(where e.event_type = 'delivery_consult')::bigint as delivery_consults
    from events e group by e.activity_date
  )
  select p_owner_id,
    exists(select 1 from public.customer_sale_referral_links l where l.owner_id = p_owner_id),
    v_from,v_to,
    count(*) filter(where e.event_type = 'visit')::bigint,
    count(distinct e.visitor_id) filter(where e.event_type = 'visit')::bigint,
    count(*) filter(where e.event_type = 'install')::bigint,
    count(*) filter(where e.event_type = 'notification_granted')::bigint,
    count(*) filter(where e.event_type = 'notification_denied')::bigint,
    count(*) filter(where e.event_type = 'push_subscribed')::bigint,
    count(*) filter(where e.event_type = 'product_consult')::bigint,
    count(*) filter(where e.event_type = 'delivery_consult')::bigint,
    coalesce((select jsonb_agg(jsonb_build_object('product_id',ranked.product_id,'name',ranked.product_name,'consults',ranked.consults)
      order by ranked.consults desc,ranked.product_name) from (select pc.*,row_number() over(order by pc.consults desc,pc.product_name) as position from product_counts pc) ranked where ranked.position <= 5),'[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('date',dc.activity_date,'visits',dc.visits,'unique_visitors',dc.unique_visitors,
      'installs',dc.installs,'notification_grants',dc.notification_grants,'notification_denials',dc.notification_denials,
      'push_subscriptions',dc.push_subscriptions,'product_consults',dc.product_consults,'delivery_consults',dc.delivery_consults)
      order by dc.activity_date desc) from daily_counts dc),'[]'::jsonb)
  from events e;
end;
$function$;

revoke all on function public.supervisor_get_assigned_customer_catalog_analytics(uuid,date,date) from public,anon;
grant execute on function public.supervisor_get_assigned_customer_catalog_analytics(uuid,date,date) to authenticated;
comment on function public.supervisor_get_assigned_customer_catalog_analytics(uuid,date,date) is
  'Customer-link analytics for one assigned seller and date range; only that seller’s verified supervisor may read it.';
notify pgrst, 'reload schema';
