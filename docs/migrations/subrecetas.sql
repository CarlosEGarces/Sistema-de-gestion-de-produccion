-- Antojito's Cakes — Sub-recetas dentro de las fichas técnicas
-- Ejecutar una sola vez en Supabase → SQL Editor (seguro si se repite).
--
-- Semántica: una fila de detalle_receta es un ingrediente O una sub-receta.
-- Para sub-recetas, `cantidad` = veces/fracción de la receta base (0.5 = media receta)
-- y su costo = cantidad * costo_base de la sub-receta.
--
-- IMPORTANTE: al consultar detalle_receta desde recetas hay dos FKs posibles
-- (receta_id y subreceta_id). En los select de Supabase usar siempre el hint:
--   detalle_receta!detalle_receta_receta_id_fkey(...)

begin;

-- 1) Estructura ---------------------------------------------------------------
alter table detalle_receta
  add column if not exists subreceta_id uuid references recetas(id) on delete restrict;

-- Las filas de sub-receta no tienen ingrediente_id.
alter table detalle_receta alter column ingrediente_id drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'detalle_receta_item_unico') then
    alter table detalle_receta add constraint detalle_receta_item_unico
      check ((ingrediente_id is not null) <> (subreceta_id is not null));
  end if;
end $$;

create unique index if not exists detalle_receta_receta_subreceta_uniq
  on detalle_receta (receta_id, subreceta_id)
  where subreceta_id is not null;

-- 2) Costo base con ingredientes y sub-recetas -------------------------------
create or replace function recalcular_costo_base(p_receta_id uuid) returns void as $$
begin
  update recetas
  set
    costo_base = coalesce((
      select sum(
        case
          when d.ingrediente_id is not null then d.cantidad * i.costo_unitario
          else d.cantidad * coalesce(sr.costo_base, 0)
        end
      )
      from detalle_receta d
      left join ingredientes i on i.id = d.ingrediente_id
      left join recetas sr on sr.id = d.subreceta_id
      where d.receta_id = p_receta_id
    ), 0),
    updated_at = now()
  where id = p_receta_id;
end;
$$ language plpgsql security definer;

-- 3) Si cambia el costo de una sub-receta, recalcular sus recetas padres ------
create or replace function trg_subreceta_costo_recalc() returns trigger as $$
begin
  if new.costo_base is distinct from old.costo_base then
    perform recalcular_costo_base(d.receta_id)
    from (
      select distinct receta_id
      from detalle_receta
      where subreceta_id = new.id
    ) d;
  end if;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists subreceta_costo_recalc on recetas;
create trigger subreceta_costo_recalc
after update of costo_base on recetas
for each row execute function trg_subreceta_costo_recalc();

-- 4) Evitar ciclos (A usa a B, B usa a A, etc.) ------------------------------
create or replace function trg_detalle_receta_evitar_ciclo() returns trigger as $$
declare
  v_ciclo boolean;
begin
  if new.subreceta_id is null then
    return new;
  end if;

  if new.subreceta_id = new.receta_id then
    raise exception 'Una receta no puede ser sub-receta de sí misma';
  end if;

  with recursive descendientes(id, profundidad) as (
    select d.subreceta_id, 1
    from detalle_receta d
    where d.receta_id = new.subreceta_id and d.subreceta_id is not null
    union all
    select d.subreceta_id, x.profundidad + 1
    from detalle_receta d
    join descendientes x on d.receta_id = x.id
    where d.subreceta_id is not null and x.profundidad < 20
  )
  select exists (select 1 from descendientes where id = new.receta_id) into v_ciclo;

  if v_ciclo then
    raise exception 'Sub-receta inválida: generaría un ciclo entre recetas';
  end if;

  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists detalle_receta_evitar_ciclo on detalle_receta;
create trigger detalle_receta_evitar_ciclo
before insert or update of receta_id, subreceta_id on detalle_receta
for each row execute function trg_detalle_receta_evitar_ciclo();

-- 4.1) El trigger existente deriva es_empaque del ingrediente. Las filas de
--      sub-receta no tienen ingrediente, así que debe dejarlo en false (NOT NULL).
create or replace function public.sync_es_empaque_desde_ingrediente() returns trigger
language plpgsql security definer set search_path = '' as $fn$
begin
  if new.ingrediente_id is null then
    new.es_empaque := coalesce(new.es_empaque, false);
    return new;
  end if;
  select (categoria = 'empaque') into new.es_empaque
  from public.ingredientes
  where id = new.ingrediente_id;
  new.es_empaque := coalesce(new.es_empaque, false);
  return new;
end;
$fn$;

-- 5) Factor de uso por sub-sección -------------------------------------------
-- Todas las filas de una misma sección comparten este valor.
-- 1 = se usa la sub-sección completa; 0.5 = se usa la mitad.
alter table detalle_receta
  add column if not exists seccion_factor numeric(10,4) not null default 1;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'detalle_receta_seccion_factor_pos') then
    alter table detalle_receta add constraint detalle_receta_seccion_factor_pos
      check (seccion_factor > 0);
  end if;
end $$;

create or replace function recalcular_costo_base(p_receta_id uuid) returns void as $$
begin
  update recetas
  set
    costo_base = coalesce((
      select sum(
        case
          when d.ingrediente_id is not null then d.cantidad * i.costo_unitario
          else d.cantidad * coalesce(sr.costo_base, 0)
        end * coalesce(d.seccion_factor, 1)
      )
      from detalle_receta d
      left join ingredientes i on i.id = d.ingrediente_id
      left join recetas sr on sr.id = d.subreceta_id
      where d.receta_id = p_receta_id
    ), 0),
    updated_at = now()
  where id = p_receta_id;
end;
$$ language plpgsql security definer;

-- 6) Recalcular costos existentes para dejar todo consistente ----------------
do $$
declare r record;
begin
  for r in select id from recetas loop
    perform recalcular_costo_base(r.id);
  end loop;
end $$;

commit;
