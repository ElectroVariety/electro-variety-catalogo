create or replace function ev_internal.can_view_customer_sale_request(p_seller_id uuid)
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
      and p_seller_id = auth.uid()
      and (
        exists (select 1 from public.seller_profiles sp where sp.user_id = auth.uid() and sp.active = true)
        or exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
      )
    )
    or (
      p_seller_id is not null
      and exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
      and exists (
        select 1 from public.supervisor_sellers ss
        where ss.supervisor_id = auth.uid() and ss.seller_id = p_seller_id
      )
    )
  );
$$;
revoke all on function ev_internal.can_view_customer_sale_request(uuid) from public, anon;
grant execute on function ev_internal.can_view_customer_sale_request(uuid) to authenticated;

drop policy if exists "Staff can read scoped customer sale requests" on public.customer_sale_requests;
create policy "Users can read own or scoped customer sale requests"
  on public.customer_sale_requests
  for select to authenticated
  using ((select ev_internal.can_view_customer_sale_request(seller_id)));

drop policy if exists "Staff can view scoped customer sale documents" on storage.objects;
create policy "Users can view own or scoped customer sale documents"
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
      and ev_internal.can_view_customer_sale_request(csr.seller_id)
    )
  );

comment on function ev_internal.can_view_customer_sale_request(uuid) is
  'Admin sees every customer purchase request; sellers see their own; supervisors see their own and assigned sellers.';
notify pgrst, 'reload schema';
