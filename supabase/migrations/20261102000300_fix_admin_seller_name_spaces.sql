create or replace function public.admin_update_seller_name(p_user_id uuid, p_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  clean_name text := nullif(regexp_replace(trim(coalesce(p_name, '')), '[[:space:]]+', ' ', 'g'), '');
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede cambiar el nombre de un vendedor'
      using errcode = '42501';
  end if;
  if clean_name is null or length(clean_name) > 80 then
    raise exception 'El nombre debe tener entre 1 y 80 caracteres';
  end if;

  update public.seller_profiles set name = clean_name where user_id = p_user_id;
  if not found then
    raise exception 'No se encontró el perfil del vendedor'
      using errcode = 'P0002';
  end if;
  update public.stock_profiles set name = clean_name where user_id = p_user_id;
  update public.admin_profiles set display_name = clean_name where user_id = p_user_id;
  return clean_name;
end;
$$;

revoke all on function public.admin_update_seller_name(uuid, text) from public, anon;
grant execute on function public.admin_update_seller_name(uuid, text) to authenticated;
