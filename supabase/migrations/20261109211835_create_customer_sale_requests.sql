create table if not exists public.customer_sale_requests (
  id uuid primary key default gen_random_uuid(),
  tracking_code text not null unique check (tracking_code ~ '^[A-Z0-9-]{6,20}$'),
  full_name text not null check (char_length(btrim(full_name)) between 2 and 120),
  phone text not null check (char_length(phone) between 8 and 20),
  locality text not null default '' check (char_length(locality) <= 120),
  address text not null default '' check (char_length(address) <= 200),
  notes text not null default '' check (char_length(notes) <= 1000),
  items jsonb not null check (
    jsonb_typeof(items) = 'array'
    and jsonb_array_length(items) between 1 and 10
  ),
  status text not null default 'pending' check (
    status = any (array['pending'::text, 'contacted'::text, 'converted'::text, 'cancelled'::text])
  ),
  admin_note text not null default '' check (char_length(admin_note) <= 1000),
  privacy_accepted boolean not null default true check (privacy_accepted),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz
);

create index if not exists customer_sale_requests_created_at_idx
  on public.customer_sale_requests (created_at desc);

create index if not exists customer_sale_requests_status_created_at_idx
  on public.customer_sale_requests (status, created_at desc);

alter table public.customer_sale_requests enable row level security;

revoke all on public.customer_sale_requests from anon, authenticated;
grant select, update on public.customer_sale_requests to authenticated;

create policy "Admins can read customer sale requests"
  on public.customer_sale_requests
  for select
  to authenticated
  using ((select public.is_admin()));

create policy "Admins can update customer sale requests"
  on public.customer_sale_requests
  for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

comment on table public.customer_sale_requests is
  'Public customer requests for product purchases. Requests are reviewed by staff and do not reserve or change stock.';
