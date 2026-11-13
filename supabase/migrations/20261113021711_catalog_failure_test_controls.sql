-- Solo las cuentas de vendedor que administración marque expresamente como
-- cuentas de prueba pueden recibir fallas simuladas del catálogo.
create table if not exists public.catalog_failure_test_accounts (
  user_id uuid primary key references public.seller_profiles(user_id) on delete cascade,
  app_close boolean not null default false,
  load_delay_ms integer not null default 0
    check (load_delay_ms between 0 and 30000),
  share_mode text not null default 'none'
    check (share_mode in ('none', 'text_only', 'image_without_prices', 'nothing')),
  enabled boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.catalog_failure_test_accounts enable row level security;
revoke all on public.catalog_failure_test_accounts from anon, authenticated;

create or replace function public.admin_set_catalog_failure_test_account(
  p_user_id uuid,
  p_enabled boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede administrar las cuentas de prueba.' using errcode = '42501';
  end if;

  if p_enabled then
    if not exists (
      select 1 from public.seller_profiles sp
      where sp.user_id = p_user_id and sp.active = true
    ) then
      raise exception 'Solo se pueden marcar cuentas activas del catálogo de vendedores.' using errcode = '22023';
    end if;

    insert into public.catalog_failure_test_accounts(user_id, created_by, updated_by)
    values (p_user_id, auth.uid(), auth.uid())
    on conflict (user_id) do update
      set enabled = true, updated_by = auth.uid(), updated_at = now();
  else
    delete from public.catalog_failure_test_accounts where user_id = p_user_id;
  end if;
  return true;
end;
$function$;
revoke all on function public.admin_set_catalog_failure_test_account(uuid, boolean) from public, anon;
grant execute on function public.admin_set_catalog_failure_test_account(uuid, boolean) to authenticated;

create or replace function public.admin_set_catalog_failure_test_scenario(
  p_user_id uuid,
  p_app_close boolean,
  p_load_delay_ms integer,
  p_share_mode text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede configurar las fallas de prueba.' using errcode = '42501';
  end if;
  if p_load_delay_ms is null or p_load_delay_ms not between 0 and 30000 then
    raise exception 'El retraso debe ser de 0 a 30.000 milisegundos.' using errcode = '22023';
  end if;
  if p_share_mode is null or p_share_mode not in ('none', 'text_only', 'image_without_prices', 'nothing') then
    raise exception 'El tipo de falla al compartir no es válido.' using errcode = '22023';
  end if;

  update public.catalog_failure_test_accounts
  set app_close = coalesce(p_app_close, false),
      load_delay_ms = p_load_delay_ms,
      share_mode = p_share_mode,
      enabled = true,
      updated_by = auth.uid(),
      updated_at = now()
  where user_id = p_user_id;
  if not found then
    raise exception 'La persona no está marcada como cuenta de prueba.' using errcode = 'P0002';
  end if;
  return true;
end;
$function$;
revoke all on function public.admin_set_catalog_failure_test_scenario(uuid, boolean, integer, text) from public, anon;
grant execute on function public.admin_set_catalog_failure_test_scenario(uuid, boolean, integer, text) to authenticated;

create or replace function public.admin_list_catalog_failure_test_accounts()
returns table(
  user_id uuid,
  display_name text,
  phone text,
  app_close boolean,
  load_delay_ms integer,
  share_mode text,
  enabled boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede ver las cuentas de prueba.' using errcode = '42501';
  end if;

  return query
  select t.user_id,
    coalesce(nullif(btrim(sp.name), ''), 'Vendedor')::text,
    coalesce(sp.phone, '')::text,
    t.app_close, t.load_delay_ms, t.share_mode, t.enabled, t.created_at, t.updated_at
  from public.catalog_failure_test_accounts t
  join public.seller_profiles sp on sp.user_id = t.user_id
  order by sp.name collate "C", t.created_at;
end;
$function$;
revoke all on function public.admin_list_catalog_failure_test_accounts() from public, anon;
grant execute on function public.admin_list_catalog_failure_test_accounts() to authenticated;

create or replace function public.get_my_catalog_failure_test_scenario()
returns table(app_close boolean, load_delay_ms integer, share_mode text)
language sql
stable
security definer
set search_path = ''
as $function$
  select t.app_close, t.load_delay_ms, t.share_mode
  from public.catalog_failure_test_accounts t
  join public.seller_profiles sp on sp.user_id = t.user_id and sp.active = true
  where t.user_id = (select auth.uid()) and t.enabled = true;
$function$;
revoke all on function public.get_my_catalog_failure_test_scenario() from public, anon;
grant execute on function public.get_my_catalog_failure_test_scenario() to authenticated;

comment on table public.catalog_failure_test_accounts is
  'Cuentas de vendedor seleccionadas por administración para simular fallas controladas. No aplica a otros perfiles ni modifica ventas o stock.';
