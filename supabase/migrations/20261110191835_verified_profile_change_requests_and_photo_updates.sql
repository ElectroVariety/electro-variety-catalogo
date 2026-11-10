create table if not exists public.verified_staff_profile_change_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  requested_full_name text not null check (char_length(trim(requested_full_name)) between 3 and 120),
  requested_dni text not null check (char_length(trim(requested_dni)) between 7 and 20),
  requested_birth_date date not null check (requested_birth_date <= current_date),
  requested_gender text not null check (requested_gender in ('female','male','non_binary','other','prefer_not_to_say')),
  requested_phone text not null check (char_length(trim(requested_phone)) between 8 and 25),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_note text,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz
);
alter table public.verified_staff_profile_change_requests enable row level security;
revoke all on public.verified_staff_profile_change_requests from public,anon,authenticated;
create unique index if not exists verified_staff_profile_one_pending_change_per_user
  on public.verified_staff_profile_change_requests(user_id) where status='pending';

create or replace function public.save_my_verified_staff_profile(p_full_name text,p_dni text,p_birth_date date,p_gender text,p_phone text,p_photo_path text default null)
returns public.verified_staff_profiles
language plpgsql security definer set search_path='' as $$
declare v_profile public.verified_staff_profiles%rowtype; v_name text:=nullif(trim(p_full_name),''); v_dni text:=nullif(trim(p_dni),''); v_phone text:=nullif(trim(p_phone),'');
begin
  if auth.uid() is null then raise exception 'Iniciá sesión' using errcode='42501'; end if;
  if not ev_internal.staff_sales_is_verified(auth.uid()) and not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then
    raise exception 'Solo los usuarios verificados pueden guardar este perfil' using errcode='42501';
  end if;
  if exists(select 1 from public.verified_staff_profiles p where p.user_id=auth.uid()) then
    raise exception 'Los datos guardados están bloqueados. Enviá una solicitud al administrador para modificarlos.' using errcode='42501';
  end if;
  if v_name is null or char_length(v_name)<3 or char_length(v_name)>120 then raise exception 'Ingresá nombre y apellido'; end if;
  if v_dni is null or char_length(v_dni)<7 or char_length(v_dni)>20 then raise exception 'Ingresá un DNI válido'; end if;
  if p_birth_date is null or p_birth_date>current_date then raise exception 'Ingresá una fecha de nacimiento válida'; end if;
  if p_gender not in ('female','male','non_binary','other','prefer_not_to_say') then raise exception 'Elegí una opción de género'; end if;
  if v_phone is null or char_length(v_phone)<8 or char_length(v_phone)>25 then raise exception 'Ingresá un teléfono válido'; end if;
  if p_photo_path is not null and p_photo_path !~ ('^' || auth.uid()::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$') then raise exception 'La foto seleccionada no es válida'; end if;
  insert into public.verified_staff_profiles(user_id,full_name,dni,birth_date,gender,phone,photo_path,completed_at,updated_at)
  values(auth.uid(),v_name,v_dni,p_birth_date,p_gender,v_phone,p_photo_path,now(),now())
  returning * into v_profile;
  update public.seller_profiles set name=v_name,phone=v_phone where user_id=auth.uid();
  update public.admin_profiles set display_name=v_name where user_id=auth.uid();
  update public.stock_profiles set name=v_name where user_id=auth.uid();
  return v_profile;
end;
$$;

create or replace function public.save_my_verified_staff_profile_photo(p_photo_path text)
returns public.verified_staff_profiles
language plpgsql security definer set search_path='' as $$
declare v_profile public.verified_staff_profiles%rowtype;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión' using errcode='42501'; end if;
  if not ev_internal.staff_sales_is_verified(auth.uid()) and not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then
    raise exception 'Solo los usuarios verificados pueden cambiar esta foto' using errcode='42501';
  end if;
  if p_photo_path is not null and p_photo_path !~ ('^' || auth.uid()::text || '/[0-9a-f-]{36}\.(jpg|jpeg|png|webp)$') then raise exception 'La foto seleccionada no es válida'; end if;
  update public.verified_staff_profiles set photo_path=p_photo_path,updated_at=now()
  where user_id=auth.uid() returning * into v_profile;
  if not found then raise exception 'Primero completá los datos personales' using errcode='42501'; end if;
  return v_profile;
end;
$$;

create or replace function public.submit_verified_staff_profile_change_request(
  p_full_name text,p_dni text,p_birth_date date,p_gender text,p_phone text
)
returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_name text:=nullif(trim(p_full_name),''); v_dni text:=nullif(trim(p_dni),''); v_phone text:=nullif(trim(p_phone),'');
begin
  if auth.uid() is null or not ev_internal.staff_sales_is_verified(auth.uid()) then raise exception 'Solo los usuarios con insignia pueden solicitar cambios' using errcode='42501'; end if;
  if not exists(select 1 from public.verified_staff_profiles p where p.user_id=auth.uid()) then raise exception 'Completá primero tu perfil personal' using errcode='42501'; end if;
  if v_name is null or char_length(v_name)<3 or char_length(v_name)>120 then raise exception 'Ingresá nombre y apellido'; end if;
  if v_dni is null or char_length(v_dni)<7 or char_length(v_dni)>20 then raise exception 'Ingresá un DNI válido'; end if;
  if p_birth_date is null or p_birth_date>current_date then raise exception 'Ingresá una fecha de nacimiento válida'; end if;
  if p_gender not in ('female','male','non_binary','other','prefer_not_to_say') then raise exception 'Elegí una opción de género'; end if;
  if v_phone is null or char_length(v_phone)<8 or char_length(v_phone)>25 then raise exception 'Ingresá un teléfono válido'; end if;
  insert into public.verified_staff_profile_change_requests(user_id,requested_full_name,requested_dni,requested_birth_date,requested_gender,requested_phone)
  values(auth.uid(),v_name,v_dni,p_birth_date,p_gender,v_phone) returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'Ya tenés una solicitud pendiente de revisión' using errcode='23505';
end;
$$;

create or replace function public.get_my_verified_staff_profile_change_request()
returns table(request_id uuid,status text,requested_at timestamptz,admin_note text)
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null or not ev_internal.staff_sales_is_verified(auth.uid()) then raise exception 'Acceso restringido' using errcode='42501'; end if;
  return query select r.id,r.status,r.requested_at,r.admin_note
  from public.verified_staff_profile_change_requests r where r.user_id=auth.uid()
  order by r.requested_at desc limit 1;
end;
$$;

create or replace function public.admin_list_verified_staff_profile_change_requests(p_limit integer default 500)
returns table(
  request_id uuid,user_id uuid,display_name text,role_label text,
  current_full_name text,current_dni text,current_birth_date date,current_gender text,current_phone text,
  requested_full_name text,requested_dni text,requested_birth_date date,requested_gender text,requested_phone text,
  requested_at timestamptz
)
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then raise exception 'Solo el administrador puede revisar solicitudes' using errcode='42501'; end if;
  return query select r.id,r.user_id,coalesce(nullif(trim(sp.name),''),nullif(trim(ap.display_name),''),nullif(trim(st.name),''),r.requested_full_name)::text,
    case when ap.role='admin' then coalesce(nullif(trim(cr.name),''),'Admin') when ap.role='supervisor' then 'Supervisor' when ap.role='custom' then coalesce(nullif(trim(cr.name),''),'Personalizado') when sp.user_id is not null then 'Vendedor' when st.location='local' then 'Local' when st.location='deposito' then 'Logística' else 'Usuario' end::text,
    p.full_name,p.dni,p.birth_date,p.gender,p.phone,r.requested_full_name,r.requested_dni,r.requested_birth_date,r.requested_gender,r.requested_phone,r.requested_at
  from public.verified_staff_profile_change_requests r
  join public.verified_staff_profiles p on p.user_id=r.user_id
  left join public.seller_profiles sp on sp.user_id=r.user_id
  left join public.admin_profiles ap on ap.user_id=r.user_id
  left join public.staff_custom_roles cr on cr.id=ap.custom_role_id
  left join public.stock_profiles st on st.user_id=r.user_id
  where r.status='pending'
  order by r.requested_at limit greatest(1,least(coalesce(p_limit,500),2000));
end;
$$;

create or replace function public.admin_review_verified_staff_profile_change_request(p_request_id uuid,p_approve boolean,p_admin_note text default null)
returns text
language plpgsql security definer set search_path='' as $$
declare v_request public.verified_staff_profile_change_requests%rowtype;
begin
  if not exists(select 1 from public.admin_profiles ap where ap.user_id=auth.uid() and ap.role='admin') then raise exception 'Solo el administrador puede revisar solicitudes' using errcode='42501'; end if;
  select * into v_request from public.verified_staff_profile_change_requests r where r.id=p_request_id for update;
  if not found or v_request.status<>'pending' then raise exception 'La solicitud ya fue revisada o no existe'; end if;
  if p_approve then
    update public.verified_staff_profiles set full_name=v_request.requested_full_name,dni=v_request.requested_dni,birth_date=v_request.requested_birth_date,
      gender=v_request.requested_gender,phone=v_request.requested_phone,updated_at=now()
    where user_id=v_request.user_id;
    if not found then raise exception 'No se encontró el perfil actual'; end if;
    update public.seller_profiles set name=v_request.requested_full_name,phone=v_request.requested_phone where user_id=v_request.user_id;
    update public.admin_profiles set display_name=v_request.requested_full_name where user_id=v_request.user_id;
    update public.stock_profiles set name=v_request.requested_full_name where user_id=v_request.user_id;
  end if;
  update public.verified_staff_profile_change_requests set status=case when p_approve then 'approved' else 'rejected' end,
    admin_note=nullif(trim(p_admin_note),''),reviewed_by=auth.uid(),reviewed_at=now() where id=p_request_id;
  return case when p_approve then 'approved' else 'rejected' end;
end;
$$;

revoke all on function public.save_my_verified_staff_profile(text,text,date,text,text,text) from public,anon;
revoke all on function public.save_my_verified_staff_profile_photo(text) from public,anon;
revoke all on function public.submit_verified_staff_profile_change_request(text,text,date,text,text) from public,anon;
revoke all on function public.get_my_verified_staff_profile_change_request() from public,anon;
revoke all on function public.admin_list_verified_staff_profile_change_requests(integer) from public,anon;
revoke all on function public.admin_review_verified_staff_profile_change_request(uuid,boolean,text) from public,anon;
grant execute on function public.save_my_verified_staff_profile(text,text,date,text,text,text) to authenticated;
grant execute on function public.save_my_verified_staff_profile_photo(text) to authenticated;
grant execute on function public.submit_verified_staff_profile_change_request(text,text,date,text,text) to authenticated;
grant execute on function public.get_my_verified_staff_profile_change_request() to authenticated;
grant execute on function public.admin_list_verified_staff_profile_change_requests(integer) to authenticated;
grant execute on function public.admin_review_verified_staff_profile_change_request(uuid,boolean,text) to authenticated;
notify pgrst,'reload schema';
