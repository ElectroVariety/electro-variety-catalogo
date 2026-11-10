create or replace function ev_internal.can_read_staff_profile_photo(p_owner_id text)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select auth.uid() is not null and (
    p_owner_id=(select auth.uid())::text
    or (select public.is_admin())
    or exists (
      select 1
      from public.supervisor_sellers ss
      join public.admin_profiles ap on ap.user_id=ss.supervisor_id
      where ss.supervisor_id=(select auth.uid())
        and ap.role='supervisor'
        and ev_internal.staff_sales_is_verified((select auth.uid()))
        and ss.seller_id::text=p_owner_id
    )
  );
$$;

revoke all on function ev_internal.can_read_staff_profile_photo(text) from public, anon;
grant execute on function ev_internal.can_read_staff_profile_photo(text) to authenticated;

drop policy if exists "Staff can read authorized profile photos" on storage.objects;
create policy "Staff can read authorized profile photos" on storage.objects
for select to authenticated
using (
  bucket_id='staff-profile-photos'
  and ev_internal.can_read_staff_profile_photo((storage.foldername(name))[1])
);

notify pgrst,'reload schema';

