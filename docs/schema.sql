-- Antojito's Cakes — Gestión de Producción
-- Módulo 1: Gestión de Recetas
-- Ejecutar completo en Supabase → SQL Editor (una sola vez).

create extension if not exists pgcrypto; -- para gen_random_uuid()

create type rol_usuario as enum ('administrador', 'produccion', 'inventario');

-- Perfiles: extiende auth.users con nombre y rol
create table perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  rol rol_usuario not null default 'produccion',
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create table ingredientes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  unidad_medida text not null, -- 'g' | 'kg' | 'ml' | 'l' | 'unidad'
  costo_unitario numeric(10,4) not null check (costo_unitario >= 0),
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table recetas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  categoria text not null check (categoria in ('racion','torta_entera','bebida')),
  porciones integer not null default 1 check (porciones > 0),
  descripcion text,
  costo_base numeric(10,4) not null default 0, -- se recalcula solo, ver trigger
  activo boolean not null default true,
  created_by uuid references perfiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table detalle_receta (
  id uuid primary key default gen_random_uuid(),
  receta_id uuid not null references recetas(id) on delete cascade,
  ingrediente_id uuid not null references ingredientes(id) on delete restrict,
  cantidad numeric(10,4) not null check (cantidad > 0),
  created_at timestamptz not null default now(),
  unique (receta_id, ingrediente_id) -- evita ingrediente duplicado en la misma receta
);

-- Recalcula costo_base de una receta a partir de su detalle
create or replace function recalcular_costo_base(p_receta_id uuid) returns void as $$
begin
  update recetas set
    costo_base = coalesce((
      select sum(d.cantidad * i.costo_unitario)
      from detalle_receta d join ingredientes i on i.id = d.ingrediente_id
      where d.receta_id = p_receta_id
    ), 0),
    updated_at = now()
  where id = p_receta_id;
end;
$$ language plpgsql security definer;

create or replace function trg_detalle_receta_recalc() returns trigger as $$
begin
  perform recalcular_costo_base(coalesce(new.receta_id, old.receta_id));
  return null;
end;
$$ language plpgsql;

create trigger detalle_receta_recalc
after insert or update or delete on detalle_receta
for each row execute function trg_detalle_receta_recalc();

-- Si cambia el costo de un ingrediente, recalcula todas las recetas que lo usan
create or replace function trg_ingrediente_recalc() returns trigger as $$
begin
  if new.costo_unitario is distinct from old.costo_unitario then
    perform recalcular_costo_base(d.receta_id)
    from (select distinct receta_id from detalle_receta where ingrediente_id = new.id) d;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger ingrediente_recalc
after update on ingredientes
for each row execute function trg_ingrediente_recalc();

-- RLS
alter table perfiles enable row level security;
alter table ingredientes enable row level security;
alter table recetas enable row level security;
alter table detalle_receta enable row level security;

create or replace function mi_rol() returns rol_usuario as $$
  select rol from perfiles where id = auth.uid();
$$ language sql stable security definer;

create policy "ver propio perfil" on perfiles for select using (id = auth.uid());
create policy "leer catalogos" on ingredientes for select using (auth.uid() is not null);
create policy "leer recetas" on recetas for select using (auth.uid() is not null);
create policy "leer detalle" on detalle_receta for select using (auth.uid() is not null);

create policy "escribir ingredientes" on ingredientes for all
  using (mi_rol() in ('administrador','produccion'))
  with check (mi_rol() in ('administrador','produccion'));
create policy "escribir recetas" on recetas for all
  using (mi_rol() in ('administrador','produccion'))
  with check (mi_rol() in ('administrador','produccion'));
create policy "escribir detalle" on detalle_receta for all
  using (mi_rol() in ('administrador','produccion'))
  with check (mi_rol() in ('administrador','produccion'));

-- ─────────────────────────────────────────────────────────────
-- Después de correr este script:
-- 1. Ir a Authentication → Users → crear un usuario (email + password).
-- 2. Copiar su UUID y ejecutar, por ejemplo:
--
--    insert into perfiles (id, nombre, rol)
--    values ('UUID-DEL-USUARIO', 'Nombre Apellido', 'administrador');
--
-- 3. Repetir para cada empleado con el rol que corresponda:
--    'administrador' | 'produccion' | 'inventario'
-- ─────────────────────────────────────────────────────────────
