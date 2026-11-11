create or replace function public.admin_create_ranking_sale(
  p_seller_id uuid,
  p_customer_type text,
  p_product_id bigint,
  p_payment_frequency text,
  p_locality text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := auth.uid();
  v_seller_name text;
  v_product_name text;
  v_q_count integer;
  v_q_price text;
  v_m_count integer;
  v_m_price text;
  v_installment_count integer;
  v_installment_price text;
  v_frequency_label text;
  v_customer_label text;
  v_locality text := nullif(btrim(p_locality), '');
  v_sale_id uuid;
  v_order_text text;
begin
  if v_admin_id is null or not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = v_admin_id and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede cargar ventas al ranking' using errcode = '42501';
  end if;
  if p_seller_id is null then raise exception 'Elegí un usuario'; end if;
  if p_customer_type is null or p_customer_type not in ('new','existing') then
    raise exception 'Elegí si la venta fue a un cliente nuevo o a un cliente de Electro Variety';
  end if;
  if p_payment_frequency is null or p_payment_frequency not in ('quincenal','mensual') then
    raise exception 'Elegí modalidad quincenal o mensual';
  end if;
  if v_locality is null or char_length(v_locality) > 120 then
    raise exception 'Ingresá una localidad de hasta 120 caracteres';
  end if;

  select coalesce(nullif(btrim(sp.name),''),nullif(btrim(ap.display_name),''),nullif(btrim(st.name),''),'Usuario')
  into v_seller_name
  from (select p_seller_id as user_id) selected_user
  left join public.seller_profiles sp on sp.user_id=selected_user.user_id
  left join public.admin_profiles ap on ap.user_id=selected_user.user_id
  left join public.stock_profiles st on st.user_id=selected_user.user_id
  where sp.user_id is not null or ap.user_id is not null or st.user_id is not null;
  if not found then raise exception 'No se encontró un usuario del catálogo válido'; end if;

  select p.name,p.q_count,p.q_price,p.m_count,p.m_price
  into v_product_name,v_q_count,v_q_price,v_m_count,v_m_price
  from public.products p where p.id=p_product_id;
  if not found then raise exception 'No existe el producto elegido'; end if;

  if p_payment_frequency='quincenal' then
    v_installment_count:=v_q_count; v_installment_price:=v_q_price; v_frequency_label:='quincenales';
  else
    v_installment_count:=v_m_count; v_installment_price:=v_m_price; v_frequency_label:='mensuales';
  end if;
  if v_installment_count is null or v_installment_count<1 or nullif(btrim(v_installment_price),'') is null then
    raise exception 'El producto no tiene una modalidad de cuotas válida';
  end if;

  v_customer_label:=case p_customer_type when 'new' then 'Cliente nuevo' else 'Cliente de Electro Variety' end;
  v_order_text:=format('Venta cargada por administración al ranking mensual. %s. Producto: %s. Modalidad: %s cuotas %s de %s. Localidad: %s.',
    v_customer_label,v_product_name,v_installment_count,v_frequency_label,v_installment_price,v_locality);

  insert into public.seller_sales(
    seller_id,seller_name,order_text,status,expires_at,updated_at,customer_type,locality,requires_supervisor_delivery
  ) values(
    p_seller_id,v_seller_name,v_order_text,'delivered',now(),now(),p_customer_type,v_locality,false
  ) returning id into v_sale_id;

  insert into public.seller_sale_items(
    sale_id,product_id,product_name,quantity,reserved_deposito,reserved_local,status,resolved_at,manual_entry
  ) values(
    v_sale_id,p_product_id,v_product_name,1,0,0,'delivered',now(),true
  );
  return v_sale_id;
end;
$function$;

revoke all on function public.admin_create_ranking_sale(uuid,text,bigint,text,text) from public,anon;
grant execute on function public.admin_create_ranking_sale(uuid,text,bigint,text,text) to authenticated;
