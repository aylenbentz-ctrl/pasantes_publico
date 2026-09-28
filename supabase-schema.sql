-- ============================================================
-- Esquema para "Fichaje de Pasantes" en Supabase
-- Ejecutar en: Supabase Dashboard > SQL Editor > New query
-- ============================================================

-- Tabla de pasantes autorizados (incluye el PIN)
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

-- Tabla de fichajes (entrada/salida)
create table if not exists fichajes (
  id bigint generated always as identity primary key,
  nombre text not null,
  tipo text not null check (tipo in ('entrada','salida')),
  dia date not null,
  ts timestamptz not null default now(),
  ubicacion_lat double precision,
  ubicacion_lng double precision
);

alter table pasantes enable row level security;
alter table fichajes enable row level security;

-- ------------------------------------------------------------
-- pasantes: SOLO el panel de RRHH autenticado puede leer o
-- escribir esta tabla directamente. Así el PIN de cada pasante
-- nunca se descarga al navegador de otra persona.
-- ------------------------------------------------------------
create policy "rrhh_lee_pasantes" on pasantes
  for select using (auth.role() = 'authenticated');

create policy "rrhh_escribe_pasantes" on pasantes
  for insert with check (auth.role() = 'authenticated');

create policy "rrhh_actualiza_pasantes" on pasantes
  for update using (auth.role() = 'authenticated');

-- Vista pública SIN el PIN, solo para autocompletar el nombre
-- en la pantalla de fichaje (no requiere login).
create or replace view pasantes_publico as
  select id, nombre, area, horario from pasantes;

grant select on pasantes_publico to anon, authenticated;

-- ------------------------------------------------------------
-- fichajes: cualquiera puede LEER los registros de hoy (para
-- mostrarlos en el panel). La escritura NO se hace directo a
-- la tabla: se hace a través de la función marcar_fichaje()
-- de abajo, que valida el PIN dentro de la base de datos.
-- ------------------------------------------------------------
create policy "cualquiera_lee_fichajes" on fichajes
  for select using (true);

-- No creamos policy de insert para "anon": los inserts solo
-- pasan por la función security definer de abajo.

-- ------------------------------------------------------------
-- Función que valida nombre+PIN y registra el fichaje.
-- Corre con privilegios del dueño (security definer), así puede
-- leer la tabla pasantes (protegida por RLS) sin que el cliente
-- tenga acceso directo a ella.
-- ------------------------------------------------------------
create or replace function marcar_fichaje(
  p_nombre text,
  p_pin text,
  p_tipo text,
  p_lat double precision default null,
  p_lng double precision default null
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pasante pasantes%rowtype;
begin
  if p_tipo not in ('entrada','salida') then
    return json_build_object('ok', false, 'error', 'tipo_invalido');
  end if;

  select * into v_pasante from pasantes where lower(nombre) = lower(p_nombre) limit 1;
  if not found then
    return json_build_object('ok', false, 'error', 'pasante_no_encontrado');
  end if;

  if v_pasante.pin is distinct from p_pin then
    return json_build_object('ok', false, 'error', 'pin_incorrecto');
  end if;

  insert into fichajes(nombre, tipo, dia, ts, ubicacion_lat, ubicacion_lng)
  values (v_pasante.nombre, p_tipo, current_date, now(), p_lat, p_lng);

  return json_build_object('ok', true, 'nombre', v_pasante.nombre);
end;
$$;

-- Permite que usuarios anónimos (los pasantes, sin login) ejecuten
-- esta función puntual — pero NO les da acceso a la tabla en sí.
grant execute on function marcar_fichaje(text, text, text, double precision, double precision) to anon, authenticated;

-- ------------------------------------------------------------
-- Activar Realtime (para que el panel se actualice solo):
-- Dashboard > Database > Replication > activar "fichajes" y
-- "pasantes" en la publicación supabase_realtime.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- Crear el usuario de RRHH:
-- Dashboard > Authentication > Users > Add user (email + contraseña).
-- Ese es el login que se usa en el Panel RRHH de la app.
-- ------------------------------------------------------------
