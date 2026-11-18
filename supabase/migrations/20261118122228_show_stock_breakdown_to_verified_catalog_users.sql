-- Stock quantities are exposed to verified staff through RLS. Existing
-- administrator, stock-manager, and stock-account policies remain in place.
create policy "Verified staff view stock inventory"
on public.stock_inventory for select to authenticated
using (
  exists (
    select 1
    from public.staff_sales_verifications verification
    where verification.user_id = (select auth.uid())
      and verification.is_verified = true
  )
);
