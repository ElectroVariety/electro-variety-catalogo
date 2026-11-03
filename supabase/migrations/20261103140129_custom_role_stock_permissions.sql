alter table public.staff_custom_roles
  add column if not exists can_manage_deposito_stock boolean not null default false,
  add column if not exists can_manage_local_stock boolean not null default false;

-- These existing operational roles receive only the stock area that matches their work.
update public.staff_custom_roles
set can_manage_deposito_stock = true
where lower(trim(name)) in ('logistica', 'logística');

update public.staff_custom_roles
set can_manage_local_stock = true
where lower(trim(name)) = 'local';

create or replace function public.has_stock_role_permission(p_location text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
    and p_location in ('deposito', 'local')
    and exists (
      select 1
      from public.admin_profiles ap
      join public.staff_custom_roles r on r.id = ap.custom_role_id
      where ap.user_id = auth.uid()
        and ap.role = 'custom'
        and (
          (p_location = 'deposito' and r.can_manage_deposito_stock)
          or (p_location = 'local' and r.can_manage_local_stock)
        )
        and (
          exists (select 1 from public.seller_profiles s where s.user_id = ap.user_id and s.active = true)
          or exists (select 1 from public.stock_profiles sp where sp.user_id = ap.user_id and sp.active = true)
        )
    );
$$;

revoke all on function public.has_stock_role_permission(text) from public, anon;
grant execute on function public.has_stock_role_permission(text) to authenticated;

create or replace function public.get_my_stock_role_permissions()
returns table(can_manage_deposito_stock boolean, can_manage_local_stock boolean)
language sql
stable
security definer
set search_path = public
as $$
  select public.has_stock_role_permission('deposito'), public.has_stock_role_permission('local')
  where auth.uid() is not null;
$$;

revoke all on function public.get_my_stock_role_permissions() from public, anon;
grant execute on function public.get_my_stock_role_permissions() to authenticated;

create or replace function public.admin_update_staff_role_permissions(
  p_role_id uuid,
  p_can_view_assigned_sellers boolean,
  p_can_manage_deposito_stock boolean,
  p_can_manage_local_stock boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede modificar permisos de roles'
      using errcode = '42501';
  end if;

  update public.staff_custom_roles
  set can_view_assigned_sellers = coalesce(p_can_view_assigned_sellers, false),
      can_manage_deposito_stock = coalesce(p_can_manage_deposito_stock, false),
      can_manage_local_stock = coalesce(p_can_manage_local_stock, false)
  where id = p_role_id;

  if not found then
    raise exception 'No se encontró el rol personalizado'
      using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_update_staff_role_permissions(uuid, boolean, boolean, boolean) from public, anon;
grant execute on function public.admin_update_staff_role_permissions(uuid, boolean, boolean, boolean) to authenticated;

drop function public.admin_list_staff_roles();
create function public.admin_list_staff_roles()
returns table(
  id uuid,
  name text,
  can_view_assigned_sellers boolean,
  can_manage_deposito_stock boolean,
  can_manage_local_stock boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede consultar roles'
      using errcode = '42501';
  end if;

  return query
  select r.id, r.name, r.can_view_assigned_sellers,
         r.can_manage_deposito_stock, r.can_manage_local_stock
  from public.staff_custom_roles r
  order by lower(r.name);
end;
$$;

revoke all on function public.admin_list_staff_roles() from public, anon;
grant execute on function public.admin_list_staff_roles() to authenticated;

drop policy if exists "Custom roles view permitted stock inventory" on public.stock_inventory;
create policy "Custom roles view permitted stock inventory"
on public.stock_inventory for select to authenticated
using (public.has_stock_role_permission(location));

drop policy if exists "Custom roles create permitted stock requests" on public.stock_requests;
create policy "Custom roles create permitted stock requests"
on public.stock_requests for insert to authenticated
with check (
  requested_by = (select auth.uid())
  and public.has_stock_role_permission(location)
);

notify pgrst, 'reload schema';
