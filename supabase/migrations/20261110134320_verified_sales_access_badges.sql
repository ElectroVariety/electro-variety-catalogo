create table if not exists public.staff_sales_verifications (
  user_id uuid primary key references auth.users(id) on delete cascade,
  is_verified boolean not null default false,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.staff_sales_verifications enable row level security;
revoke all on public.staff_sales_verifications from anon, authenticated;
grant select on public.staff_sales_verifications to authenticated;
drop policy if exists "Users can read own sales verification" on public.staff_sales_verifications;
create policy "Users can read own sales verification"
  on public.staff_sales_verifications for select to authenticated
  using (user_id = (select auth.uid()));

create or replace function ev_internal.staff_sales_is_verified(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
    and (p_user_id = auth.uid() or exists (
      select 1 from public.admin_profiles ap
      where ap.user_id = auth.uid() and ap.role = 'admin'
    ))
    and coalesce((
      select v.is_verified
      from public.staff_sales_verifications v
      where v.user_id = p_user_id
    ), false);
$$;
revoke all on function ev_internal.staff_sales_is_verified(uuid) from public, anon;
grant execute on function ev_internal.staff_sales_is_verified(uuid) to authenticated;

create or replace function public.admin_list_staff_sales_verifications()
returns table(user_id uuid, display_name text, phone text, role_name text, is_verified boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede administrar las insignias.' using errcode = '42501';
  end if;

  return query
  with staff as (
    select ap.user_id,
      coalesce(nullif(btrim(ap.display_name), ''), nullif(btrim(sp.name), ''), nullif(btrim(st.name), ''), 'Usuario')::text as display_name,
      coalesce(sp.phone, st.phone, '')::text as phone,
      case ap.role
        when 'admin' then 'Admin'
        when 'supervisor' then 'Supervisor'
        when 'custom' then coalesce(cr.name, 'Personalizado')
        else coalesce(nullif(btrim(cr.name), ''), case when sp.user_id is not null then 'Vendedor' when st.user_id is not null then case st.location when 'deposito' then 'Logística' when 'local' then 'Local' else 'Stock' end else 'Usuario' end)
      end::text as role_name,
      (ap.role = 'admin') as is_admin,
      (sp.user_id is not null) as is_seller
    from public.admin_profiles ap
    left join public.seller_profiles sp on sp.user_id = ap.user_id
    left join public.stock_profiles st on st.user_id = ap.user_id
    left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
    union all
    select sp.user_id, coalesce(nullif(btrim(sp.name), ''), 'Vendedor')::text, coalesce(sp.phone, '')::text,
      'Vendedor'::text, false, true
    from public.seller_profiles sp
    where not exists (select 1 from public.admin_profiles ap where ap.user_id = sp.user_id)
    union all
    select st.user_id, coalesce(nullif(btrim(st.name), ''), 'Usuario de stock')::text, coalesce(st.phone, '')::text,
      case st.location when 'deposito' then 'Logística' when 'local' then 'Local' else 'Stock' end::text, false, false
    from public.stock_profiles st
    where not exists (select 1 from public.admin_profiles ap where ap.user_id = st.user_id)
      and not exists (select 1 from public.seller_profiles sp where sp.user_id = st.user_id)
  )
  select s.user_id, s.display_name, s.phone, s.role_name,
    coalesce(v.is_verified, false)
  from staff s
  left join public.staff_sales_verifications v on v.user_id = s.user_id
  order by s.is_admin desc, s.is_seller desc, s.role_name, s.display_name;
end;
$$;
revoke all on function public.admin_list_staff_sales_verifications() from public, anon;
grant execute on function public.admin_list_staff_sales_verifications() to authenticated;

create or replace function public.admin_set_staff_sales_verification(p_user_id uuid, p_is_verified boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede administrar las insignias.' using errcode = '42501';
  end if;
  if p_user_id is null or p_is_verified is null then
    raise exception 'Falta el usuario o el estado de verificación.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.seller_profiles sp where sp.user_id = p_user_id)
    and not exists (select 1 from public.stock_profiles st where st.user_id = p_user_id)
    and not exists (select 1 from public.admin_profiles ap where ap.user_id = p_user_id) then
    raise exception 'El usuario no tiene un perfil de personal válido.' using errcode = '22023';
  end if;
  insert into public.staff_sales_verifications(user_id, is_verified, updated_by, updated_at)
  values (p_user_id, p_is_verified, auth.uid(), now())
  on conflict (user_id) do update
    set is_verified = excluded.is_verified, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;
revoke all on function public.admin_set_staff_sales_verification(uuid, boolean) from public, anon;
grant execute on function public.admin_set_staff_sales_verification(uuid, boolean) to authenticated;

drop policy if exists "Staff can create own customer sale referral links" on public.customer_sale_referral_links;
create policy "Verified staff and admins can create own customer sale referral links"
  on public.customer_sale_referral_links for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and (
      ev_internal.staff_sales_is_verified((select auth.uid()))
      or exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'admin')
    )
  );
drop policy if exists "Staff can read own customer sale referral links" on public.customer_sale_referral_links;
create policy "Verified staff and admins can read own customer sale referral links"
  on public.customer_sale_referral_links for select to authenticated
  using (
    owner_id = (select auth.uid())
    and (
      ev_internal.staff_sales_is_verified((select auth.uid()))
      or exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'admin')
    )
  );

create or replace function ev_internal.can_view_customer_sale_request(p_seller_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and (
    exists (
      select 1 from public.admin_profiles ap
      where ap.user_id = auth.uid() and ap.role = 'admin'
    )
    or (
      p_seller_id is not null
      and p_seller_id = auth.uid()
      and ev_internal.staff_sales_is_verified(auth.uid())
    )
    or (
      p_seller_id is not null
      and ev_internal.staff_sales_is_verified(auth.uid())
      and exists (
        select 1 from public.admin_profiles ap
        left join public.staff_custom_roles cr on cr.id = ap.custom_role_id
        where ap.user_id = auth.uid()
          and (ap.role = 'supervisor' or (ap.role = 'custom' and coalesce(cr.can_view_assigned_sellers, false)))
      )
      and exists (
        select 1 from public.supervisor_sellers ss
        where ss.supervisor_id = auth.uid() and ss.seller_id = p_seller_id
      )
    )
  );
$$;
revoke all on function ev_internal.can_view_customer_sale_request(uuid) from public, anon;
grant execute on function ev_internal.can_view_customer_sale_request(uuid) to authenticated;
comment on function ev_internal.can_view_customer_sale_request(uuid) is
  'Admins have universal access; verified staff can view their own requests, and verified supervisors or roles with assigned-seller access can view requests from assigned sellers.';

notify pgrst, 'reload schema';
