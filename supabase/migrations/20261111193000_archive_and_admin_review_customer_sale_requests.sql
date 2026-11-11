alter table public.customer_sale_requests
  add column if not exists archived_at timestamptz;

create or replace function public.begin_customer_sale_request_review(p_request_id uuid)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_request public.customer_sale_requests%rowtype;
  v_uid uuid := auth.uid();
  v_is_admin boolean;
begin
  if v_uid is null then
    raise exception 'Iniciá sesión para revisar la solicitud';
  end if;

  select exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = v_uid and ap.role = 'admin'
  ) into v_is_admin;

  if not v_is_admin and (
    not exists (
      select 1 from public.admin_profiles ap
      where ap.user_id = v_uid and ap.role = 'supervisor'
    ) or not ev_internal.staff_sales_is_verified(v_uid)
  ) then
    raise exception 'Solo un administrador o supervisor verificado puede iniciar la revisión' using errcode = '42501';
  end if;

  select * into v_request from public.customer_sale_requests
  where id = p_request_id for update;
  if not found then
    raise exception 'No se encontró la solicitud' using errcode = 'P0002';
  end if;

  if not v_is_admin and not ev_internal.can_review_customer_sale_request(v_request.seller_id) then
    raise exception 'No tenés permiso para revisar esta solicitud' using errcode = '42501';
  end if;

  if v_request.status in ('pending', 'contacted') then
    update public.customer_sale_requests
    set status = 'under_review', reviewed_by = v_uid, reviewed_at = now(), updated_at = now()
    where id = p_request_id;
    return 'under_review';
  end if;
  return v_request.status;
end;
$function$;

create or replace function public.admin_set_customer_sale_request_archived(
  p_request_id uuid,
  p_archived boolean
)
returns boolean
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not exists (
    select 1 from public.admin_profiles ap
    where ap.user_id = auth.uid() and ap.role = 'admin'
  ) then
    raise exception 'Solo el administrador puede archivar solicitudes' using errcode = '42501';
  end if;

  update public.customer_sale_requests
  set archived_at = case
        when p_archived then coalesce(archived_at, now())
        else null
      end,
      updated_at = now()
  where id = p_request_id;

  if not found then
    raise exception 'No se encontró la solicitud' using errcode = 'P0002';
  end if;
  return true;
end;
$function$;

revoke all on function public.admin_set_customer_sale_request_archived(uuid, boolean) from public, anon;
grant execute on function public.admin_set_customer_sale_request_archived(uuid, boolean) to authenticated;

comment on column public.customer_sale_requests.archived_at is
  'Momento en que administración archivó la solicitud; no reemplaza el estado de aprobación.';
