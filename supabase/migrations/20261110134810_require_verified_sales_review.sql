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
      and ev_internal.staff_sales_is_verified(auth.uid())
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
comment on function ev_internal.can_review_customer_sale_request(uuid) is
  'Admins can review all purchase requests; supervisors must have a verification badge and may review their own or assigned sellers requests.';
