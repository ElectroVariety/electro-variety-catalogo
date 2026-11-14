-- Public referral links may use a verified staff member's registered phone.
-- Existing UUID referral URLs continue to resolve unchanged.
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
  v_owners uuid[];
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

  select array_agg(distinct l.owner_id) into v_owners
  from public.customer_sale_referral_links l
  join public.staff_sales_verifications v on v.user_id = l.owner_id and v.is_verified = true
  left join public.verified_staff_profiles vp on vp.user_id = l.owner_id
  left join public.seller_profiles sp on sp.user_id = l.owner_id
  left join public.stock_profiles st on st.user_id = l.owner_id
  where l.expires_at > now()
    and regexp_replace(
      coalesce(nullif(btrim(vp.phone), ''), nullif(btrim(sp.phone), ''), nullif(btrim(st.phone), '')),
      '[^0-9]', '', 'g'
    ) = v_digits;

  if coalesce(cardinality(v_owners), 0) <> 1 then
    return null;
  end if;
  return v_owners[1];
end;
$function$;

revoke all on function public.resolve_customer_sale_referral_owner(text) from public, anon, authenticated;
grant execute on function public.resolve_customer_sale_referral_owner(text) to service_role;
comment on function public.resolve_customer_sale_referral_owner(text) is
  'Resolves an existing referral UUID or a unique registered phone for an actively verified staff link.';

drop function if exists public.resolve_customer_catalog_whatsapp(uuid);
create function public.resolve_customer_catalog_whatsapp(p_token text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_owner_id uuid;
  v_raw text;
  v_digits text;
begin
  v_owner_id := public.resolve_customer_sale_referral_owner(p_token);
  if v_owner_id is null then
    return null;
  end if;

  select coalesce(nullif(btrim(vp.phone), ''), nullif(btrim(sp.phone), ''), nullif(btrim(st.phone), ''))
  into v_raw
  from public.staff_sales_verifications v
  left join public.verified_staff_profiles vp on vp.user_id = v.user_id
  left join public.seller_profiles sp on sp.user_id = v.user_id
  left join public.stock_profiles st on st.user_id = v.user_id
  where v.user_id = v_owner_id and v.is_verified = true;

  v_digits := regexp_replace(coalesce(v_raw, ''), '[^0-9]', '', 'g');
  if v_digits = '' then
    return null;
  end if;

  if left(v_digits, 3) = '549' or left(v_digits, 2) = '54' then
    return v_digits;
  elsif left(v_digits, 1) = '0' then
    v_digits := substr(v_digits, 2);
  end if;

  if length(v_digits) = 10 then
    return '549' || v_digits;
  elsif length(v_digits) between 11 and 15 then
    return v_digits;
  end if;
  return null;
end;
$function$;

revoke all on function public.resolve_customer_catalog_whatsapp(text) from public;
grant execute on function public.resolve_customer_catalog_whatsapp(text) to anon, authenticated;
comment on function public.resolve_customer_catalog_whatsapp(text) is
  'Resolves a personal catalog link from its old UUID or the verified staff member registered phone.';

drop function if exists public.record_customer_catalog_analytics_event(uuid, uuid, uuid, text, bigint);
create function public.record_customer_catalog_analytics_event(
  p_token text,
  p_visitor_id uuid,
  p_session_id uuid,
  p_event_type text,
  p_product_id bigint default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_owner_id uuid;
begin
  if p_token is null or p_visitor_id is null or p_session_id is null or p_event_type is null then
    return false;
  end if;
  if p_event_type not in ('visit', 'product_consult', 'delivery_consult', 'install', 'notification_granted', 'notification_denied', 'push_subscribed') then
    return false;
  end if;
  if (p_event_type = 'product_consult') <> (p_product_id is not null) then
    return false;
  end if;

  v_owner_id := public.resolve_customer_sale_referral_owner(p_token);
  if v_owner_id is null then
    return false;
  end if;
  if p_event_type = 'product_consult' and not exists (
    select 1 from public.products p where p.id = p_product_id and p.active = true
  ) then
    return false;
  end if;
  if p_event_type in ('product_consult', 'delivery_consult') and (
    select count(*) from public.customer_catalog_analytics_events e
    where e.owner_id = v_owner_id and e.visitor_id = p_visitor_id
      and e.event_type = p_event_type and e.created_at >= now() - interval '1 hour'
  ) >= 120 then
    return false;
  end if;

  insert into public.customer_catalog_analytics_events(owner_id, visitor_id, session_id, event_type, product_id)
  values (v_owner_id, p_visitor_id, p_session_id, p_event_type, p_product_id)
  on conflict do nothing;
  return found;
end;
$function$;

revoke all on function public.record_customer_catalog_analytics_event(text, uuid, uuid, text, bigint) from public;
grant execute on function public.record_customer_catalog_analytics_event(text, uuid, uuid, text, bigint) to anon, authenticated;
comment on function public.record_customer_catalog_analytics_event(text, uuid, uuid, text, bigint) is
  'Records pseudonymous analytics for personal links identified by registered phone or legacy UUID.';

notify pgrst, 'reload schema';
