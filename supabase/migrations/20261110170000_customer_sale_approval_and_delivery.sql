alter table public.customer_sale_requests
  drop constraint if exists customer_sale_requests_status_check;
alter table public.customer_sale_requests
  add constraint customer_sale_requests_status_check
  check (status = any (array['pending'::text, 'contacted'::text, 'under_review'::text, 'converted'::text, 'cancelled'::text, 'approved'::text, 'rejected'::text]));

alter table public.seller_sales
  add column if not exists customer_sale_request_id uuid
    references public.customer_sale_requests(id) on delete set null;
alter table public.seller_sales
  add column if not exists requires_supervisor_delivery boolean not null default false;
create unique index if not exists seller_sales_customer_sale_request_uidx
  on public.seller_sales(customer_sale_request_id) where customer_sale_request_id is not null;
comment on column public.seller_sales.customer_sale_request_id is
  'Customer web request that generated this seller sale; prevents duplicate approval and requires supervisor delivery resolution.';

create or replace function public.begin_customer_sale_request_review(p_request_id uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_request public.customer_sale_requests%rowtype;
begin
  if not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'supervisor'
  ) or not ev_internal.staff_sales_is_verified(auth.uid()) then
    raise exception 'Solo supervisores verificados pueden iniciar la revisión' using errcode = '42501';
  end if;

  select * into v_request from public.customer_sale_requests
  where id = p_request_id for update;
  if not found then raise exception 'No se encontró la solicitud' using errcode = 'P0002'; end if;
  if not ev_internal.can_review_customer_sale_request(v_request.seller_id) then
    raise exception 'No tenés permiso para revisar esta solicitud' using errcode = '42501';
  end if;

  if v_request.status in ('pending', 'contacted') then
    update public.customer_sale_requests
    set status = 'under_review', reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
    where id = p_request_id;
    return 'under_review';
  end if;
  return v_request.status;
end;
$$;

create or replace function public.approve_customer_sale_request(p_request_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_request public.customer_sale_requests%rowtype;
  v_seller_name text;
  v_sale_id uuid;
  v_line record;
  v_product_name text;
  v_deposito integer;
  v_local integer;
  v_take_deposito integer;
  v_take_local integer;
  v_deposito_untracked boolean;
  v_local_untracked boolean;
  v_remaining integer;
  v_units integer := 0;
  v_allocations jsonb := '[]'::jsonb;
  v_order_text text;
begin
  if v_uid is null then raise exception 'Iniciá sesión para aprobar la solicitud'; end if;
  select exists (select 1 from public.admin_profiles ap where ap.user_id = v_uid and ap.role = 'admin') into v_is_admin;
  if not v_is_admin and (
    not exists (select 1 from public.admin_profiles ap where ap.user_id = v_uid and ap.role = 'supervisor')
    or not ev_internal.staff_sales_is_verified(v_uid)
  ) then
    raise exception 'Solo un administrador o supervisor verificado puede aprobar solicitudes' using errcode = '42501';
  end if;

  select * into v_request from public.customer_sale_requests
  where id = p_request_id for update;
  if not found then raise exception 'No se encontró la solicitud' using errcode = 'P0002'; end if;
  if not v_is_admin and not ev_internal.can_review_customer_sale_request(v_request.seller_id) then
    raise exception 'No tenés permiso para aprobar esta solicitud' using errcode = '42501';
  end if;
  if v_request.status = 'approved' then
    select s.id into v_sale_id from public.seller_sales s where s.customer_sale_request_id = p_request_id;
    if v_sale_id is not null then return v_sale_id; end if;
    raise exception 'La solicitud figura aprobada pero no tiene una venta asociada';
  end if;
  if v_request.status <> 'under_review' then
    raise exception 'Abrí la solicitud para iniciar la revisión antes de aprobarla';
  end if;
  if v_request.seller_id is null then
    raise exception 'Esta solicitud no está asociada a un vendedor y no se puede registrar como venta';
  end if;
  select coalesce(nullif(trim(sp.name), ''), nullif(trim(ap.display_name), ''), nullif(trim(st.name), ''))
    into v_seller_name
  from (select v_request.seller_id as user_id) owner
  left join public.seller_profiles sp on sp.user_id = owner.user_id and sp.active = true
  left join public.admin_profiles ap on ap.user_id = owner.user_id
  left join public.stock_profiles st on st.user_id = owner.user_id and st.active = true
  where sp.user_id is not null or ap.user_id is not null or st.user_id is not null;
  if not found or v_seller_name is null then raise exception 'El usuario asociado está inactivo o no existe'; end if;

  if jsonb_typeof(v_request.items) <> 'array'
     or jsonb_array_length(v_request.items) < 1
     or jsonb_array_length(v_request.items) > 3 then
    raise exception 'La solicitud debe contener entre 1 y 3 productos';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_request.items) e
    group by (e->>'product_id') having count(*) > 1
  ) then raise exception 'La solicitud repite productos; revisá los datos antes de aprobar'; end if;

  for v_line in
    select (e->>'product_id')::bigint as product_id,
           (e->>'quantity')::integer as quantity
    from jsonb_array_elements(v_request.items) e
    order by (e->>'product_id')::bigint
  loop
    if v_line.product_id is null or v_line.quantity is null or v_line.quantity < 1 or v_line.quantity > 3 then
      raise exception 'La cantidad solicitada no es válida';
    end if;
    v_units := v_units + v_line.quantity;
    if v_units > 3 then raise exception 'La solicitud supera el máximo de 3 unidades'; end if;
    select p.name into v_product_name from public.products p where p.id = v_line.product_id and p.active = true;
    if not found then raise exception 'Un producto solicitado ya no está disponible'; end if;

    select si.quantity into v_deposito from public.stock_inventory si
      where si.product_id = v_line.product_id and si.location = 'deposito' for update;
    if not found then raise exception 'No hay registro de stock para depósito'; end if;
    select si.quantity into v_local from public.stock_inventory si
      where si.product_id = v_line.product_id and si.location = 'local' for update;
    if not found then raise exception 'No hay registro de stock para local'; end if;

    v_take_deposito := 0;
    v_take_local := 0;
    v_deposito_untracked := false;
    v_local_untracked := false;
    if v_deposito is null then
      v_take_deposito := v_line.quantity;
      v_deposito_untracked := true;
    else
      v_take_deposito := least(v_deposito, v_line.quantity);
      v_remaining := v_line.quantity - v_take_deposito;
      if v_remaining > 0 then
        if v_local is null then
          v_take_local := v_remaining;
          v_local_untracked := true;
        elsif v_local >= v_remaining then
          v_take_local := v_remaining;
        else
          raise exception 'Stock insuficiente para % (disponible: %)', v_product_name, v_deposito + coalesce(v_local, 0);
        end if;
      end if;
    end if;
    v_allocations := v_allocations || jsonb_build_array(jsonb_build_object(
      'product_id', v_line.product_id, 'product_name', v_product_name,
      'quantity', v_line.quantity, 'reserved_deposito', v_take_deposito,
      'reserved_local', v_take_local, 'deposito_untracked', v_deposito_untracked,
      'local_untracked', v_local_untracked
    ));
  end loop;

  if not v_request.is_electro_variety_customer and (jsonb_array_length(v_request.items) <> 1 or v_units <> 1) then
    raise exception 'Los clientes nuevos pueden solicitar un solo producto y una unidad';
  end if;

  v_order_text := format('Solicitud %s del formulario web · %s · %s', v_request.tracking_code, v_request.full_name, v_request.phone);
  insert into public.seller_sales(customer_sale_request_id, requires_supervisor_delivery, seller_id, seller_name, order_text)
    values (p_request_id, true, v_request.seller_id, v_seller_name, v_order_text)
    returning id into v_sale_id;

  for v_line in select value from jsonb_array_elements(v_allocations) order by (value->>'product_id')::bigint
  loop
    if (v_line.value->>'reserved_deposito')::integer > 0 and not (v_line.value->>'deposito_untracked')::boolean then
      update public.stock_inventory si
      set quantity = si.quantity - (v_line.value->>'reserved_deposito')::integer, updated_by = v_uid, updated_at = now()
      where si.product_id = (v_line.value->>'product_id')::bigint and si.location = 'deposito';
    end if;
    if (v_line.value->>'reserved_local')::integer > 0 and not (v_line.value->>'local_untracked')::boolean then
      update public.stock_inventory si
      set quantity = si.quantity - (v_line.value->>'reserved_local')::integer, updated_by = v_uid, updated_at = now()
      where si.product_id = (v_line.value->>'product_id')::bigint and si.location = 'local';
    end if;
    insert into public.seller_sale_items(
      sale_id, product_id, product_name, quantity, reserved_deposito, reserved_local,
      deposito_untracked, local_untracked
    ) values (
      v_sale_id, (v_line.value->>'product_id')::bigint, v_line.value->>'product_name',
      (v_line.value->>'quantity')::integer, (v_line.value->>'reserved_deposito')::integer,
      (v_line.value->>'reserved_local')::integer, (v_line.value->>'deposito_untracked')::boolean,
      (v_line.value->>'local_untracked')::boolean
    );
    perform public.recalculate_product_stock((v_line.value->>'product_id')::bigint);
  end loop;

  update public.customer_sale_requests
  set status = 'approved', reviewed_by = v_uid, reviewed_at = now(), updated_at = now()
  where id = p_request_id;
  return v_sale_id;
end;
$$;

create or replace function public.reject_customer_sale_request(p_request_id uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_request public.customer_sale_requests%rowtype;
  v_is_admin boolean;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión para rechazar la solicitud'; end if;
  select exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'admin') into v_is_admin;
  if not v_is_admin and (
    not exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
    or not ev_internal.staff_sales_is_verified(auth.uid())
  ) then raise exception 'Solo un administrador o supervisor verificado puede rechazar solicitudes' using errcode = '42501'; end if;

  select * into v_request from public.customer_sale_requests where id = p_request_id for update;
  if not found then raise exception 'No se encontró la solicitud' using errcode = 'P0002'; end if;
  if not v_is_admin and not ev_internal.can_review_customer_sale_request(v_request.seller_id) then
    raise exception 'No tenés permiso para rechazar esta solicitud' using errcode = '42501';
  end if;
  if v_request.status = 'rejected' then return 'rejected'; end if;
  if v_request.status <> 'under_review' then raise exception 'Abrí la solicitud para iniciar la revisión antes de rechazarla'; end if;

  update public.customer_sale_requests
  set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
  where id = p_request_id;
  return 'rejected';
end;
$$;

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

  delete from storage.objects o
  where o.bucket_id = 'customer-sale-private'
    and split_part(o.name, '/', 2) = p_request_id::text;
  delete from public.customer_sale_requests where id = p_request_id;
  return true;
end;
$$;

create or replace function public.resolve_assigned_seller_sale_item(
  p_sale_id uuid, p_product_id bigint, p_delivered boolean
)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_sale public.seller_sales%rowtype;
  v_item public.seller_sale_items%rowtype;
  v_is_admin boolean;
begin
  if auth.uid() is null then raise exception 'Iniciá sesión'; end if;
  select exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'admin') into v_is_admin;
  if not v_is_admin and (
    not exists (select 1 from public.admin_profiles ap where ap.user_id = auth.uid() and ap.role = 'supervisor')
    or not ev_internal.staff_sales_is_verified(auth.uid())
  ) then raise exception 'Solo supervisores verificados pueden confirmar estas entregas' using errcode = '42501'; end if;

  select * into v_sale from public.seller_sales where id = p_sale_id for update;
  if not found then raise exception 'No se encontró este pedido'; end if;
  if not v_is_admin and coalesce(v_sale.seller_id <> auth.uid(), true) and not exists (
    select 1 from public.supervisor_sellers ss
    where ss.supervisor_id = auth.uid() and ss.seller_id = v_sale.seller_id
  ) then raise exception 'Este pedido no pertenece a un vendedor asignado a tu equipo' using errcode = '42501'; end if;
  if v_sale.expires_at <= now() then
    perform public.expire_seller_sale_items(v_sale.id);
    return 'expired';
  end if;
  select * into v_item from public.seller_sale_items
  where sale_id = p_sale_id and product_id = p_product_id for update;
  if not found then raise exception 'No se encontró el producto de este pedido'; end if;
  if v_item.status <> 'pending_delivery' then raise exception 'Este producto ya tiene un estado confirmado'; end if;
  if p_delivered then
    update public.seller_sale_items set status = 'delivered', resolved_at = now() where id = v_item.id;
  else
    perform public.restore_seller_sale_item_stock(v_item.id);
    update public.seller_sale_items set status = 'not_delivered', resolved_at = now() where id = v_item.id;
  end if;
  perform public.refresh_seller_sale_status(v_sale.id);
  return case when p_delivered then 'delivered' else 'not_delivered' end;
end;
$$;

create or replace function public.resolve_seller_sale_item(p_sale_id uuid, p_product_id bigint, p_delivered boolean)
returns text
language plpgsql security definer set search_path = 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_session_id uuid := nullif(auth.jwt()->>'session_id','')::uuid;
  v_sale public.seller_sales%rowtype;
  v_item public.seller_sale_items%rowtype;
begin
  if v_uid is null then raise exception 'Iniciá sesión'; end if;
  if not exists (select 1 from public.seller_profiles where user_id=v_uid and active=true) then
    raise exception 'La cuenta de vendedor está inactiva';
  end if;
  if not exists (select 1 from public.seller_devices where user_id=v_uid and active=true and session_id=v_session_id) then
    raise exception 'La sesión de este dispositivo ya no está autorizada';
  end if;
  select * into v_sale from public.seller_sales where id=p_sale_id and seller_id=v_uid for update;
  if not found then raise exception 'No se encontró este pedido'; end if;
  if v_sale.requires_supervisor_delivery then
    raise exception 'La entrega de una solicitud web debe confirmarla el supervisor asignado' using errcode = '42501';
  end if;
  if v_sale.expires_at <= now() then
    perform public.expire_seller_sale_items(v_sale.id);
    return 'expired';
  end if;
  select * into v_item from public.seller_sale_items
    where sale_id=p_sale_id and product_id=p_product_id for update;
  if not found then raise exception 'No se encontró el producto de este pedido'; end if;
  if v_item.status <> 'pending_delivery' then raise exception 'Este producto ya tiene un estado confirmado'; end if;
  if p_delivered then
    update public.seller_sale_items set status='delivered', resolved_at=now() where id=v_item.id;
  else
    perform public.restore_seller_sale_item_stock(v_item.id);
    update public.seller_sale_items set status='not_delivered', resolved_at=now() where id=v_item.id;
  end if;
  perform public.refresh_seller_sale_status(v_sale.id);
  return case when p_delivered then 'delivered' else 'not_delivered' end;
end;
$function$;

revoke all on function public.begin_customer_sale_request_review(uuid) from public, anon;
revoke all on function public.approve_customer_sale_request(uuid) from public, anon;
revoke all on function public.reject_customer_sale_request(uuid) from public, anon;
revoke all on function public.admin_delete_customer_sale_request(uuid) from public, anon;
revoke all on function public.resolve_assigned_seller_sale_item(uuid, bigint, boolean) from public, anon;
revoke all on function public.resolve_seller_sale_item(uuid, bigint, boolean) from public, anon;
grant execute on function public.begin_customer_sale_request_review(uuid) to authenticated;
grant execute on function public.approve_customer_sale_request(uuid) to authenticated;
grant execute on function public.reject_customer_sale_request(uuid) to authenticated;
grant execute on function public.admin_delete_customer_sale_request(uuid) to authenticated;
grant execute on function public.resolve_assigned_seller_sale_item(uuid, bigint, boolean) to authenticated;
grant execute on function public.resolve_seller_sale_item(uuid, bigint, boolean) to authenticated;

notify pgrst, 'reload schema';
