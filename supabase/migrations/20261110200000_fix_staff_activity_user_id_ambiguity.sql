create or replace function public.admin_list_catalog_staff_daily_activity(p_limit integer default 2000)
returns table(user_id uuid,display_name text,role_label text,activity_date date,first_session_at timestamptz,last_session_at timestamptz,duration_seconds integer,whatsapp_share_count integer,is_online boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then
    raise exception 'Solo el administrador puede ver toda la actividad' using errcode='42501';
  end if;
  update public.catalog_staff_sessions s set ended_at=s.last_seen_at+interval '60 seconds'
  where s.ended_at is null and s.last_seen_at<now()-interval '3 minutes';
  return query
  select d.user_id,
    coalesce(nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='admin' then 'Admin' when ap.role='supervisor' then 'Supervisor'
      when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado')
      when sp.user_id is not null then 'Vendedor' when st.location='local' then 'Local'
      when st.location='deposito' then 'Logística' else 'Usuario' end::text,
    d.activity_date,d.first_session_at,d.last_session_at,d.duration_seconds,d.whatsapp_share_count,
    exists(select 1 from public.catalog_staff_sessions s where s.user_id=d.user_id and s.ended_at is null and s.last_seen_at>=now()-interval '3 minutes')
  from public.catalog_staff_daily_activity d
  left join public.seller_profiles sp on sp.user_id=d.user_id
  left join public.admin_profiles ap on ap.user_id=d.user_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.stock_profiles st on st.user_id=d.user_id
  order by d.activity_date desc,d.last_session_at desc
  limit greatest(1,least(coalesce(p_limit,2000),5000));
end;
$$;

create or replace function public.supervisor_list_assigned_catalog_daily_activity(p_limit integer default 500)
returns table(user_id uuid,display_name text,role_label text,activity_date date,first_session_at timestamptz,last_session_at timestamptz,duration_seconds integer,whatsapp_share_count integer,is_online boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='supervisor')
    or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo supervisores verificados pueden consultar la actividad de sus vendedores' using errcode='42501';
  end if;
  update public.catalog_staff_sessions s set ended_at=s.last_seen_at+interval '60 seconds'
  where s.ended_at is null and s.last_seen_at<now()-interval '3 minutes'
    and exists(select 1 from public.supervisor_sellers x where x.supervisor_id=auth.uid() and x.seller_id=s.user_id);
  return query
  select d.user_id,
    coalesce(nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='supervisor' then 'Supervisor'
      when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado')
      when sp.user_id is not null then 'Vendedor' when st.location='local' then 'Local'
      when st.location='deposito' then 'Logística' else 'Usuario' end::text,
    d.activity_date,d.first_session_at,d.last_session_at,d.duration_seconds,d.whatsapp_share_count,
    exists(select 1 from public.catalog_staff_sessions s where s.user_id=d.user_id and s.ended_at is null and s.last_seen_at>=now()-interval '3 minutes')
  from public.catalog_staff_daily_activity d
  join public.supervisor_sellers ss on ss.seller_id=d.user_id and ss.supervisor_id=auth.uid()
  left join public.seller_profiles sp on sp.user_id=d.user_id
  left join public.admin_profiles ap on ap.user_id=d.user_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.stock_profiles st on st.user_id=d.user_id
  order by d.activity_date desc,d.last_session_at desc
  limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;

notify pgrst,'reload schema';
