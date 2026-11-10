-- Keep privileged RPCs unavailable to unauthenticated callers. Admin-only
-- functions still validate the caller inside their SECURITY DEFINER bodies.
revoke all on function public.approve_seller_device_request(uuid) from public, anon, authenticated;
grant execute on function public.approve_seller_device_request(uuid) to authenticated;

revoke all on function public.approve_stock_request(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.approve_stock_request(uuid, jsonb) to authenticated;

revoke all on function public.revoke_seller_device(uuid) from public, anon, authenticated;
grant execute on function public.revoke_seller_device(uuid) to authenticated;

-- is_admin() is used by authenticated RLS policies and by the push sender,
-- which authenticates the administrator before calling it.
revoke all on function public.is_admin() from public, anon, authenticated;
grant execute on function public.is_admin() to authenticated;

-- This function only has an internal caller (approve_stock_request). Make the
-- same admin check explicit in case it is ever exposed again by a later grant.
create or replace function public.recalculate_product_stock(p_product_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  d integer;
  l integer;
  d_unknown boolean;
  l_unknown boolean;
  total integer;
begin
  if not public.is_admin() then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception 'El producto % no existe', p_product_id;
  end if;

  select quantity is null, coalesce(quantity, 0)
    into d_unknown, d
  from public.stock_inventory
  where product_id = p_product_id and location = 'deposito';
  if not found then d_unknown := true; d := 0; end if;

  select quantity is null, coalesce(quantity, 0)
    into l_unknown, l
  from public.stock_inventory
  where product_id = p_product_id and location = 'local';
  if not found then l_unknown := true; l := 0; end if;

  if d_unknown or l_unknown then
    update public.products set stock = -1, updated_at = now() where id = p_product_id;
  else
    total := d + l;
    update public.products set stock = total, updated_at = now() where id = p_product_id;
  end if;
end;
$$;

-- It is invoked only by the owner-executed admin approval function.
revoke all on function public.recalculate_product_stock(bigint) from public, anon, authenticated;

-- Public catalog visitors need this RPC to save their browser's Push
-- subscription. Restrict endpoints to known browser push services so the
-- administrator's sender cannot be used to make requests to arbitrary hosts.
create or replace function public.save_client_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_endpoint is null or length(btrim(p_endpoint)) = 0 or length(p_endpoint) > 2048
    or btrim(p_endpoint) !~* '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/[^[:space:]]+$' then
    raise exception 'Invalid Push endpoint';
  end if;

  if p_p256dh is null or length(btrim(p_p256dh)) = 0 or length(p_p256dh) > 1024 then
    raise exception 'Invalid Push p256dh key';
  end if;
  if p_auth is null or length(btrim(p_auth)) = 0 or length(p_auth) > 1024 then
    raise exception 'Invalid Push auth key';
  end if;
  if p_user_agent is null or length(p_user_agent) > 2048 then
    raise exception 'Invalid User-Agent';
  end if;

  insert into public.client_push_subscriptions(endpoint, p256dh, auth, user_agent, active, updated_at)
  values (btrim(p_endpoint), btrim(p_p256dh), btrim(p_auth), p_user_agent, true, now())
  on conflict (endpoint) do update set
    p256dh = excluded.p256dh,
    auth = excluded.auth,
    user_agent = excluded.user_agent,
    active = true,
    updated_at = now();
end;
$$;

revoke all on function public.save_client_push_subscription(text, text, text, text) from public, anon, authenticated;
grant execute on function public.save_client_push_subscription(text, text, text, text) to anon, authenticated;

-- Disable pre-existing non-provider URLs without deleting their records.
update public.client_push_subscriptions
set active = false, updated_at = now()
where active = true
  and endpoint !~* '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/[^[:space:]]+$';

notify pgrst, 'reload schema';
