-- Retiro de productos terminados: motivo y nota para que los reportes
-- distingan ventas de pérdidas (daño / tiempo en exhibición).
-- Idempotente. Ejecutar en el SQL Editor de Supabase.
begin;

alter table public.lotes
  add column if not exists retiro_nota text;

-- Valores que usa la app en lotes.motivo_retiro:
--   'vendido'            -> venta
--   'perdida_danado'     -> pérdida (producto dañado)
--   'perdida_exhibicion' -> pérdida (superó el umbral de días en exhibición)
--   'merma'              -> pérdida histórica (también se cuenta como pérdida)
--   'transferido'        -> envío a otra sede (no cuenta ni como venta ni como pérdida)
alter table public.lotes drop constraint if exists lotes_motivo_retiro_check;
alter table public.lotes add constraint lotes_motivo_retiro_check
  check (motivo_retiro is null or motivo_retiro in
    ('vendido', 'transferido', 'merma', 'perdida_danado', 'perdida_exhibicion'));

commit;
