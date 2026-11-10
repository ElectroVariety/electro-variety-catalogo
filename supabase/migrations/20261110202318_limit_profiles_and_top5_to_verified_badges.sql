create or replace function public.get_catalog_staff_profile(p_user_id uuid)
returns table(
  user_id uuid,display_name text,role_label text,is_verified boolean,photo_path text,
  existing_customer_sales integer,new_customer_sales integer,total_customer_sales integer,
  top_locality text,top_product text,top_product_units bigint
)
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo usuarios con insignia pueden consultar perfiles del catálogo' using errcode='42501';
  end if;
  if p_user_id is null or not (
    exists(select 1 from public.seller_profiles s where s.user_id=p_user_id and s.active=true)
    or exists(select 1 from public.stock_profiles st where st.user_id=p_user_id and st.active=true)
    or exists(select 1 from public.admin_profiles a where a.user_id=p_user_id and a.role in ('admin','supervisor','custom'))
  ) then
    raise exception 'No se encontró el usuario del catálogo' using errcode='P0002';
  end if;

  return query
  with completed as (
    select s.id,s.seller_id,s.customer_type,s.locality
    from public.seller_sales s
    where s.seller_id=p_user_id and s.status='delivered'
      and s.customer_type in ('existing','new')
  ),
  location_counts as (
    select c.locality,count(*) as sales from completed c
    where nullif(trim(c.locality),'') is not null
    group by c.locality order by sales desc,lower(c.locality) limit 1
  ),
  product_counts as (
    select i.product_name,sum(i.quantity)::bigint as units
    from completed c join public.seller_sale_items i on i.sale_id=c.id
    where i.status='delivered'
    group by i.product_name order by units desc,lower(i.product_name) limit 1
  )
  select p_user_id,
    coalesce(nullif(trim(p.full_name),''),nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='admin' then coalesce(nullif(trim(cr.name),''),'Admin')
      when ap.role='supervisor' then 'Supervisor'
      when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location='local' then 'Local'
      when st.location='deposito' then 'Logística'
      else 'Usuario' end::text,
    coalesce(v.is_verified,false),p.photo_path,
    (select count(*)::integer from completed c where c.customer_type='existing'),
    (select count(*)::integer from completed c where c.customer_type='new'),
    (select count(*)::integer from completed c),
    (select lc.locality from location_counts lc),
    (select pc.product_name from product_counts pc),
    (select pc.units from product_counts pc)
  from (select p_user_id as user_id) target
  left join public.verified_staff_profiles p on p.user_id=target.user_id
  left join public.seller_profiles sp on sp.user_id=target.user_id and sp.active=true
  left join public.admin_profiles ap on ap.user_id=target.user_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.stock_profiles st on st.user_id=target.user_id and st.active=true
  left join public.staff_sales_verifications v on v.user_id=target.user_id;
end;
$$;

create or replace function public.get_catalog_monthly_sales_ranking(p_month date default null)
returns table(category text,seller_id uuid,display_name text,role_label text,is_verified boolean,sale_count bigint,ranking_position bigint,month_start date,month_end date)
language plpgsql stable security definer set search_path='' as $$
declare
  v_month_start date:=date_trunc('month',coalesce(p_month,(now() at time zone 'America/Argentina/Buenos_Aires')::date)::timestamp)::date;
  v_month_end date;
begin
  if auth.uid() is null or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo usuarios con insignia pueden ver el ranking mensual' using errcode='42501';
  end if;
  v_month_end:=(v_month_start+interval '1 month - 1 day')::date;
  return query
  with counted as (
    select s.seller_id,s.customer_type,count(*)::bigint as sale_count
    from public.seller_sales s
    where s.status='delivered'
      and s.customer_type in ('existing','new')
      and s.updated_at >= (v_month_start::timestamp at time zone 'America/Argentina/Buenos_Aires')
      and s.updated_at < ((v_month_end+1)::timestamp at time zone 'America/Argentina/Buenos_Aires')
    group by s.seller_id,s.customer_type
  ),
  ranked as (
    select c.seller_id,c.customer_type,c.sale_count,
      row_number() over(partition by c.customer_type order by c.sale_count desc,c.seller_id) as ranking_position
    from counted c
  )
  select case r.customer_type when 'new' then 'new' else 'existing' end::text,
    r.seller_id,
    coalesce(nullif(trim(vp.full_name),''),nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='admin' then coalesce(nullif(trim(cr.name),''),'Admin')
      when ap.role='supervisor' then 'Supervisor'
      when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location='local' then 'Local'
      when st.location='deposito' then 'Logística'
      else 'Usuario' end::text,
    coalesce(v.is_verified,false),r.sale_count,r.ranking_position,v_month_start,v_month_end
  from ranked r
  left join public.verified_staff_profiles vp on vp.user_id=r.seller_id
  left join public.seller_profiles sp on sp.user_id=r.seller_id
  left join public.admin_profiles ap on ap.user_id=r.seller_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.stock_profiles st on st.user_id=r.seller_id
  left join public.staff_sales_verifications v on v.user_id=r.seller_id
  where r.ranking_position<=5
  order by r.customer_type,r.ranking_position;
end;
$$;

create or replace function public.get_catalog_staff_directory()
returns table(user_id uuid,display_name text,role_label text,supervisor_ids uuid[],is_verified boolean,photo_path text)
language plpgsql stable security definer set search_path='' as $$
declare
  v_can_view_photos boolean:=ev_internal.staff_sales_is_verified(auth.uid());
begin
  if not public.can_access_catalog_presence() then
    raise exception 'Esta cuenta no puede consultar el personal del catálogo' using errcode='42501';
  end if;
  return query
  with staff_ids as (
    select s.user_id from public.seller_profiles s where s.active=true
    union select st.user_id from public.stock_profiles st where st.active=true
    union select a.user_id from public.admin_profiles a where a.role in ('admin','supervisor','custom')
  )
  select ids.user_id,
    coalesce(nullif(trim(vp.full_name),''),nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),'Sin nombre')::text,
    case when ap.role='admin' then coalesce(nullif(trim(cr.name),''),'Admin')
      when ap.role='supervisor' then 'Supervisor'
      when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado')
      when sp.user_id is not null then 'Vendedor'
      when st.location='local' then 'Local'
      when st.location='deposito' then 'Logística'
      else 'Usuario' end::text,
    coalesce(array(select distinct ss.supervisor_id from public.supervisor_sellers ss where ss.seller_id=ids.user_id order by ss.supervisor_id),array[]::uuid[]),
    coalesce(v.is_verified,false),
    case when v_can_view_photos and coalesce(v.is_verified,false) then vp.photo_path else null end
  from staff_ids ids
  left join public.verified_staff_profiles vp on vp.user_id=ids.user_id
  left join public.seller_profiles sp on sp.user_id=ids.user_id and sp.active=true
  left join public.stock_profiles st on st.user_id=ids.user_id and st.active=true
  left join public.admin_profiles ap on ap.user_id=ids.user_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.staff_sales_verifications v on v.user_id=ids.user_id
  order by 3,2;
end;
$$;

create or replace function ev_internal.can_read_staff_profile_photo(p_owner_id text)
returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null
    and ev_internal.staff_sales_is_verified((select auth.uid()))
    and exists(select 1 from public.verified_staff_profiles p where p.user_id::text=p_owner_id);
$$;

revoke all on function ev_internal.can_read_staff_profile_photo(text) from public,anon;
grant execute on function ev_internal.can_read_staff_profile_photo(text) to authenticated;
revoke all on function public.get_catalog_staff_profile(uuid) from public,anon;
revoke all on function public.get_catalog_monthly_sales_ranking(date) from public,anon;
revoke all on function public.get_catalog_staff_directory() from public,anon;
grant execute on function public.get_catalog_staff_profile(uuid) to authenticated;
grant execute on function public.get_catalog_monthly_sales_ranking(date) to authenticated;
grant execute on function public.get_catalog_staff_directory() to authenticated;
drop policy if exists "Staff can read authorized profile photos" on storage.objects;
create policy "Staff can read authorized profile photos" on storage.objects
for select to authenticated
using(bucket_id='staff-profile-photos' and ev_internal.can_read_staff_profile_photo((storage.foldername(name))[1]));
notify pgrst,'reload schema';

