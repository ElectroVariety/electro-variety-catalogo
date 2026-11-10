create table if not exists public.verified_staff_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (char_length(trim(full_name)) between 3 and 120),
  dni text not null check (char_length(trim(dni)) between 7 and 20),
  birth_date date not null check (birth_date <= current_date),
  gender text not null check (gender in ('female','male','non_binary','other','prefer_not_to_say')),
  phone text not null check (char_length(trim(phone)) between 8 and 25),
  photo_path text check (photo_path is null or photo_path ~ ('^' || user_id::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$')),
  completed_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.verified_staff_profiles enable row level security;
revoke all on public.verified_staff_profiles from public, anon, authenticated;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('staff-profile-photos','staff-profile-photos',false,5242880,array['image/jpeg','image/png','image/webp']::text[])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Verified staff own profile photo upload" on storage.objects;
create policy "Verified staff own profile photo upload" on storage.objects for insert to authenticated
with check(bucket_id='staff-profile-photos' and (storage.foldername(name))[1]=(select auth.uid())::text
  and ((select public.is_admin()) or ev_internal.staff_sales_is_verified((select auth.uid()))));
drop policy if exists "Staff can read authorized profile photos" on storage.objects;
create policy "Staff can read authorized profile photos" on storage.objects for select to authenticated
using(bucket_id='staff-profile-photos' and (
  (storage.foldername(name))[1]=(select auth.uid())::text
  or (select public.is_admin())
  or exists(select 1 from public.supervisor_sellers ss join public.admin_profiles ap on ap.user_id=ss.supervisor_id
    where ss.supervisor_id=(select auth.uid()) and ap.role='supervisor'
      and ev_internal.staff_sales_is_verified((select auth.uid()))
      and ss.seller_id::text=(storage.foldername(name))[1])
));
drop policy if exists "Verified staff own profile photo update" on storage.objects;
create policy "Verified staff own profile photo update" on storage.objects for update to authenticated
using(bucket_id='staff-profile-photos' and (storage.foldername(name))[1]=(select auth.uid())::text)
with check(bucket_id='staff-profile-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Verified staff own profile photo delete" on storage.objects;
create policy "Verified staff own profile photo delete" on storage.objects for delete to authenticated
using(bucket_id='staff-profile-photos' and (storage.foldername(name))[1]=(select auth.uid())::text);

create or replace function public.get_my_verified_staff_profile()
returns table(user_id uuid,full_name text,dni text,birth_date date,gender text,phone text,photo_path text,completed_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Iniciá sesión' using errcode='42501'; end if;
  if not ev_internal.staff_sales_is_verified(auth.uid()) and not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then
    raise exception 'El perfil personal está disponible para usuarios verificados' using errcode='42501';
  end if;
  return query select p.user_id,p.full_name,p.dni,p.birth_date,p.gender,p.phone,p.photo_path,p.completed_at from public.verified_staff_profiles p where p.user_id=auth.uid();
end;
$$;

create or replace function public.save_my_verified_staff_profile(p_full_name text,p_dni text,p_birth_date date,p_gender text,p_phone text,p_photo_path text default null)
returns public.verified_staff_profiles
language plpgsql security definer set search_path='' as $$
declare v_profile public.verified_staff_profiles%rowtype; v_name text:=nullif(trim(p_full_name),''); v_dni text:=nullif(trim(p_dni),''); v_phone text:=nullif(trim(p_phone),'');
begin
  if auth.uid() is null then raise exception 'Iniciá sesión' using errcode='42501'; end if;
  if not ev_internal.staff_sales_is_verified(auth.uid()) and not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then
    raise exception 'Solo los usuarios verificados pueden guardar este perfil' using errcode='42501';
  end if;
  if v_name is null or char_length(v_name)<3 or char_length(v_name)>120 then raise exception 'Ingresá nombre y apellido'; end if;
  if v_dni is null or char_length(v_dni)<7 or char_length(v_dni)>20 then raise exception 'Ingresá un DNI válido'; end if;
  if p_birth_date is null or p_birth_date>current_date then raise exception 'Ingresá una fecha de nacimiento válida'; end if;
  if p_gender not in ('female','male','non_binary','other','prefer_not_to_say') then raise exception 'Elegí una opción de género'; end if;
  if v_phone is null or char_length(v_phone)<8 or char_length(v_phone)>25 then raise exception 'Ingresá un teléfono válido'; end if;
  if p_photo_path is not null and p_photo_path !~ ('^' || auth.uid()::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$') then raise exception 'La foto seleccionada no es válida'; end if;
  insert into public.verified_staff_profiles(user_id,full_name,dni,birth_date,gender,phone,photo_path,completed_at,updated_at)
  values(auth.uid(),v_name,v_dni,p_birth_date,p_gender,v_phone,p_photo_path,now(),now())
  on conflict(user_id) do update set full_name=excluded.full_name,dni=excluded.dni,birth_date=excluded.birth_date,gender=excluded.gender,phone=excluded.phone,photo_path=coalesce(excluded.photo_path,verified_staff_profiles.photo_path),completed_at=now(),updated_at=now()
  returning * into v_profile;
  update public.seller_profiles set name=v_name,phone=v_phone where user_id=auth.uid();
  update public.admin_profiles set display_name=v_name where user_id=auth.uid();
  update public.stock_profiles set name=v_name where user_id=auth.uid();
  return v_profile;
end;
$$;

create or replace function public.admin_list_verified_staff_profiles(p_limit integer default 1000)
returns table(user_id uuid,full_name text,dni text,birth_date date,gender text,phone text,photo_path text,role_label text,completed_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then raise exception 'Solo el administrador puede ver todos los perfiles' using errcode='42501'; end if;
  return query select p.user_id,p.full_name,p.dni,p.birth_date,p.gender,p.phone,p.photo_path,
    case when ap.role='admin' then coalesce(nullif(trim(cr.name),''),'Admin') when ap.role='supervisor' then 'Supervisor' when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado') when sp.user_id is not null then 'Vendedor' when st.location='local' then 'Local' when st.location='deposito' then 'Logística' else 'Usuario' end::text,p.completed_at
  from public.verified_staff_profiles p
  left join public.admin_profiles ap on ap.user_id=p.user_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.seller_profiles sp on sp.user_id=p.user_id
  left join public.stock_profiles st on st.user_id=p.user_id
  left join public.staff_sales_verifications v on v.user_id=p.user_id
  where coalesce(v.is_verified,false) or ap.role='admin'
  order by p.full_name limit greatest(1,least(coalesce(p_limit,1000),3000));
end;
$$;

create or replace function public.supervisor_list_verified_staff_profiles(p_limit integer default 500)
returns table(user_id uuid,full_name text,dni text,birth_date date,gender text,phone text,photo_path text,role_label text,completed_at timestamptz)
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='supervisor') or not ev_internal.staff_sales_is_verified(auth.uid()) then raise exception 'Solo supervisores verificados pueden ver estos perfiles' using errcode='42501'; end if;
  return query select p.user_id,p.full_name,p.dni,p.birth_date,p.gender,p.phone,p.photo_path,'Vendedor'::text,p.completed_at
  from public.verified_staff_profiles p
  join public.supervisor_sellers ss on ss.seller_id=p.user_id and ss.supervisor_id=auth.uid()
  join public.seller_profiles sp on sp.user_id=p.user_id and sp.active=true
  join public.staff_sales_verifications v on v.user_id=p.user_id and v.is_verified=true
  order by p.full_name limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;

revoke all on function public.get_my_verified_staff_profile() from public,anon;
revoke all on function public.save_my_verified_staff_profile(text,text,date,text,text,text) from public,anon;
revoke all on function public.admin_list_verified_staff_profiles(integer) from public,anon;
revoke all on function public.supervisor_list_verified_staff_profiles(integer) from public,anon;
grant execute on function public.get_my_verified_staff_profile() to authenticated;
grant execute on function public.save_my_verified_staff_profile(text,text,date,text,text,text) to authenticated;
grant execute on function public.admin_list_verified_staff_profiles(integer) to authenticated;
grant execute on function public.supervisor_list_verified_staff_profiles(integer) to authenticated;
notify pgrst,'reload schema';
