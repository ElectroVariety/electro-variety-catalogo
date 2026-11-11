drop policy if exists "Verified staff and admins can create own customer sale referral links" on public.customer_sale_referral_links;
drop policy if exists "Verified staff and admins can read own customer sale referral links" on public.customer_sale_referral_links;

create policy "Verified staff can create own customer sale referral links"
  on public.customer_sale_referral_links for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and ev_internal.staff_sales_is_verified((select auth.uid()))
  );

create policy "Verified staff can read own customer sale referral links"
  on public.customer_sale_referral_links for select to authenticated
  using (
    owner_id = (select auth.uid())
    and ev_internal.staff_sales_is_verified((select auth.uid()))
  );

create or replace function public.resolve_customer_catalog_whatsapp(p_token uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_raw text;
  v_digits text;
begin
  if p_token is null then
    return null;
  end if;

  select coalesce(
    nullif(btrim(vp.phone), ''),
    nullif(btrim(sp.phone), ''),
    nullif(btrim(st.phone), '')
  )
  into v_raw
  from public.customer_sale_referral_links l
  join public.staff_sales_verifications verification
    on verification.user_id = l.owner_id and verification.is_verified = true
  left join public.verified_staff_profiles vp on vp.user_id = l.owner_id
  left join public.seller_profiles sp on sp.user_id = l.owner_id
  left join public.stock_profiles st on st.user_id = l.owner_id
  where l.token = p_token
    and l.expires_at > now()
  limit 1;

  if v_raw is null then
    return null;
  end if;

  v_digits := regexp_replace(v_raw, '[^0-9]', '', 'g');
  if v_digits = '' then
    return null;
  end if;

  if left(v_digits, 3) = '549' then
    return v_digits;
  elsif left(v_digits, 2) = '54' then
    return v_digits;
  elsif left(v_digits, 1) = '0' then
    v_digits := substr(v_digits, 2);
  end if;

  if length(v_digits) = 10 then
    return '549' || v_digits;
  end if;
  if length(v_digits) between 11 and 15 then
    return v_digits;
  end if;
  return null;
end;
$function$;

revoke all on function public.resolve_customer_catalog_whatsapp(uuid) from public;
grant execute on function public.resolve_customer_catalog_whatsapp(uuid) to anon, authenticated;
comment on function public.resolve_customer_catalog_whatsapp(uuid) is
  'Resolves the private WhatsApp number for a verified staff member from their permanent referral token; returns null if the token is invalid or the badge is inactive.';
notify pgrst, 'reload schema';
