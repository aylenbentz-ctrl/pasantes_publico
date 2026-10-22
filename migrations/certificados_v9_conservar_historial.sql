-- MIGRACION SEGURA: certificados anteriores -> version 9
-- Ejecutar UNA VEZ (se puede repetir) en Supabase > SQL Editor,
-- conectado al mismo proyecto usado por el sitio.
-- No elimina certificados, fotos, PDFs ni tablas.
-- El campo "visto" anterior solo significa visto, NO aprobado;
-- por eso los certificados heredados quedan "pendiente".
--
-- MUY IMPORTANTE: hacer respaldo de public.certificados antes de correrla.
-- Esta migracion no se ejecuta al fusionar un Pull Request.

BEGIN;

DO $guard$
BEGIN
  IF to_regclass('public.certificados') IS NULL THEN
    RAISE EXCEPTION 'No existe public.certificados. Revisar el proyecto de Supabase.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'certificados' AND column_name = 'nombre'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'certificados' AND column_name = 'dia'
  ) THEN
    RAISE EXCEPTION 'Esta migracion solo corresponde a certificados con columnas nombre y dia.';
  END IF;
END
$guard$;

-- Agregar columnas nuevas SIN reemplazar los valores anteriores.
ALTER TABLE public.certificados
  ADD COLUMN IF NOT EXISTS pasante text,
  ADD COLUMN IF NOT EXISTS desde date,
  ADD COLUMN IF NOT EXISTS hasta date,
  ADD COLUMN IF NOT EXISTS motivo text,
  ADD COLUMN IF NOT EXISTS detalle text,
  ADD COLUMN IF NOT EXISTS estado text,
  ADD COLUMN IF NOT EXISTS motivo_rechazo text,
  ADD COLUMN IF NOT EXISTS creado_en timestamptz,
  ADD COLUMN IF NOT EXISTS resuelto_en timestamptz;

-- Asegurar que los datos historicos permanezcan legibles.
-- NOTA: No sobrescribe datos ya migrados.
UPDATE public.certificados
SET pasante = coalesce(nullif(btrim(pasante), ''), nombre),
    desde = coalesce(desde, dia),
    hasta = coalesce(hasta, dia),
    motivo = coalesce(nullif(btrim(motivo), ''), 'Otro'),
    detalle = coalesce(detalle, nota),
    estado = coalesce(estado, 'pendiente'),
    creado_en = coalesce(creado_en, subido_en, now())
WHERE pasante IS NULL OR btrim(pasante) = ''
   OR desde IS NULL OR hasta IS NULL OR motivo IS NULL OR btrim(motivo) = ''
   OR estado IS NULL OR creado_en IS NULL;

-- Nuevos certificados usan columnas v9; se conservan las viejas.
ALTER TABLE public.certificados
  ALTER COLUMN nombre DROP NOT NULL,
  ALTER COLUMN dia DROP NOT NULL,
  ALTER COLUMN pasante SET NOT NULL,
  ALTER COLUMN desde SET NOT NULL,
  ALTER COLUMN hasta SET NOT NULL,
  ALTER COLUMN motivo SET NOT NULL,
  ALTER COLUMN estado SET DEFAULT 'pendiente',
  ALTER COLUMN estado SET NOT NULL,
  ALTER COLUMN creado_en SET DEFAULT now(),
  ALTER COLUMN creado_en SET NOT NULL;

-- Estas restricciones validan NUEVOS estados sin borrar registros.
DO $constraints$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'certificados_v9_estado_check' AND conrelid = 'public.certificados'::regclass) THEN
    ALTER TABLE public.certificados ADD CONSTRAINT certificados_v9_estado_check
      CHECK (estado IN ('pendiente', 'aprobado', 'rechazado'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'certificados_v9_periodo_check' AND conrelid = 'public.certificados'::regclass) THEN
    ALTER TABLE public.certificados ADD CONSTRAINT certificados_v9_periodo_check
      CHECK (hasta >= desde);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'certificados_v9_rechazo_check' AND conrelid = 'public.certificados'::regclass) THEN
    ALTER TABLE public.certificados ADD CONSTRAINT certificados_v9_rechazo_check
      CHECK (estado <> 'rechazado' OR coalesce(trim(motivo_rechazo),'') <> '');
  END IF;
END
$constraints$;

-- Reutilizar las politicas RLS de RRHH. Las nuevas del esquema v9
-- son equivalentes y requieren usuario autenticado autorizado.

-- ------------------------------------------------------------
-- Editar pasante (solo RRHH). Si cambia el nombre, el historial de
-- fichadas y los certificados pasan al nombre nuevo en la misma operación.
-- p_pin vacío = no cambia el PIN.
-- ------------------------------------------------------------
create or replace function editar_pasante(
  p_id text, p_nombre text, p_pin text, p_area text, p_horario text,
  p_inicio date, p_fin date, p_sedes_ids bigint[]
) returns json
language plpgsql security definer set search_path = public
as $$
declare
  v pasantes%rowtype;
  v_nuevo text := trim(coalesce(p_nombre, ''));
begin
  if not soy_rrhh() then return json_build_object('ok', false, 'error', 'no_autorizado'); end if;
  select * into v from pasantes where id = p_id;
  if not found then return json_build_object('ok', false, 'error', 'pasante_no_encontrado'); end if;
  if v_nuevo = '' then return json_build_object('ok', false, 'error', 'nombre_vacio'); end if;
  if coalesce(p_pin, '') <> '' and p_pin !~ '^[0-9]{4,6}$' then return json_build_object('ok', false, 'error', 'pin_invalido'); end if;
  if p_inicio is not null and p_fin is not null and p_fin < p_inicio then return json_build_object('ok', false, 'error', 'fechas_invalidas'); end if;
  if coalesce(array_length(p_sedes_ids, 1), 0) = 0 then return json_build_object('ok', false, 'error', 'sin_sede'); end if;
  if exists (select 1 from pasantes where id <> p_id and lower(trim(nombre)) = lower(v_nuevo)) then
    return json_build_object('ok', false, 'error', 'nombre_duplicado');
  end if;

  update pasantes set nombre = v_nuevo,
         pin = case when coalesce(p_pin, '') = '' then pin else p_pin end,
         area = p_area, horario = p_horario, fecha_inicio = p_inicio, fecha_fin = p_fin, sedes_ids = p_sedes_ids
   where id = p_id;

  if v.nombre is distinct from v_nuevo then
    update fichajes set nombre = v_nuevo where nombre = v.nombre;
    update certificados set pasante = v_nuevo where pasante = v.nombre;
  end if;
  return json_build_object('ok', true, 'nombre', v_nuevo);
end;
$$;
grant execute on function editar_pasante(text, text, text, text, text, date, date, bigint[]) to authenticated;

-- ------------------------------------------------------------
-- Certificados (justificativos de falta). El pasante sube una foto/PDF
-- y RRHH la aprueba o la rechaza (con motivo). El archivo se guarda
-- dentro de la tabla (data URL); la app achica las fotos antes de subir.
-- ------------------------------------------------------------
create table if not exists certificados (
  id bigint generated always as identity primary key,
  pasante text not null,
  desde date not null,
  hasta date not null,
  motivo text not null,
  detalle text,
  archivo_nombre text,
  archivo_tipo text,
  archivo text not null,
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado')),
  motivo_rechazo text,
  creado_en timestamptz not null default now(),
  resuelto_en timestamptz,
  check (hasta >= desde),
  check (estado <> 'rechazado' or coalesce(trim(motivo_rechazo), '') <> '')
);
create index if not exists certificados_estado_idx on certificados (estado, creado_en desc);
create index if not exists certificados_pasante_idx on certificados (pasante);
alter table certificados enable row level security;

drop policy if exists "rrhh_cert_select" on certificados;
drop policy if exists "rrhh_cert_update" on certificados;
drop policy if exists "rrhh_cert_delete" on certificados;
create policy "rrhh_cert_select" on certificados for select using (soy_rrhh());
create policy "rrhh_cert_update" on certificados for update using (soy_rrhh()) with check (soy_rrhh());
create policy "rrhh_cert_delete" on certificados for delete using (soy_rrhh());
-- (sin policy de insert: los pasantes suben solo con subir_certificado)

create or replace function subir_certificado(
  p_nombre text, p_pin text, p_desde date, p_hasta date, p_motivo text,
  p_detalle text, p_archivo_nombre text, p_archivo text
) returns json
language plpgsql security definer set search_path = public
as $$
declare v pasantes%rowtype; v_id bigint;
begin
  select * into v from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found or v.pin is distinct from p_pin then return json_build_object('ok', false, 'error', 'credenciales'); end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde then return json_build_object('ok', false, 'error', 'fechas_invalidas'); end if;
  if p_archivo is null or p_archivo !~ '^data:(image/(jpeg|png|webp)|application/pdf);base64,' then
    return json_build_object('ok', false, 'error', 'archivo_invalido');
  end if;
  if length(p_archivo) > 2000000 then return json_build_object('ok', false, 'error', 'archivo_grande'); end if;
  if (select count(*) from certificados where pasante = v.nombre) >= 30 then
    return json_build_object('ok', false, 'error', 'demasiados_certificados');
  end if;
  insert into certificados(pasante, desde, hasta, motivo, detalle, archivo_nombre, archivo_tipo, archivo)
  values (v.nombre, p_desde, p_hasta, left(coalesce(nullif(trim(p_motivo), ''), 'Otro'), 60), left(coalesce(p_detalle, ''), 200),
          left(coalesce(p_archivo_nombre, ''), 120), substring(p_archivo from 6 for position(';' in p_archivo) - 6), p_archivo)
  returning id into v_id;
  return json_build_object('ok', true, 'id', v_id);
end;
$$;
grant execute on function subir_certificado(text, text, date, date, text, text, text, text) to anon, authenticated;

create or replace function mis_certificados(p_nombre text, p_pin text)
returns json
language plpgsql security definer set search_path = public
as $$
declare v pasantes%rowtype;
begin
  select * into v from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found or v.pin is distinct from p_pin then return json_build_object('ok', false, 'error', 'credenciales'); end if;
  return json_build_object('ok', true, 'certificados', coalesce((
    select json_agg(json_build_object('id', c.id, 'desde', c.desde, 'hasta', c.hasta, 'motivo', c.motivo, 'detalle', c.detalle,
                                      'archivo_nombre', c.archivo_nombre, 'estado', c.estado, 'motivo_rechazo', c.motivo_rechazo,
                                      'creado_en', c.creado_en, 'resuelto_en', c.resuelto_en) order by c.creado_en desc)
      from certificados c where c.pasante = v.nombre
  ), '[]'::json));
end;
$$;
grant execute on function mis_certificados(text, text) to anon, authenticated;

create or replace function mi_certificado_archivo(p_nombre text, p_pin text, p_id bigint)
returns json
language plpgsql security definer set search_path = public
as $$
declare v pasantes%rowtype; c certificados%rowtype;
begin
  select * into v from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found or v.pin is distinct from p_pin then return json_build_object('ok', false, 'error', 'credenciales'); end if;
  select * into c from certificados where id = p_id and pasante = v.nombre;
  if not found then return json_build_object('ok', false, 'error', 'no_encontrado'); end if;
  return json_build_object('ok', true, 'archivo', c.archivo, 'archivo_nombre', c.archivo_nombre);
end;
$$;
grant execute on function mi_certificado_archivo(text, text, bigint) to anon, authenticated;

-- El pasante puede borrar sus certificados salvo los ya aprobados.
create or replace function borrar_certificado(p_nombre text, p_pin text, p_id bigint)
returns json
language plpgsql security definer set search_path = public
as $$
declare v pasantes%rowtype; c certificados%rowtype;
begin
  select * into v from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found or v.pin is distinct from p_pin then return json_build_object('ok', false, 'error', 'credenciales'); end if;
  select * into c from certificados where id = p_id and pasante = v.nombre;
  if not found then return json_build_object('ok', false, 'error', 'no_encontrado'); end if;
  if c.estado = 'aprobado' then return json_build_object('ok', false, 'error', 'aprobado_no_se_borra'); end if;
  delete from certificados where id = p_id;
  return json_build_object('ok', true);
end;
$$;
grant execute on function borrar_certificado(text, text, bigint) to anon, authenticated;



-- Comprobacion de filas (incluidos los documentos historicos, que quedan intactos).
SELECT count(*) AS total_certificados,
       count(*) FILTER (WHERE nombre IS NOT NULL AND dia IS NOT NULL) AS certificados_heredados,
       count(*) FILTER (WHERE archivo IS NOT NULL) AS archivos_conservados
FROM public.certificados;

COMMIT;
