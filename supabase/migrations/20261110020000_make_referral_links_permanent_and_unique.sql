-- Keep every seller's existing referral URL alive, and allow at most one URL per user.
update public.customer_sale_referral_links
set expires_at = 'infinity'::timestamptz
where expires_at <> 'infinity'::timestamptz;

alter table public.customer_sale_referral_links
  alter column expires_at set default 'infinity'::timestamptz;

create unique index if not exists customer_sale_referral_links_one_per_owner_idx
  on public.customer_sale_referral_links (owner_id);

revoke delete, update, truncate on public.customer_sale_referral_links from anon, authenticated;
grant select, insert on public.customer_sale_referral_links to authenticated;

comment on table public.customer_sale_referral_links is
  'One permanent, non-deletable customer purchase referral link per staff user.';
notify pgrst, 'reload schema';
