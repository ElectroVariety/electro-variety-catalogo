alter table public.customer_sale_requests
  add column if not exists seller_id uuid references auth.users(id) on delete set null,
  add column if not exists seller_name text not null default '' check (char_length(seller_name) <= 120),
  add column if not exists credit_assessment text not null default 'not_reviewed'
    check (credit_assessment = any (array['not_reviewed'::text, 'favorable'::text, 'needs_review'::text, 'unfavorable'::text]));

alter table public.customer_sale_requests
  drop constraint if exists customer_sale_requests_status_check;
alter table public.customer_sale_requests
  add constraint customer_sale_requests_status_check
  check (status = any (array['pending'::text, 'contacted'::text, 'converted'::text, 'cancelled'::text, 'approved'::text, 'rejected'::text]));

create index if not exists customer_sale_requests_seller_created_idx
  on public.customer_sale_requests (seller_id, created_at desc);

create schema if not exists ev_internal;
revoke all on schema ev_internal from public, anon;
grant usage on schema ev_internal to authenticated;

create or replace function ev_internal.can_review_customer_sale_request(p_seller_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and (
    exists (
      select 1 from public.admin_profiles ap
      where ap.user_id = auth.uid() and ap.role = 'admin'
    )
    or (
      p_seller_id is not null
      and exists (
        select 1 from public.admin_profiles ap
        where ap.user_id = auth.uid() and ap.role = 'supervisor'
      )
      and (
        p_seller_id = auth.uid()
        or exists (
          select 1 from public.supervisor_sellers ss
          where ss.supervisor_id = auth.uid() and ss.seller_id = p_seller_id
        )
      )
    )
  );
$$;
revoke all on function ev_internal.can_review_customer_sale_request(uuid) from public, anon;
grant execute on function ev_internal.can_review_customer_sale_request(uuid) to authenticated;

drop policy if exists "Admins can read customer sale requests" on public.customer_sale_requests;
drop policy if exists "Admins can update customer sale requests" on public.customer_sale_requests;
drop policy if exists "Staff can read scoped customer sale requests" on public.customer_sale_requests;
drop policy if exists "Staff can review scoped customer sale requests" on public.customer_sale_requests;

create policy "Staff can read scoped customer sale requests"
  on public.customer_sale_requests
  for select to authenticated
  using ((select ev_internal.can_review_customer_sale_request(seller_id)));

create policy "Staff can review scoped customer sale requests"
  on public.customer_sale_requests
  for update to authenticated
  using ((select ev_internal.can_review_customer_sale_request(seller_id)))
  with check ((select ev_internal.can_review_customer_sale_request(seller_id)));

revoke update on public.customer_sale_requests from authenticated;
grant update (status, admin_note, reviewed_by, reviewed_at, updated_at, credit_assessment)
  on public.customer_sale_requests to authenticated;

create table if not exists public.customer_sale_referral_links (
  token uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '365 days')
);
create index if not exists customer_sale_referral_links_owner_idx
  on public.customer_sale_referral_links (owner_id, expires_at desc);
alter table public.customer_sale_referral_links enable row level security;
revoke all on public.customer_sale_referral_links from anon, authenticated;
grant select, insert on public.customer_sale_referral_links to authenticated;
drop policy if exists "Staff can create own customer sale referral links" on public.customer_sale_referral_links;
create policy "Staff can create own customer sale referral links"
  on public.customer_sale_referral_links for insert to authenticated
  with check (
    owner_id = (select auth.uid())
    and (
      exists (select 1 from public.seller_profiles sp where sp.user_id = auth.uid() and sp.active = true)
      or exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role in ('admin', 'supervisor'))
    )
  );
drop policy if exists "Staff can read own customer sale referral links" on public.customer_sale_referral_links;
create policy "Staff can read own customer sale referral links"
  on public.customer_sale_referral_links for select to authenticated
  using (owner_id = (select auth.uid()));

drop policy if exists "Admins can view customer sale DNI documents" on storage.objects;
drop policy if exists "Staff can view scoped customer sale documents" on storage.objects;
create policy "Staff can view scoped customer sale documents"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'customer-sale-private'
    and exists (
      select 1
      from public.customer_sale_requests csr
      where csr.id::text = case
        when split_part(name, '/', 1) = 'dni' then split_part(name, '/', 2)
        when split_part(name, '/', 1) = 'sale-requests' then split_part(name, '/', 2)
        else ''
      end
      and ev_internal.can_review_customer_sale_request(csr.seller_id)
    )
  );

comment on column public.customer_sale_requests.seller_id is
  'Staff user that referred the public purchase request; supervisors can review their own and assigned sellers requests.';
comment on column public.customer_sale_requests.credit_assessment is
  'Manual credit assessment recorded by authorized staff; this does not query an external credit bureau.';
notify pgrst, 'reload schema';
