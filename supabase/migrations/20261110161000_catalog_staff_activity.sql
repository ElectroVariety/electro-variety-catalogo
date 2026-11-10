create table if not exists public.catalog_staff_sessions (
  session_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at timestamptz,
  duration_seconds integer not null default 0 check (duration_seconds >= 0),
  created_at timestamptz not null default now()
);

create index if not exists catalog_staff_sessions_user_started_idx
  on public.catalog_staff_sessions (user_id, started_at desc);
create index if not exists catalog_staff_sessions_last_seen_idx
  on public.catalog_staff_sessions (last_seen_at desc) where ended_at is null;

alter table public.catalog_staff_sessions enable row level security;
revoke all on public.catalog_staff_sessions from public, anon, authenticated;

create or replace function public.start_catalog_staff_session(p_session_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null or not public.can_access_catalog_presence() then
    raise exception 'Esta cuenta no puede registrar actividad del catálogo' using errcode = '42501';
  end if;
  if p_session_id is null then raise exception 'Falta el identificador de sesión'; end if;

  insert into public.catalog_staff_sessions(session_id, user_id)
  values (p_session_id, auth.uid()) on conflict (session_id) do nothing;

  if not exists (
    select 1 from public.catalog_staff_sessions
    where session_id = p_session_id and user_id = auth.uid()
  ) then
    raise exception 'La sesión pertenece a otro usuario' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.heartbeat_catalog_staff_session(p_session_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null or not public.can_access_catalog_presence() then
    raise exception 'Esta cuenta no puede registrar actividad del catálogo' using errcode = '42501';
  end if;
  update public.catalog_staff_sessions s
  set last_seen_at = now(),
      duration_seconds = greatest(s.duration_seconds, floor(extract(epoch from (now() - s.started_at)))::integer)
  where s.session_id = p_session_id and s.user_id = auth.uid() and s.ended_at is null;
end;
$$;

create or replace function public.end_catalog_staff_session(p_session_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then return; end if;
  update public.catalog_staff_sessions s
  set last_seen_at = now(), ended_at = now(),
      duration_seconds = greatest(s.duration_seconds, floor(extract(epoch from (now() - s.started_at)))::integer)
  where s.session_id = p_session_id and s.user_id = auth.uid() and s.ended_at is null;
end;
$$;

create or replace function public.admin_list_catalog_staff_activity(p_limit integer default 500)
returns table(
  session_id uuid, user_id uuid, display_name text, role_label text,
  started_at timestamptz, last_seen_at timestamptz, ended_at timestamptz, duration_seconds integer
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_profiles a where a.user_id = auth.uid() and a.role = 'admin') then
    raise exception 'Solo el administrador puede ver toda la actividad' using errcode = '42501';
  end if;

  update public.catalog_staff_sessions s
  set ended_at = s.last_seen_at + interval '60 seconds',
      duration_seconds = greatest(s.duration_seconds, floor(extract(epoch from ((s.last_seen_at + interval '60 seconds') - s.started_at)))::integer)
  where s.ended_at is null and s.last_seen_at < now() - interval '3 minutes';

  return query
  select s.session_id, s.user_id,
    coalesce(nullif(trim(sp.name), ''), nullif(trim(ap.display_name), ''), nullif(trim(st.name), ''), 'Sin nombre')::text,
    case
      when ap.role = 'admin' then 'Admin'
      when ap.role = 'supervisor' then 'Supervisor'
      when ap.role = 'custom' then coalesce(nullif(trim(cr.name), ''), 'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location = 'local' then 'Local'
      when st.location = 'deposito' then 'Logística'
      else 'Usuario'
    end::text,
    s.started_at, s.last_seen_at, s.ended_at,
    greatest(s.duration_seconds, case when s.ended_at is null then floor(extract(epoch from (now() - s.started_at)))::integer else 0 end)
  from public.catalog_staff_sessions s
  left join public.seller_profiles sp on sp.user_id = s.user_id
  left join public.admin_profiles ap on ap.user_id = s.user_id
  left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
  left join public.stock_profiles st on st.user_id = s.user_id
  order by s.started_at desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
end;
$$;

create or replace function public.supervisor_list_assigned_catalog_activity(p_limit integer default 500)
returns table(
  session_id uuid, user_id uuid, display_name text, role_label text,
  started_at timestamptz, last_seen_at timestamptz, ended_at timestamptz, duration_seconds integer
)
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_profiles a where a.user_id = auth.uid() and a.role = 'supervisor') then
    raise exception 'Solo los supervisores pueden consultar la actividad de sus vendedores' using errcode = '42501';
  end if;

  update public.catalog_staff_sessions s
  set ended_at = s.last_seen_at + interval '60 seconds',
      duration_seconds = greatest(s.duration_seconds, floor(extract(epoch from ((s.last_seen_at + interval '60 seconds') - s.started_at)))::integer)
  where s.ended_at is null and s.last_seen_at < now() - interval '3 minutes'
    and exists (select 1 from public.supervisor_sellers ss where ss.supervisor_id = auth.uid() and ss.seller_id = s.user_id);

  return query
  select s.session_id, s.user_id,
    coalesce(nullif(trim(sp.name), ''), nullif(trim(ap.display_name), ''), nullif(trim(st.name), ''), 'Sin nombre')::text,
    case
      when ap.role = 'supervisor' then 'Supervisor'
      when ap.role = 'custom' then coalesce(nullif(trim(cr.name), ''), 'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location = 'local' then 'Local'
      when st.location = 'deposito' then 'Logística'
      else 'Usuario'
    end::text,
    s.started_at, s.last_seen_at, s.ended_at,
    greatest(s.duration_seconds, case when s.ended_at is null then floor(extract(epoch from (now() - s.started_at)))::integer else 0 end)
  from public.catalog_staff_sessions s
  join public.supervisor_sellers ss on ss.seller_id = s.user_id and ss.supervisor_id = auth.uid()
  left join public.seller_profiles sp on sp.user_id = s.user_id
  left join public.admin_profiles ap on ap.user_id = s.user_id
  left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
  left join public.stock_profiles st on st.user_id = s.user_id
  order by s.started_at desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
end;
$$;

revoke all on function public.start_catalog_staff_session(uuid) from public, anon;
revoke all on function public.heartbeat_catalog_staff_session(uuid) from public, anon;
revoke all on function public.end_catalog_staff_session(uuid) from public, anon;
revoke all on function public.admin_list_catalog_staff_activity(integer) from public, anon;
revoke all on function public.supervisor_list_assigned_catalog_activity(integer) from public, anon;
grant execute on function public.start_catalog_staff_session(uuid) to authenticated;
grant execute on function public.heartbeat_catalog_staff_session(uuid) to authenticated;
grant execute on function public.end_catalog_staff_session(uuid) to authenticated;
grant execute on function public.admin_list_catalog_staff_activity(integer) to authenticated;
grant execute on function public.supervisor_list_assigned_catalog_activity(integer) to authenticated;

notify pgrst, 'reload schema';
