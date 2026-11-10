create table if not exists public.catalog_staff_daily_activity (
  user_id uuid not null references auth.users(id) on delete cascade,
  activity_date date not null,
  first_session_at timestamptz not null,
  last_session_at timestamptz not null,
  duration_seconds integer not null default 0 check (duration_seconds >= 0),
  whatsapp_share_count integer not null default 0 check (whatsapp_share_count >= 0),
  primary key (user_id, activity_date)
);
alter table public.catalog_staff_daily_activity enable row level security;
revoke all on public.catalog_staff_daily_activity from public, anon, authenticated;

create or replace function ev_internal.record_catalog_staff_duration(p_user_id uuid, p_from timestamptz, p_to timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_cursor timestamptz := p_from;
  v_boundary timestamptz;
  v_date date;
  v_seconds integer;
begin
  if p_user_id is null or p_from is null or p_to <= p_from then return; end if;
  while v_cursor < p_to loop
    v_date := (v_cursor at time zone 'America/Argentina/Buenos_Aires')::date;
    v_boundary := ((v_date + 1)::timestamp at time zone 'America/Argentina/Buenos_Aires');
    v_seconds := greatest(0, floor(extract(epoch from (least(p_to, v_boundary) - v_cursor)))::integer);
    if v_seconds > 0 then
      insert into public.catalog_staff_daily_activity(user_id, activity_date, first_session_at, last_session_at, duration_seconds)
      values (p_user_id, v_date, p_from, p_to, v_seconds)
      on conflict (user_id, activity_date) do update set
        first_session_at = least(catalog_staff_daily_activity.first_session_at, excluded.first_session_at),
        last_session_at = greatest(catalog_staff_daily_activity.last_session_at, excluded.last_session_at),
        duration_seconds = catalog_staff_daily_activity.duration_seconds + excluded.duration_seconds;
    end if;
    v_cursor := least(p_to, v_boundary);
  end loop;
end;
$$;
revoke all on function ev_internal.record_catalog_staff_duration(uuid, timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.start_catalog_staff_session(p_session_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.can_access_catalog_presence() then
    raise exception 'Esta cuenta no puede registrar actividad del catálogo' using errcode = '42501';
  end if;
  if p_session_id is null then raise exception 'Falta el identificador de sesión'; end if;
  insert into public.catalog_staff_sessions(session_id, user_id) values (p_session_id, auth.uid()) on conflict (session_id) do nothing;
  if not exists (select 1 from public.catalog_staff_sessions where session_id = p_session_id and user_id = auth.uid()) then
    raise exception 'La sesión pertenece a otro usuario' using errcode = '42501';
  end if;
  insert into public.catalog_staff_daily_activity(user_id, activity_date, first_session_at, last_session_at)
  values (auth.uid(), (now() at time zone 'America/Argentina/Buenos_Aires')::date, now(), now())
  on conflict (user_id, activity_date) do update set
    first_session_at = least(catalog_staff_daily_activity.first_session_at, excluded.first_session_at),
    last_session_at = greatest(catalog_staff_daily_activity.last_session_at, excluded.last_session_at);
end;
$$;

create or replace function public.heartbeat_catalog_staff_session(p_session_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_session public.catalog_staff_sessions%rowtype; v_now timestamptz := now(); v_from timestamptz; v_seconds integer;
begin
  if auth.uid() is null or not public.can_access_catalog_presence() then raise exception 'Esta cuenta no puede registrar actividad del catálogo' using errcode = '42501'; end if;
  select * into v_session from public.catalog_staff_sessions where session_id=p_session_id and user_id=auth.uid() and ended_at is null for update;
  if not found then return; end if;
  v_from := v_session.last_seen_at;
  v_seconds := greatest(0, floor(extract(epoch from (least(v_now, v_from + interval '90 seconds') - v_from)))::integer);
  perform ev_internal.record_catalog_staff_duration(auth.uid(), v_from, least(v_now, v_from + interval '90 seconds'));
  update public.catalog_staff_sessions set last_seen_at=v_now, duration_seconds=duration_seconds+v_seconds where session_id=p_session_id;
  update public.catalog_staff_daily_activity set last_session_at=greatest(last_session_at,v_now)
  where user_id=auth.uid() and activity_date=(v_now at time zone 'America/Argentina/Buenos_Aires')::date;
end;
$$;

create or replace function public.end_catalog_staff_session(p_session_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_session public.catalog_staff_sessions%rowtype; v_now timestamptz := now(); v_to timestamptz; v_seconds integer;
begin
  if auth.uid() is null then return; end if;
  select * into v_session from public.catalog_staff_sessions where session_id=p_session_id and user_id=auth.uid() and ended_at is null for update;
  if not found then return; end if;
  v_to := least(v_now, v_session.last_seen_at + interval '90 seconds');
  v_seconds := greatest(0, floor(extract(epoch from (v_to-v_session.last_seen_at)))::integer);
  perform ev_internal.record_catalog_staff_duration(auth.uid(),v_session.last_seen_at,v_to);
  update public.catalog_staff_sessions set last_seen_at=v_now, ended_at=v_now, duration_seconds=duration_seconds+v_seconds where session_id=p_session_id;
  update public.catalog_staff_daily_activity set last_session_at=greatest(last_session_at,v_now)
  where user_id=auth.uid() and activity_date=(v_now at time zone 'America/Argentina/Buenos_Aires')::date;
end;
$$;

create or replace function public.record_catalog_whatsapp_share(p_session_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.can_access_catalog_presence() then raise exception 'Esta cuenta no puede registrar actividad del catálogo' using errcode = '42501'; end if;
  if not exists (select 1 from public.catalog_staff_sessions where session_id=p_session_id and user_id=auth.uid() and ended_at is null) then
    raise exception 'La sesión activa no pertenece a esta cuenta' using errcode = '42501';
  end if;
  insert into public.catalog_staff_daily_activity(user_id,activity_date,first_session_at,last_session_at,whatsapp_share_count)
  values(auth.uid(),(now() at time zone 'America/Argentina/Buenos_Aires')::date,now(),now(),1)
  on conflict(user_id,activity_date) do update set
    last_session_at=greatest(catalog_staff_daily_activity.last_session_at,excluded.last_session_at),
    whatsapp_share_count=catalog_staff_daily_activity.whatsapp_share_count+1;
end;
$$;

create or replace function public.admin_list_catalog_staff_daily_activity(p_limit integer default 2000)
returns table(user_id uuid,display_name text,role_label text,activity_date date,first_session_at timestamptz,last_session_at timestamptz,duration_seconds integer,whatsapp_share_count integer,is_online boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.admin_profiles where user_id=auth.uid() and role='admin') then raise exception 'Solo el administrador puede ver toda la actividad' using errcode='42501'; end if;
  update public.catalog_staff_sessions set ended_at=last_seen_at+interval '60 seconds'
  where ended_at is null and last_seen_at < now()-interval '3 minutes';
  return query select d.user_id,
    coalesce(nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='admin' then 'Admin' when ap.role='supervisor' then 'Supervisor' when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado') when sp.user_id is not null then 'Vendedor' when st.location='local' then 'Local' when st.location='deposito' then 'Logística' else 'Usuario' end::text,
    d.activity_date,d.first_session_at,d.last_session_at,d.duration_seconds,d.whatsapp_share_count,
    exists(select 1 from public.catalog_staff_sessions s where s.user_id=d.user_id and s.ended_at is null and s.last_seen_at>=now()-interval '3 minutes')
  from public.catalog_staff_daily_activity d left join public.seller_profiles sp on sp.user_id=d.user_id left join public.admin_profiles ap on ap.user_id=d.user_id left join public.staff_custom_roles cr on cr.id=ap.custom_role_id left join public.stock_profiles st on st.user_id=d.user_id
  order by d.activity_date desc,d.last_session_at desc limit greatest(1,least(coalesce(p_limit,2000),5000));
end;
$$;

create or replace function public.supervisor_list_assigned_catalog_daily_activity(p_limit integer default 500)
returns table(user_id uuid,display_name text,role_label text,activity_date date,first_session_at timestamptz,last_session_at timestamptz,duration_seconds integer,whatsapp_share_count integer,is_online boolean)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.admin_profiles where user_id=auth.uid() and role='supervisor') or not ev_internal.staff_sales_is_verified(auth.uid()) then raise exception 'Solo supervisores verificados pueden consultar la actividad de sus vendedores' using errcode='42501'; end if;
  update public.catalog_staff_sessions s set ended_at=s.last_seen_at+interval '60 seconds'
  where s.ended_at is null and s.last_seen_at<now()-interval '3 minutes' and exists(select 1 from public.supervisor_sellers ss where ss.supervisor_id=auth.uid() and ss.seller_id=s.user_id);
  return query select d.user_id,
    coalesce(nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='supervisor' then 'Supervisor' when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado') when sp.user_id is not null then 'Vendedor' when st.location='local' then 'Local' when st.location='deposito' then 'Logística' else 'Usuario' end::text,
    d.activity_date,d.first_session_at,d.last_session_at,d.duration_seconds,d.whatsapp_share_count,
    exists(select 1 from public.catalog_staff_sessions s where s.user_id=d.user_id and s.ended_at is null and s.last_seen_at>=now()-interval '3 minutes')
  from public.catalog_staff_daily_activity d join public.supervisor_sellers ss on ss.seller_id=d.user_id and ss.supervisor_id=auth.uid() left join public.seller_profiles sp on sp.user_id=d.user_id left join public.admin_profiles ap on ap.user_id=d.user_id left join public.staff_custom_roles cr on cr.id=ap.custom_role_id left join public.stock_profiles st on st.user_id=d.user_id
  order by d.activity_date desc,d.last_session_at desc limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;

revoke all on function public.record_catalog_whatsapp_share(uuid) from public,anon;
revoke all on function public.admin_list_catalog_staff_daily_activity(integer) from public,anon;
revoke all on function public.supervisor_list_assigned_catalog_daily_activity(integer) from public,anon;
grant execute on function public.record_catalog_whatsapp_share(uuid) to authenticated;
grant execute on function public.admin_list_catalog_staff_daily_activity(integer) to authenticated;
grant execute on function public.supervisor_list_assigned_catalog_daily_activity(integer) to authenticated;
notify pgrst,'reload schema';
