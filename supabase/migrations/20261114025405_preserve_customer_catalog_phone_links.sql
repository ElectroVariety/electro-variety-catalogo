create table if not exists public.customer_sale_referral_phone_aliases (
  phone_digits text primary key check (phone_digits ~ '^[0-9]{8,15}$'),
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (owner_id, phone_digits)
);

create index if not exists customer_sale_referral_phone_aliases_owner_idx
  on public.customer_sale_referral_phone_aliases(owner_id);

alter table public.customer_sale_referral_phone_aliases enable row level security;
revoke all on public.customer_sale_referral_phone_aliases from public, anon, authenticated;
comment on table public.customer_sale_referral_phone_aliases is
  'Permanent phone aliases for verified staff referral URLs. Old aliases remain attached to the same owner after an approved phone change.';

-- Preserve links already shared since phone-based URLs were introduced.
insert into public.customer_sale_referral_phone_aliases(phone_digits, owner_id)
select distinct regexp_replace(
         coalesce(nullif(btrim(vp.phone), ''), nullif(btrim(sp.phone), ''), nullif(btrim(st.phone), '')),
         '[^0-9]', '', 'g'
       ), l.owner_id
from public.customer_sale_referral_links l
join public.staff_sales_verifications v on v.user_id = l.owner_id and v.is_verified = true
left join public.verified_staff_profiles vp on vp.user_id = l.owner_id
left join public.seller_profiles sp on sp.user_id = l.owner_id
left join public.stock_profiles st on st.user_id = l.owner_id
where l.expires_at > now()
  and length(regexp_replace(
    coalesce(nullif(btrim(vp.phone), ''), nullif(btrim(sp.phone), ''), nullif(btrim(st.phone), '')),
    '[^0-9]', '', 'g'
  )) between 8 and 15
on conflict (phone_digits) do nothing;

create or replace function public.resolve_customer_sale_referral_owner(p_ref text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_uuid uuid;
  v_digits text;
begin
  if p_ref is null or btrim(p_ref) = '' then
    return null;
  end if;

  if p_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_uuid := p_ref::uuid;
    select l.owner_id into v_uuid
    from public.customer_sale_referral_links l
    join public.staff_sales_verifications v on v.user_id = l.owner_id and v.is_verified = true
    where l.token = v_uuid and l.expires_at > now();
    return v_uuid;
  end if;

  v_digits := regexp_replace(p_ref, '[^0-9]', '', 'g');
  if length(v_digits) not between 8 and 15 then
    return null;
  end if;

  select a.owner_id into v_uuid
  from public.customer_sale_referral_phone_aliases a
  join public.customer_sale_referral_links l on l.owner_id = a.owner_id and l.expires_at > now()
  join public.staff_sales_verifications v on v.user_id = a.owner_id and v.is_verified = true
  where a.phone_digits = v_digits
  limit 1;
  return v_uuid;
end;
$function$;

revoke all on function public.resolve_customer_sale_referral_owner(text) from public, anon, authenticated;
grant execute on function public.resolve_customer_sale_referral_owner(text) to service_role;

create or replace function public.register_my_customer_sale_referral_phone_alias(p_phone text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_digits text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_registered_digits text;
  v_owner uuid;
begin
  if auth.uid() is null then
    raise exception 'Iniciá sesión para crear tus enlaces.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.staff_sales_verifications v
    where v.user_id = auth.uid() and v.is_verified = true
  ) then
    raise exception 'Solo los usuarios con insignia pueden crear enlaces personales.' using errcode = '42501';
  end if;

  select regexp_replace(coalesce(nullif(btrim(vp.phone), ''), nullif(btrim(sp.phone), ''), nullif(btrim(st.phone), '')),
                        '[^0-9]', '', 'g')
  into v_registered_digits
  from public.verified_staff_profiles vp
  left join public.seller_profiles sp on sp.user_id = vp.user_id
  left join public.stock_profiles st on st.user_id = vp.user_id
  where vp.user_id = auth.uid();

  if v_registered_digits is null or length(v_digits) not between 8 and 15 or v_digits <> v_registered_digits then
    raise exception 'El teléfono del enlace debe coincidir con el teléfono registrado en tu perfil.' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.customer_sale_referral_links l
    where l.owner_id = auth.uid() and l.expires_at > now()
  ) then
    raise exception 'No se encontró tu enlace personal.' using errcode = 'P0002';
  end if;

  insert into public.customer_sale_referral_phone_aliases(phone_digits, owner_id)
  values (v_digits, auth.uid())
  on conflict (phone_digits) do nothing;

  select a.owner_id into v_owner
  from public.customer_sale_referral_phone_aliases a
  where a.phone_digits = v_digits;
  if v_owner is distinct from auth.uid() then
    raise exception 'Ese teléfono ya está asociado a otro enlace personal.' using errcode = '23505';
  end if;
  return true;
end;
$function$;

revoke all on function public.register_my_customer_sale_referral_phone_alias(text) from public, anon;
grant execute on function public.register_my_customer_sale_referral_phone_alias(text) to authenticated;

create or replace function ev_internal.capture_customer_sale_referral_phone_alias()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_digits text := regexp_replace(coalesce(new.phone, ''), '[^0-9]', '', 'g');
  v_owner uuid;
begin
  if length(v_digits) between 8 and 15
     and exists (
       select 1 from public.staff_sales_verifications v
       join public.customer_sale_referral_links l on l.owner_id = v.user_id and l.expires_at > now()
       where v.user_id = new.user_id and v.is_verified = true
     ) then
    insert into public.customer_sale_referral_phone_aliases(phone_digits, owner_id)
    values (v_digits, new.user_id)
    on conflict (phone_digits) do nothing;

    select a.owner_id into v_owner
    from public.customer_sale_referral_phone_aliases a
    where a.phone_digits = v_digits;
    if v_owner is distinct from new.user_id then
      raise exception 'El teléfono ya está asociado a otro enlace personal.' using errcode = '23505';
    end if;
  end if;
  return new;
end;
$function$;

revoke all on function ev_internal.capture_customer_sale_referral_phone_alias() from public, anon, authenticated;

drop trigger if exists capture_customer_sale_phone_alias_on_insert on public.verified_staff_profiles;
create trigger capture_customer_sale_phone_alias_on_insert
after insert on public.verified_staff_profiles
for each row execute function ev_internal.capture_customer_sale_referral_phone_alias();

drop trigger if exists capture_customer_sale_phone_alias_on_phone_change on public.verified_staff_profiles;
create trigger capture_customer_sale_phone_alias_on_phone_change
after update of phone on public.verified_staff_profiles
for each row when (old.phone is distinct from new.phone)
execute function ev_internal.capture_customer_sale_referral_phone_alias();

notify pgrst, 'reload schema';
