-- ============================================================
-- Esquema para "Fichaje de Pasantes" en Supabase
-- Ejecutar en: Supabase Dashboard > SQL Editor > New query
-- Se puede correr de nuevo sin romper nada (es idempotente),
-- así que sirve tanto para instalar de cero como para actualizar
-- una instalación anterior.
-- ============================================================

-- ------------------------------------------------------------
-- Tablas
-- ------------------------------------------------------------
create table if not exists pasantes (
  id text primary key,
  nombre text not null,
  pin text not null,
  area text,
  horario text,
  fecha_inicio date,
  fecha_fin date,
  creado_en timestamptz default now()
);

create table if not exists fichajes (
  id bigint generated always as identity primary key,
  nombre text not null,
  tipo text not null check (tipo in ('entrada','salida')),
  dia date not null,
  ts timestamptz not null default now(),
  ubicacion_lat double precision,
  ubicacion_lng double precision
);
-- Sede desde la que se fichó (se completa sola al validar la zona)
alter table fichajes add column if not exists sede text;

-- Sedes donde cada pasante puede fichar (ids de la tabla sedes)
alter table pasantes add column if not exists sedes_ids bigint[] not null default '{}';

-- Usuarios que son de Recursos Humanos. Quien inicia sesión con
-- email/contraseña pero NO está en esta tabla no tiene ningún permiso.
create table if not exists rrhh_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text
);

-- Sedes habilitadas para fichar (geocerca). RRHH las edita desde la app.
create table if not exists sedes (
  id bigint generated always as identity primary key,
  nombre text not null,
  direccion text,
  lat double precision,
  lng double precision,
  radio_m integer not null default 300,
  activa boolean not null default false
);
-- La app completa lat/lng sola (busca la dirección) cuando RRHH activa la sede.
alter table sedes add column if not exists localidad text default '';
alter table sedes add column if not exists ubicacion_texto text default '';
-- true cuando la dirección se ubicó solo por la calle (sin el número exacto)
alter table sedes add column if not exists ubicacion_aprox boolean not null default false;

-- Sedes de Autos del Sur. La app las ubica sola (busca la dirección) la primera
-- vez que RRHH inicia sesión; después se pueden revisar en Panel RRHH > Sedes.
insert into sedes (nombre, direccion, localidad, activa)
select v.nombre, v.direccion, v.localidad, true
from (values
  ('Autos del Sur Sarandí', 'GFT, Av. Bartolomé Mitre 2900, B1872 Sarandí, Provincia de Buenos Aires', 'Sarandí'),
  ('Autos del Sur Quilmes', 'Av. Hipólito Yrigoyen 80, B1878 Quilmes, Provincia de Buenos Aires', 'Quilmes'),
  ('Autos del Sur Florencio Varela', 'RP36 1161, B1888 Florencio Varela, Provincia de Buenos Aires', 'Florencio Varela'),
  ('Autos del Sur Roca', 'Av. Roca 2149, B1872 Crucecita, Provincia de Buenos Aires', 'Crucecita')
) as v(nombre, direccion, localidad)
where not exists (select 1 from sedes);

-- Pasantes cargados antes de existir la asignación: se les asignan todas las sedes.
update pasantes set sedes_ids = (select coalesce(array_agg(id), '{}') from sedes) where sedes_ids = '{}';

alter table pasantes   enable row level security;
alter table fichajes   enable row level security;
alter table rrhh_admins enable row level security;
alter table sedes      enable row level security;
-- rrhh_admins no tiene policies a propósito: nadie la lee directo,
-- solo la función soy_rrhh() (security definer) de abajo.

-- ------------------------------------------------------------
-- ¿El usuario logueado es de RRHH?
-- ------------------------------------------------------------
create or replace function soy_rrhh() returns boolean
language sql security definer set search_path = public stable
as $$ select exists (select 1 from rrhh_admins where user_id = auth.uid()); $$;

grant execute on function soy_rrhh() to anon, authenticated;

-- ------------------------------------------------------------
-- Policies: SOLO RRHH puede leer/escribir directo en las tablas.
-- Los pasantes (sin cuenta de Supabase) usan las funciones de abajo.
-- ------------------------------------------------------------
drop policy if exists "rrhh_lee_pasantes"       on pasantes;
drop policy if exists "rrhh_escribe_pasantes"   on pasantes;
drop policy if exists "rrhh_actualiza_pasantes" on pasantes;
drop policy if exists "rrhh_borra_pasantes"     on pasantes;
create policy "rrhh_lee_pasantes"       on pasantes for select using (soy_rrhh());
create policy "rrhh_escribe_pasantes"   on pasantes for insert with check (soy_rrhh());
create policy "rrhh_actualiza_pasantes" on pasantes for update using (soy_rrhh()) with check (soy_rrhh());
create policy "rrhh_borra_pasantes"     on pasantes for delete using (soy_rrhh());

-- Antes cualquiera podía leer los fichajes (con ubicación). Ahora solo RRHH.
drop policy if exists "cualquiera_lee_fichajes" on fichajes;
drop policy if exists "rrhh_lee_fichajes"       on fichajes;
drop policy if exists "rrhh_borra_fichajes"     on fichajes;
create policy "rrhh_lee_fichajes"   on fichajes for select using (soy_rrhh());
create policy "rrhh_borra_fichajes" on fichajes for delete using (soy_rrhh());

drop policy if exists "rrhh_sedes_select" on sedes;
drop policy if exists "rrhh_sedes_insert" on sedes;
drop policy if exists "rrhh_sedes_update" on sedes;
drop policy if exists "rrhh_sedes_delete" on sedes;
create policy "rrhh_sedes_select" on sedes for select using (soy_rrhh());
create policy "rrhh_sedes_insert" on sedes for insert with check (soy_rrhh());
create policy "rrhh_sedes_update" on sedes for update using (soy_rrhh()) with check (soy_rrhh());
create policy "rrhh_sedes_delete" on sedes for delete using (soy_rrhh());

-- La vista pública con nombres ya no se usa (el pasante escribe su nombre
-- al iniciar sesión), así que se elimina para no exponer la lista.
drop view if exists pasantes_publico;

-- ------------------------------------------------------------
-- Login de pasante: valida nombre + PIN dentro de la base.
-- ------------------------------------------------------------
create or replace function login_pasante(p_nombre text, p_pin text)
returns json
language plpgsql security definer set search_path = public
as $$
declare v pasantes%rowtype;
begin
  select * into v from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found then return json_build_object('ok', false, 'error', 'pasante_no_encontrado'); end if;
  if v.pin is distinct from p_pin then return json_build_object('ok', false, 'error', 'pin_incorrecto'); end if;
  return json_build_object('ok', true, 'nombre', v.nombre, 'area', v.area, 'horario', v.horario,
                           'fecha_inicio', v.fecha_inicio, 'fecha_fin', v.fecha_fin,
                           'sedes', coalesce((select json_agg(s.nombre order by s.nombre) from sedes s where s.id = any(v.sedes_ids)), '[]'::json));
end;
$$;
grant execute on function login_pasante(text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- Fichaje: valida PIN + que esté cerca de una sede habilitada.
-- ------------------------------------------------------------
drop function if exists marcar_fichaje(text, text, text, double precision, double precision);

create or replace function marcar_fichaje(
  p_nombre text,
  p_pin text,
  p_tipo text,
  p_lat double precision default null,
  p_lng double precision default null
) returns json
language plpgsql security definer set search_path = public
as $$
declare
  v_pasante pasantes%rowtype;
  v_hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_sede record;
  v_hay_sedes boolean;
  v_entradas int;
  v_salidas int;
begin
  if p_tipo not in ('entrada','salida') then
    return json_build_object('ok', false, 'error', 'tipo_invalido');
  end if;

  select * into v_pasante from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found then return json_build_object('ok', false, 'error', 'pasante_no_encontrado'); end if;
  if v_pasante.pin is distinct from p_pin then return json_build_object('ok', false, 'error', 'pin_incorrecto'); end if;

  -- Geocerca ---------------------------------------------------
  if p_lat is null or p_lng is null then
    return json_build_object('ok', false, 'error', 'sin_ubicacion');
  end if;

  if coalesce(array_length(v_pasante.sedes_ids, 1), 0) = 0 then
    return json_build_object('ok', false, 'error', 'sin_sede_asignada');
  end if;

  select exists (select 1 from sedes where id = any(v_pasante.sedes_ids) and activa and lat is not null and lng is not null) into v_hay_sedes;
  if not v_hay_sedes then
    return json_build_object('ok', false, 'error', 'sedes_no_configuradas');
  end if;

  -- distancia (haversine, en metros) a cada sede activa; me quedo con la más cercana
  select s.nombre, s.radio_m,
         6371000 * 2 * asin(sqrt(
           power(sin(radians(p_lat - s.lat) / 2), 2) +
           cos(radians(s.lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - s.lng) / 2), 2)
         )) as dist
    into v_sede
    from sedes s
   where s.id = any(v_pasante.sedes_ids) and s.activa and s.lat is not null and s.lng is not null
   order by dist
   limit 1;

  if v_sede.dist > v_sede.radio_m then
    return json_build_object('ok', false, 'error', 'fuera_de_zona',
                             'distancia', round(v_sede.dist), 'sede', v_sede.nombre, 'radio', v_sede.radio_m);
  end if;

  -- Coherencia entrada/salida del día --------------------------
  select count(*) filter (where tipo = 'entrada'), count(*) filter (where tipo = 'salida')
    into v_entradas, v_salidas
    from fichajes where nombre = v_pasante.nombre and dia = v_hoy;

  if p_tipo = 'entrada' and v_entradas > 0 then
    return json_build_object('ok', false, 'error', 'ya_entrada');
  end if;
  if p_tipo = 'salida' and v_entradas = 0 then
    return json_build_object('ok', false, 'error', 'sin_entrada');
  end if;
  if p_tipo = 'salida' and v_salidas > 0 then
    return json_build_object('ok', false, 'error', 'ya_salida');
  end if;

  insert into fichajes(nombre, tipo, dia, ts, ubicacion_lat, ubicacion_lng, sede)
  values (v_pasante.nombre, p_tipo, v_hoy, now(), p_lat, p_lng, v_sede.nombre);

  return json_build_object('ok', true, 'nombre', v_pasante.nombre, 'sede', v_sede.nombre);
end;
$$;
grant execute on function marcar_fichaje(text, text, text, double precision, double precision) to anon, authenticated;

-- ------------------------------------------------------------
-- Historial propio del pasante (para su calendario).
-- ------------------------------------------------------------
create or replace function mis_fichajes(p_nombre text, p_pin text)
returns json
language plpgsql security definer set search_path = public
as $$
declare v pasantes%rowtype;
begin
  select * into v from pasantes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if not found or v.pin is distinct from p_pin then
    return json_build_object('ok', false, 'error', 'credenciales');
  end if;
  return json_build_object('ok', true, 'fichajes', coalesce((
    select json_agg(json_build_object('dia', f.dia, 'tipo', f.tipo, 'ts', f.ts, 'sede', f.sede) order by f.ts)
      from fichajes f where f.nombre = v.nombre
  ), '[]'::json));
end;
$$;
grant execute on function mis_fichajes(text, text) to anon, authenticated;

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

-- ------------------------------------------------------------
-- Realtime (para que el panel se actualice solo):
-- Dashboard > Database > Replication > activar "fichajes", "pasantes" y "certificados".
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- Crear el usuario de RRHH (2 pasos):
-- 1) Dashboard > Authentication > Users > Add user (email + contraseña).
-- 2) Marcarlo como RRHH (cambiá el email por el real) y correr:
--
--    insert into rrhh_admins (user_id, email)
--    select id, email from auth.users where email = 'rrhh@tuempresa.com'
--    on conflict do nothing;
--
-- Sin el paso 2, esa cuenta NO puede entrar al panel.
-- ------------------------------------------------------------
