create or replace function public.recalculate_product_stock(p_product_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  d integer;
  l integer;
  d_unknown boolean;
  l_unknown boolean;
  total integer;
  session_id uuid := nullif(auth.jwt()->>'session_id', '')::uuid;
begin
  if auth.uid() is null or (
    not public.is_admin()
    and not exists (
      select 1
      from public.seller_profiles s
      join public.seller_devices dvc on dvc.user_id = s.user_id
      where s.user_id = auth.uid()
        and s.active = true
        and dvc.active = true
        and dvc.session_id = session_id
    )
  ) then
    raise exception 'No autorizado' using errcode = '42501';
  end if;

  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception 'El producto % no existe', p_product_id;
  end if;

  select quantity is null, coalesce(quantity, 0)
    into d_unknown, d
  from public.stock_inventory
  where product_id = p_product_id and location = 'deposito';
  if not found then d_unknown := true; d := 0; end if;

  select quantity is null, coalesce(quantity, 0)
    into l_unknown, l
  from public.stock_inventory
  where product_id = p_product_id and location = 'local';
  if not found then l_unknown := true; l := 0; end if;

  if d_unknown or l_unknown then
    update public.products set stock = -1, updated_at = now() where id = p_product_id;
  else
    total := d + l;
    update public.products set stock = total, updated_at = now() where id = p_product_id;
  end if;
end;
$$;

revoke all on function public.recalculate_product_stock(bigint) from public, anon, authenticated;
grant execute on function public.recalculate_product_stock(bigint) to authenticated;

notify pgrst, 'reload schema';
