-- Producción: desconto de ingredientes al confirmar + incidencias de carga
-- Idempotente. Ejecutar en el SQL Editor de Supabase.
begin;

-- 0) Fix preexistente: registrar_log() guarda IDs de tablas con id bigint
--    (movimientos_inventario, alertas) en logs.registro_id, que era uuid.
--    Sin esto, CUALQUIER movimiento de inventario fallaba antes de llegar al
--    trigger que recalcula stock_actual. No hay FK sobre esa columna.
alter table public.logs
  alter column registro_id type text using registro_id::text;

-- 0.1) mi_rol() se usa desde las funciones nuevas con search_path = ''.
--      Calificamos la tabla para que siga funcionando en ese contexto.
create or replace function public.mi_rol() returns public.rol_usuario
language sql stable security definer set search_path = '' as $$
  select rol from public.perfiles where id = auth.uid();
$$;

-- 1) Motivo / nota de por qué un producto NO se cargó a inventario ------------
alter table public.plan_items
  add column if not exists incidencia_tipo text,
  add column if not exists incidencia_nota text,
  add column if not exists incidencia_at timestamptz,
  add column if not exists incidencia_por uuid references public.perfiles(id) on delete set null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'plan_items_incidencia_tipo_check') then
    alter table public.plan_items add constraint plan_items_incidencia_tipo_check
      check (incidencia_tipo is null or incidencia_tipo in ('cancelado', 'perdida'));
  end if;
end $$;

-- Solo el administrador puede borrar la nota (producción sí puede crearla).
create or replace function public.trg_proteger_incidencia_plan_item() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if (old.incidencia_tipo is not null and new.incidencia_tipo is null)
     or (old.incidencia_nota is not null and new.incidencia_nota is null) then
    if public.mi_rol() <> 'administrador' then
      raise exception 'Solo el administrador puede borrar la nota de incidencia';
    end if;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_proteger_incidencia_plan_item on public.plan_items;
create trigger trg_proteger_incidencia_plan_item
before update on public.plan_items
for each row execute function public.trg_proteger_incidencia_plan_item();

-- 1.1) Permitir el origen 'produccion' en los movimientos de inventario.
alter table public.movimientos_inventario drop constraint if exists movimientos_inventario_origen_check;
alter table public.movimientos_inventario add constraint movimientos_inventario_origen_check
  check (origen in ('manual', 'masivo', 'reversion', 'produccion'));

-- 2) Confirmar un ítem: lote + salidas de inventario + marca de cargado -------
-- Las salidas disparan trg_recalc_stock, que actualiza ingredientes.stock_actual.
-- Incluye empaque y expande sub-recetas (si quedaron de la migración anterior).
create or replace function public.confirmar_item_produccion(p_item_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $fn$
declare
  v_item public.plan_items%rowtype;
  v_lote_id uuid;
  v_cantidad integer;
  v_nombre text;
begin
  if not (public.mi_rol() = any (array['administrador'::public.rol_usuario, 'produccion'::public.rol_usuario])) then
    raise exception 'No tienes permiso para confirmar producción';
  end if;

  select * into v_item from public.plan_items where id = p_item_id for update;
  if not found then
    raise exception 'Ítem de plan no encontrado';
  end if;
  if v_item.cargado_a_inventario then
    raise exception 'Este ítem ya fue cargado a inventario';
  end if;
  if v_item.incidencia_tipo is not null then
    raise exception 'Este ítem tiene una incidencia registrada; bórrala antes de cargarlo';
  end if;

  v_cantidad := coalesce(v_item.cantidad_producida, v_item.cantidad_planificada);
  if v_cantidad is null or v_cantidad <= 0 then
    raise exception 'La cantidad a producir debe ser mayor a 0';
  end if;

  select nombre into v_nombre from public.recetas where id = v_item.receta_id;

  insert into public.lotes (receta_id, cantidad, sede, fecha_ingreso, created_by)
  values (v_item.receta_id, v_cantidad, v_item.sede, current_date, auth.uid())
  returning id into v_lote_id;

  with recursive consumo(receta_id, multiplicador, profundidad) as (
    select v_item.receta_id, 1::numeric, 0
    union all
    select d.subreceta_id,
           c.multiplicador * d.cantidad * coalesce(d.seccion_factor, 1),
           c.profundidad + 1
    from public.detalle_receta d
    join consumo c on c.receta_id = d.receta_id
    where d.subreceta_id is not null and c.profundidad < 20
  ), movimientos as (
    select d.ingrediente_id,
           sum(d.cantidad * coalesce(d.seccion_factor, 1) * c.multiplicador * v_cantidad) as cantidad
    from consumo c
    join public.detalle_receta d on d.receta_id = c.receta_id and d.ingrediente_id is not null
    group by d.ingrediente_id
  )
  insert into public.movimientos_inventario (ingrediente_id, tipo, cantidad, motivo, origen, created_by)
  select m.ingrediente_id,
         'salida',
         m.cantidad,
         'Producción: ' || coalesce(v_nombre, 'receta') || ' ×' || v_cantidad,
         'produccion',
         auth.uid()
  from movimientos m
  where m.cantidad > 0;

  update public.plan_items
  set cargado_a_inventario = true, lote_id = v_lote_id
  where id = p_item_id;

  return v_lote_id;
end;
$fn$;

-- 3) Confirmar todos los pendientes de un plan (todo o nada) -----------------
create or replace function public.confirmar_plan_produccion(p_plan_id uuid)
returns integer language plpgsql security definer set search_path = '' as $fn$
declare
  v_item record;
  v_total integer := 0;
begin
  if not (public.mi_rol() = any (array['administrador'::public.rol_usuario, 'produccion'::public.rol_usuario])) then
    raise exception 'No tienes permiso para confirmar producción';
  end if;

  for v_item in
    select id
    from public.plan_items
    where plan_id = p_plan_id
      and not cargado_a_inventario
      and incidencia_tipo is null
      and coalesce(cantidad_producida, cantidad_planificada) > 0
    order by created_at
    for update skip locked
  loop
    perform public.confirmar_item_produccion(v_item.id);
    v_total := v_total + 1;
  end loop;

  return v_total;
end;
$fn$;

-- 4) Registrar / borrar la nota de no carga ----------------------------------
create or replace function public.registrar_incidencia_item(
  p_item_id uuid, p_tipo text, p_nota text
) returns void language plpgsql security definer set search_path = '' as $fn$
declare
  v_nota text := btrim(coalesce(p_nota, ''));
  v_item public.plan_items%rowtype;
begin
  if not (public.mi_rol() = any (array['administrador'::public.rol_usuario, 'produccion'::public.rol_usuario])) then
    raise exception 'No tienes permiso para registrar incidencias';
  end if;
  if p_tipo not in ('cancelado', 'perdida') then
    raise exception 'El motivo debe ser cancelado o perdida';
  end if;
  if v_nota = '' then
    raise exception 'Escribe una nota explicando el motivo';
  end if;

  select * into v_item from public.plan_items where id = p_item_id for update;
  if not found then
    raise exception 'Ítem de plan no encontrado';
  end if;
  if v_item.cargado_a_inventario then
    raise exception 'No se puede marcar un producto que ya está cargado a inventario';
  end if;

  update public.plan_items
  set incidencia_tipo = p_tipo,
      incidencia_nota = v_nota,
      incidencia_at = now(),
      incidencia_por = auth.uid()
  where id = p_item_id;
end;
$fn$;

create or replace function public.borrar_incidencia_item(p_item_id uuid)
returns void language plpgsql security definer set search_path = '' as $fn$
begin
  if public.mi_rol() <> 'administrador' then
    raise exception 'Solo el administrador puede borrar la nota';
  end if;

  update public.plan_items
  set incidencia_tipo = null,
      incidencia_nota = null,
      incidencia_at = null,
      incidencia_por = null
  where id = p_item_id;
end;
$fn$;

revoke all on function public.confirmar_item_produccion(uuid) from public;
revoke all on function public.confirmar_plan_produccion(uuid) from public;
revoke all on function public.registrar_incidencia_item(uuid, text, text) from public;
revoke all on function public.borrar_incidencia_item(uuid) from public;
grant execute on function public.confirmar_item_produccion(uuid) to authenticated;
grant execute on function public.confirmar_plan_produccion(uuid) to authenticated;
grant execute on function public.registrar_incidencia_item(uuid, text, text) to authenticated;
grant execute on function public.borrar_incidencia_item(uuid) to authenticated;

commit;
