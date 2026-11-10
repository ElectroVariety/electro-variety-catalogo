drop function public.get_catalog_staff_directory();

create function public.get_catalog_staff_directory()
returns table(user_id uuid, display_name text, role_label text, supervisor_ids uuid[], is_verified boolean)
language plpgsql
stable
security definer
set search_path = ''
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
  select ids.user_id,
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
    ),
    coalesce(v.is_verified, false)
  from staff_ids ids
  left join public.seller_profiles s on s.user_id = ids.user_id
  left join public.stock_profiles st on st.user_id = ids.user_id and st.active = true
  left join public.admin_profiles a on a.user_id = ids.user_id
  left join public.staff_custom_roles r on r.id = a.custom_role_id
  left join public.staff_sales_verifications v on v.user_id = ids.user_id
  order by 3, 2;
end;
$$;

revoke all on function public.get_catalog_staff_directory() from public, anon;
grant execute on function public.get_catalog_staff_directory() to authenticated;
notify pgrst, 'reload schema';
