create or replace function public.supervisor_list_assigned_catalog_current_daily_activity(p_limit integer default 2000)
returns table(
  user_id uuid,
  display_name text,
  role_label text,
  activity_date date,
  first_session_at timestamptz,
  last_session_at timestamptz,
  duration_seconds integer,
  whatsapp_share_count integer,
  session_count bigint,
  is_online boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_today date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
    or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo supervisores verificados pueden consultar la actividad de sus vendedores' using errcode = '42501';
  end if;

  update public.catalog_staff_sessions s
  set ended_at = s.last_seen_at + interval '60 seconds'
  where s.ended_at is null and s.last_seen_at < now() - interval '3 minutes'
    and exists(select 1 from public.supervisor_sellers ss where ss.supervisor_id = auth.uid() and ss.seller_id = s.user_id);

  return query
  select d.user_id,
    coalesce(nullif(btrim(sp.name), ''), nullif(btrim(ap.display_name), ''), nullif(btrim(st.name), ''), 'Sin nombre')::text,
    case when ap.role = 'supervisor' then 'Supervisor'
      when ap.role = 'custom' then coalesce(nullif(btrim(cr.name), ''), 'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location = 'local' then 'Local'
      when st.location = 'deposito' then 'Logística'
      else 'Usuario' end::text,
    d.activity_date,d.first_session_at,d.last_session_at,d.duration_seconds,d.whatsapp_share_count,
    (select count(*)::bigint from public.catalog_staff_sessions s
      where s.user_id = d.user_id and (s.started_at at time zone 'America/Argentina/Buenos_Aires')::date = d.activity_date),
    exists(select 1 from public.catalog_staff_sessions s where s.user_id = d.user_id and s.ended_at is null
      and s.last_seen_at >= now() - interval '3 minutes' and d.activity_date = v_today)
  from public.catalog_staff_daily_activity d
  join public.supervisor_sellers ss on ss.seller_id = d.user_id and ss.supervisor_id = auth.uid()
  left join public.seller_profiles sp on sp.user_id = d.user_id
  left join public.admin_profiles ap on ap.user_id = d.user_id
  left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
  left join public.stock_profiles st on st.user_id = d.user_id
  where d.activity_date = v_today
  order by d.last_session_at desc
  limit greatest(1,least(coalesce(p_limit,2000),5000));
end;
$function$;

create or replace function public.supervisor_get_assigned_catalog_activity_profile(p_user_id uuid, p_limit integer default 2000)
returns table(
  user_id uuid,
  display_name text,
  role_label text,
  activity_date date,
  first_session_at timestamptz,
  last_session_at timestamptz,
  duration_seconds integer,
  whatsapp_share_count integer,
  session_count bigint,
  is_online boolean
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
    or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo supervisores verificados pueden abrir el historial de actividad' using errcode = '42501';
  end if;
  if p_user_id is null or not exists(
    select 1 from public.supervisor_sellers ss where ss.supervisor_id = auth.uid() and ss.seller_id = p_user_id
  ) then
    raise exception 'Solo podés consultar la actividad de vendedores asignados a tu equipo' using errcode = '42501';
  end if;

  return query
  select d.user_id,
    coalesce(nullif(btrim(sp.name), ''), nullif(btrim(ap.display_name), ''), nullif(btrim(st.name), ''), 'Sin nombre')::text,
    case when ap.role = 'supervisor' then 'Supervisor'
      when ap.role = 'custom' then coalesce(nullif(btrim(cr.name), ''), 'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location = 'local' then 'Local'
      when st.location = 'deposito' then 'Logística'
      else 'Usuario' end::text,
    d.activity_date,d.first_session_at,d.last_session_at,d.duration_seconds,d.whatsapp_share_count,
    (select count(*)::bigint from public.catalog_staff_sessions s
      where s.user_id = d.user_id and (s.started_at at time zone 'America/Argentina/Buenos_Aires')::date = d.activity_date),
    exists(select 1 from public.catalog_staff_sessions s where s.user_id = d.user_id and s.ended_at is null
      and s.last_seen_at >= now() - interval '3 minutes'
      and d.activity_date = (now() at time zone 'America/Argentina/Buenos_Aires')::date)
  from public.catalog_staff_daily_activity d
  left join public.seller_profiles sp on sp.user_id = d.user_id
  left join public.admin_profiles ap on ap.user_id = d.user_id
  left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
  left join public.stock_profiles st on st.user_id = d.user_id
  where d.user_id = p_user_id
  order by d.activity_date desc
  limit greatest(1,least(coalesce(p_limit,2000),10000));
end;
$function$;

revoke all on function public.supervisor_list_assigned_catalog_current_daily_activity(integer) from public,anon;
grant execute on function public.supervisor_list_assigned_catalog_current_daily_activity(integer) to authenticated;
revoke all on function public.supervisor_get_assigned_catalog_activity_profile(uuid,integer) from public,anon;
grant execute on function public.supervisor_get_assigned_catalog_activity_profile(uuid,integer) to authenticated;

comment on function public.supervisor_list_assigned_catalog_current_daily_activity(integer) is
  'One current-day activity aggregate per assigned user, visible only to the verified supervisor who owns the assignment.';
comment on function public.supervisor_get_assigned_catalog_activity_profile(uuid,integer) is
  'Daily activity history for one assigned user, visible only to the verified supervisor who owns the assignment.';
notify pgrst, 'reload schema';
