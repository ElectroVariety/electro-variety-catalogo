-- Keep seller sale history when a catalog product is deleted. The product
-- name is already snapshotted in seller_sale_items.product_name.
alter table public.seller_sale_items
  alter column product_id drop not null;

alter table public.seller_sale_items
  drop constraint if exists seller_sale_items_product_id_fkey;

alter table public.seller_sale_items
  add constraint seller_sale_items_product_id_fkey
  foreign key (product_id) references public.products(id) on delete set null;

create or replace function public.admin_delete_product(p_product_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede eliminar productos' using errcode = '42501';
  end if;

  if p_product_id is null then
    raise exception 'Falta el producto que se quiere eliminar' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.seller_sale_items i
    where i.product_id = p_product_id
      and i.status = 'pending_delivery'
  ) then
    raise exception 'No se puede eliminar este producto porque tiene pedidos pendientes de entrega. Resolvé o cancelá esos pedidos y volvé a intentarlo.'
      using errcode = '23503';
  end if;

  delete from public.products p where p.id = p_product_id;
  if not found then
    raise exception 'No se encontró el producto' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_delete_product(bigint) from public, anon;
grant execute on function public.admin_delete_product(bigint) to authenticated;

notify pgrst, 'reload schema';
