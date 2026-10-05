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
-- Realtime (para que el panel se actualice solo):
-- Dashboard > Database > Replication > activar "fichajes" y "pasantes".
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
