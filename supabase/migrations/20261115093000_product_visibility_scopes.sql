-- Product visibility can be restricted in the staff catalog while remaining
-- available in the general customer catalog. Personal customer catalogs can
-- optionally omit products reserved for the general catalog.
alter table public.products
  add column if not exists seller_visibility text not null default 'all'
    check (seller_visibility in ('all', 'privileged')),
  add column if not exists customer_catalog_scope text not null default 'all'
    check (customer_catalog_scope in ('all', 'general_only'));

alter table public.staff_custom_roles
  add column if not exists can_view_restricted_products boolean not null default false;

create or replace function ev_internal.can_view_restricted_products()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.admin_profiles ap
    join public.staff_custom_roles r on r.id = ap.custom_role_id
    where ap.user_id = auth.uid()
      and ap.role = 'custom'
      and r.can_view_restricted_products = true
      and (
        exists (select 1 from public.seller_profiles sp where sp.user_id = ap.user_id and sp.active = true)
        or exists (select 1 from public.stock_profiles st where st.user_id = ap.user_id and st.active = true)
      )
  );
$$;
revoke all on function ev_internal.can_view_restricted_products() from public, anon;
grant usage on schema ev_internal to authenticated;
grant execute on function ev_internal.can_view_restricted_products() to authenticated;

create or replace function public.get_my_restricted_product_permission()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select ev_internal.can_view_restricted_products();
$$;
revoke all on function public.get_my_restricted_product_permission() from public, anon;
grant execute on function public.get_my_restricted_product_permission() to authenticated;

-- Anonymous visitors power the public customer catalog. Authenticated staff
-- receive only ordinary products unless their role has the explicit privilege.
drop policy if exists "catalogo publico puede leer productos activos" on public.products;
create policy "Public customer catalog reads active products"
  on public.products for select to anon
  using (active = true);

drop policy if exists "Staff view products allowed by role" on public.products;
create policy "Staff view products allowed by role"
  on public.products for select to authenticated
  using (
    active = true
    and (
      coalesce(seller_visibility, 'all') = 'all'
      or ev_internal.can_view_restricted_products()
    )
  );

create or replace function public.admin_update_staff_role_permissions_with_product_visibility(
  p_role_id uuid,
  p_can_view_assigned_sellers boolean,
  p_can_manage_deposito_stock boolean,
  p_can_manage_local_stock boolean,
  p_can_view_restricted_products boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede modificar permisos de roles'
      using errcode = '42501';
  end if;

  update public.staff_custom_roles
  set can_view_assigned_sellers = coalesce(p_can_view_assigned_sellers, false),
      can_manage_deposito_stock = coalesce(p_can_manage_deposito_stock, false),
      can_manage_local_stock = coalesce(p_can_manage_local_stock, false),
      can_view_restricted_products = coalesce(p_can_view_restricted_products, false)
  where id = p_role_id;

  if not found then
    raise exception 'No se encontró el rol personalizado' using errcode = 'P0002';
  end if;
end;
$$;
revoke all on function public.admin_update_staff_role_permissions_with_product_visibility(uuid, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.admin_update_staff_role_permissions_with_product_visibility(uuid, boolean, boolean, boolean, boolean) to authenticated;

create or replace function public.admin_list_staff_roles_with_product_visibility()
returns table(
  id uuid,
  name text,
  can_view_assigned_sellers boolean,
  can_manage_deposito_stock boolean,
  can_manage_local_stock boolean,
  can_view_restricted_products boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo el administrador puede consultar roles' using errcode = '42501';
  end if;

  return query
  select r.id, r.name, r.can_view_assigned_sellers,
         r.can_manage_deposito_stock, r.can_manage_local_stock,
         r.can_view_restricted_products
  from public.staff_custom_roles r
  order by lower(r.name);
end;
$$;
revoke all on function public.admin_list_staff_roles_with_product_visibility() from public, anon;
grant execute on function public.admin_list_staff_roles_with_product_visibility() to authenticated;

notify pgrst, 'reload schema';
