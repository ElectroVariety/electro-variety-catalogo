-- Products with this scope are available in the authenticated staff catalog,
-- but hidden from anonymous customer catalogs and purchase forms.
alter table public.products
  drop constraint if exists products_customer_catalog_scope_check;

alter table public.products
  add constraint products_customer_catalog_scope_check
  check (customer_catalog_scope in ('all', 'general_only', 'seller_only'));

drop policy if exists "Public customer catalog reads active products" on public.products;
create policy "Public customer catalog reads active products"
  on public.products for select to anon
  using (
    active = true
    and coalesce(customer_catalog_scope, 'all') <> 'seller_only'
  );
