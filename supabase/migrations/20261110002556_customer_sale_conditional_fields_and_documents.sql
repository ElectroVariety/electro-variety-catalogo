alter table public.customer_sale_requests
  add column if not exists conditional_details jsonb not null default '{}'::jsonb,
  add column if not exists document_paths jsonb not null default '{}'::jsonb;

update storage.buckets
set allowed_mime_types = array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp',
  'video/mp4', 'video/quicktime'
]::text[]
where id = 'customer-sale-private';

comment on column public.customer_sale_requests.conditional_details is
  'Additional applicant details requested by conditional fields in the customer sales form.';
comment on column public.customer_sale_requests.document_paths is
  'Private customer-sale documents stored in customer-sale-private; administrator-only access.';
