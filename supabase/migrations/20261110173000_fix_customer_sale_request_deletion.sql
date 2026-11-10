create or replace function public.admin_delete_customer_sale_request(p_request_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'admin') then
    raise exception 'Solo el administrador puede eliminar solicitudes' using errcode = '42501';
  end if;
  if not exists (select 1 from public.customer_sale_requests where id = p_request_id) then
    raise exception 'No se encontró la solicitud' using errcode = 'P0002';
  end if;

  -- Storage files are removed separately through the Storage API by the
  -- authenticated delete-customer-sale-request Edge Function.
  delete from public.customer_sale_requests where id = p_request_id;
  return true;
end;
$$;

drop policy if exists "Admins can delete customer sale request documents" on storage.objects;
create policy "Admins can delete customer sale request documents"
  on storage.objects for delete to authenticated
  using (bucket_id = 'customer-sale-private' and (select public.is_admin()));

notify pgrst, 'reload schema';
