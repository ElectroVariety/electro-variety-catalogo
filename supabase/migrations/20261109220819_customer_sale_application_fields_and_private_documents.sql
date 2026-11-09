alter table public.customer_sale_requests
  add column if not exists dni text not null default '' check (char_length(dni) <= 20),
  add column if not exists dni_updated boolean not null default false,
  add column if not exists alternative_phone text not null default '' check (char_length(alternative_phone) <= 20),
  add column if not exists alternative_contact_relationship text not null default '' check (char_length(alternative_contact_relationship) <= 100),
  add column if not exists referred_by boolean not null default false,
  add column if not exists is_electro_variety_customer boolean not null default false,
  add column if not exists street text not null default '' check (char_length(street) <= 120),
  add column if not exists street_number text not null default '' check (char_length(street_number) <= 30),
  add column if not exists between_streets text not null default '' check (char_length(between_streets) <= 120),
  add column if not exists housing_situation text not null default '' check (housing_situation = any (array[''::text, 'own'::text, 'rent_contract'::text, 'rent_verbal'::text])),
  add column if not exists proof_services text[] not null default '{}' check (proof_services <@ array['edesur'::text, 'metrogas'::text, 'water'::text, 'other'::text, 'none_in_name'::text]),
  add column if not exists has_debts boolean not null default false,
  add column if not exists income_sources text[] not null default '{}' check (income_sources <@ array['formal_job'::text, 'informal_job'::text, 'self_employed'::text, 'business'::text, 'allowance'::text, 'retirement'::text, 'pension'::text, 'cooperative'::text, 'other'::text]),
  add column if not exists dni_front_path text check (dni_front_path is null or dni_front_path ~ '^dni/[0-9a-f-]{36}/front\.(jpg|jpeg|png|webp|pdf)$'),
  add column if not exists dni_back_path text check (dni_back_path is null or dni_back_path ~ '^dni/[0-9a-f-]{36}/back\.(jpg|jpeg|png|webp|pdf)$');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'customer-sale-private',
  'customer-sale-private',
  false,
  5242880,
  array['application/pdf', 'image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Admins can view customer sale DNI documents" on storage.objects;
create policy "Admins can view customer sale DNI documents"
  on storage.objects
  for select
  to authenticated
  using (bucket_id = 'customer-sale-private' and (select public.is_admin()));

comment on column public.customer_sale_requests.dni_front_path is
  'Object path for the DNI front image/PDF in the private customer-sale-private bucket.';
comment on column public.customer_sale_requests.dni_back_path is
  'Object path for the DNI back image/PDF in the private customer-sale-private bucket.';
