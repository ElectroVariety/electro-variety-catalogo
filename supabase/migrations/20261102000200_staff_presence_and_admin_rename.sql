create or replace function public.admin_update_seller_name(p_user_id uuid, p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '[[:space:]]+', ' ', 'g'), '');
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede cambiar el nombre de un vendedor'
      using errcode = '42501';
  end if;
  if clean_name is null or length(clean_name) > 80 then
    raise exception 'El nombre debe tener entre 1 y 80 caracteres';
  end if;

  update public.seller_profiles set name = clean_name where user_id = p_user_id;
  if not found then
    raise exception 'No se encontró el perfil del vendedor'
      using errcode = 'P0002';
  end if;

  update public.stock_profiles set name = clean_name where user_id = p_user_id;
  update public.admin_profiles set display_name = clean_name where user_id = p_user_id;
  return clean_name;
end;
$$;

revoke all on function public.admin_update_seller_name(uuid, text) from public, anon;
grant execute on function public.admin_update_seller_name(uuid, text) to authenticated;

create or replace function public.can_access_catalog_presence()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    exists (select 1 from public.seller_profiles where user_id = auth.uid() and active = true)
    or exists (select 1 from public.stock_profiles where user_id = auth.uid() and active = true)
    or exists (select 1 from public.admin_profiles where user_id = auth.uid() and role in ('admin', 'supervisor', 'custom'))
  );
$$;

revoke all on function public.can_access_catalog_presence() from public, anon;
grant execute on function public.can_access_catalog_presence() to authenticated;

create or replace function public.get_catalog_staff_directory()
returns table(user_id uuid, display_name text, role_label text, supervisor_ids uuid[])
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.can_access_catalog_presence() then
    raise exception 'Esta cuenta no puede consultar el personal del catálogo'
      using errcode = '42501';
  end if;

  return query
  with staff_ids as (
    select s.user_id from public.seller_profiles s where s.active = true
    union
    select st.user_id from public.stock_profiles st where st.active = true
    union
    select a.user_id from public.admin_profiles a where a.role in ('admin', 'supervisor', 'custom')
  )
  select
    ids.user_id,
    coalesce(nullif(trim(s.name), ''), nullif(trim(a.display_name), ''), nullif(trim(st.name), ''), 'Sin nombre')::text,
    case
      when a.role = 'admin' then coalesce(nullif(trim(r.name), ''), 'Admin')
      when a.role = 'supervisor' then 'Supervisor'
      when a.role = 'custom' then coalesce(nullif(trim(r.name), ''), 'Personalizado')
      when s.user_id is not null then 'Vendedor'
      when st.location = 'local' then 'Local'
      when st.location = 'deposito' then 'Administración'
      else 'Usuario'
    end::text,
    coalesce(
      array(
        select distinct ss.supervisor_id
        from public.supervisor_sellers ss
        where ss.seller_id = ids.user_id
        order by ss.supervisor_id
      ),
      array[]::uuid[]
    )
  from staff_ids ids
  left join public.seller_profiles s on s.user_id = ids.user_id
  left join public.stock_profiles st on st.user_id = ids.user_id and st.active = true
  left join public.admin_profiles a on a.user_id = ids.user_id
  left join public.staff_custom_roles r on r.id = a.custom_role_id
  order by 3, 2;
end;
$$;

revoke all on function public.get_catalog_staff_directory() from public, anon;
grant execute on function public.get_catalog_staff_directory() to authenticated;

drop policy if exists "staff can read seller catalog presence" on realtime.messages;
create policy "staff can read seller catalog presence"
on realtime.messages for select to authenticated
using (
  (select realtime.topic()) = 'electro-variety:seller-catalog:online'
  and extension = 'presence'
  and public.can_access_catalog_presence()
);

drop policy if exists "staff can publish seller catalog presence" on realtime.messages;
create policy "staff can publish seller catalog presence"
on realtime.messages for insert to authenticated
with check (
  (select realtime.topic()) = 'electro-variety:seller-catalog:online'
  and extension = 'presence'
  and public.can_access_catalog_presence()
);

notify pgrst, 'reload schema';
