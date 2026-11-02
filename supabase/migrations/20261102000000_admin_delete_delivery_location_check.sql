create or replace function public.admin_delete_delivery_location_check(p_check_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede borrar consultas de cobertura'
      using errcode = '42501';
  end if;

  delete from public.client_delivery_location_checks
  where id = p_check_id
  returning id into deleted_id;

  if deleted_id is null then
    raise exception 'No se encontró la consulta de cobertura'
      using errcode = 'P0002';
  end if;

  return deleted_id;
end;
$$;

revoke all on function public.admin_delete_delivery_location_check(uuid) from public, anon;
grant execute on function public.admin_delete_delivery_location_check(uuid) to authenticated;
notify pgrst, 'reload schema';
