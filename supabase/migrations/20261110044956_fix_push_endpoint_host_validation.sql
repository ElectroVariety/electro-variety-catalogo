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
declare
  endpoint_authority text;
begin
  if p_endpoint is null or length(btrim(p_endpoint)) = 0 or length(p_endpoint) > 2048
    or lower(btrim(p_endpoint)) not like 'https://%/%' then
    raise exception 'Invalid Push endpoint';
  end if;

  endpoint_authority := lower(split_part(split_part(btrim(p_endpoint), '/', 3), '?', 1));
  if endpoint_authority not in (
    'fcm.googleapis.com',
    'updates.push.services.mozilla.com',
    'web.push.apple.com'
  )
    and endpoint_authority not like '%.push.services.mozilla.com'
    and endpoint_authority not like '%.notify.windows.com' then
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

-- Restore the Chrome/Chromium subscriptions affected by the first validation
-- pattern; the validation above now compares parsed authorities directly.
update public.client_push_subscriptions
set active = true, updated_at = now()
where lower(split_part(split_part(endpoint, '/', 3), ':', 1)) = 'fcm.googleapis.com';

notify pgrst, 'reload schema';
