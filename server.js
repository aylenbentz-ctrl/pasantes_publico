/* ============================================================
   Servidor de PRUEBA local para "Fichaje de Pasantes"
   - Sin dependencias: solo Node.js 18+ (node server.js)
   - Guarda todo en data.json (al lado de este archivo)
   - Reemplaza a Supabase para probar la app en tu compu
   Variables opcionales:
     PORT=3000  RRHH_EMAIL=...  RRHH_PASS=...
     --sin-geocerca   -> no exige ubicación (útil para probar desde la PC)
     --demo           -> carga pasantes y fichajes de ejemplo
   (también sirven las variables SIN_GEOCERCA=1 y DEMO=1)
   ============================================================ */
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT) || 3000;
const RRHH_EMAIL = (process.env.RRHH_EMAIL || 'rrhh@fichaje.local').toLowerCase();
const RRHH_PASS = process.env.RRHH_PASS || 'rrhh1234';
const SIN_GEOCERCA = process.env.SIN_GEOCERCA === '1' || process.argv.includes('--sin-geocerca');
const DEMO = process.env.DEMO === '1' || process.argv.includes('--demo');
const TZ = 'America/Argentina/Buenos_Aires';
const DATA_FILE = path.join(__dirname, 'data.json');

/* ---------------- Base de datos (JSON) ---------------- */
let db;
function cargar() {
  try { db = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8')); }
  catch { db = { pasantes: [], fichajes: [], sedes: [], certificados: [], seq: { fichajes: 0, sedes: 0, certificados: 0 } }; }
  db.certificados = db.certificados || []; db.seq.certificados = db.seq.certificados || 0;
  if (!db.sedes.length) {
    // Sedes de Autos del Sur. La app las ubica sola en el primer inicio de sesión de RRHH.
    [
      ['Autos del Sur Sarandí', 'GFT, Av. Bartolomé Mitre 2900, B1872 Sarandí, Provincia de Buenos Aires', 'Sarandí'],
      ['Autos del Sur Quilmes', 'Av. Hipólito Yrigoyen 80, B1878 Quilmes, Provincia de Buenos Aires', 'Quilmes'],
      ['Autos del Sur Florencio Varela', 'RP36 1161, B1888 Florencio Varela, Provincia de Buenos Aires', 'Florencio Varela'],
      ['Autos del Sur Roca', 'Av. Roca 2149, B1872 Crucecita, Provincia de Buenos Aires', 'Crucecita']
    ].forEach(([nombre, direccion, localidad]) =>
      db.sedes.push({ id: ++db.seq.sedes, nombre, direccion, localidad, ubicacion_texto: '', ubicacion_aprox: false, lat: null, lng: null, radio_m: 300, activa: true }));
  }
  // migración: pasantes cargados antes de existir la asignación de sedes -> todas las sedes
  db.pasantes.forEach(p => { if (!Array.isArray(p.sedes_ids)) p.sedes_ids = db.sedes.map(x => x.id); });
  db.sedes.forEach(x => { if (x.localidad == null) x.localidad = ''; if (x.ubicacion_texto == null) x.ubicacion_texto = ''; if (x.ubicacion_aprox == null) x.ubicacion_aprox = false; });
  if (DEMO && !db.pasantes.length) {
    sembrarDemo();
  }
  guardar();
}
function guardar() {
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, DATA_FILE);
}
const diaDe = (d = new Date()) => d.toLocaleDateString('en-CA', { timeZone: TZ });

const DEMO_IMG = 'data:image/png;base64,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';
function sembrarDemo() {
  db.pasantes.push(
    { id: 'ana_perez', nombre: 'Ana Perez', pin: '1234', area: 'Ventas', horario: 'Lun a Vie 9 a 18', fecha_inicio: null, fecha_fin: null, sedes_ids: db.sedes.map(x => x.id), creado_en: new Date().toISOString() },
    { id: 'juan_gomez', nombre: 'Juan Gomez', pin: '4321', area: 'Taller', horario: 'Lun a Vie 8 a 17', fecha_inicio: null, fecha_fin: null, sedes_ids: db.sedes.slice(-1).map(x => x.id), creado_en: new Date().toISOString() });
  const ahora = Date.now(), dk = n => diaDe(new Date(ahora - n * 86400000));
  [['Ana Perez', 5, 5, 'Médico', 'Control anual', 'pendiente', null],
   ['Juan Gomez', 8, 7, 'Examen o estudio', 'Final de Contabilidad', 'rechazado', 'La foto está borrosa, subila de nuevo.']].forEach(([n, a, b, motivo, detalle, estado, rz], i) =>
    db.certificados.push({ id: ++db.seq.certificados, pasante: n, desde: dk(a), hasta: dk(b), motivo, detalle, archivo_nombre: 'certificado-demo.png', archivo_tipo: 'image/png', archivo: DEMO_IMG,
      estado, motivo_rechazo: rz, creado_en: new Date(ahora - (3 - i) * 86400000).toISOString(), resuelto_en: estado === 'pendiente' ? null : new Date(ahora - 86400000).toISOString() }));
  for (let i = 1; i <= 14; i++) {
    const f = new Date(Date.now() - i * 86400000);
    const dow = new Date(f.toLocaleString('en-US', { timeZone: TZ })).getDay();
    if (dow === 0 || dow === 6) continue;
    const dia = diaDe(f);
    [['Ana Perez', i % 5 === 0], ['Juan Gomez', i % 4 === 0]].forEach(([nombre, olvido]) => {
      const base = new Date(dia + 'T09:00:00-03:00');
      db.fichajes.push({ id: ++db.seq.fichajes, nombre, tipo: 'entrada', dia, ts: base.toISOString(), ubicacion_lat: null, ubicacion_lng: null, sede: 'Autos del Sur Sarandí' });
      if (!olvido) db.fichajes.push({ id: ++db.seq.fichajes, nombre, tipo: 'salida', dia, ts: new Date(base.getTime() + 8 * 3600000).toISOString(), ubicacion_lat: null, ubicacion_lng: null, sede: 'Autos del Sur Sarandí' });
    });
  }
}

/* ---------------- Sesiones RRHH + anti fuerza bruta ---------------- */
const sesiones = new Map();                 // token -> expira
const intentos = new Map();                 // ip -> {n, hasta}
const nuevaSesion = () => { const t = crypto.randomBytes(24).toString('hex'); sesiones.set(t, Date.now() + 12 * 3600e3); return t; };
function tokenDe(req) { return (req.headers.authorization || '').replace(/^Bearer /, ''); }
function esRRHH(req) {
  const t = tokenDe(req), exp = sesiones.get(t);
  if (!exp) return false;
  if (exp < Date.now()) { sesiones.delete(t); return false; }
  return true;
}
function bloqueado(ip) { const i = intentos.get(ip); return !!(i && i.hasta > Date.now()); }
function falla(ip) {
  const i = intentos.get(ip) || { n: 0, hasta: 0 };
  i.n++;
  if (i.n >= 8) { i.hasta = Date.now() + 10 * 60e3; i.n = 0; }
  intentos.set(ip, i);
}
const igual = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };

/* ---------------- Lógica de negocio (espejo de supabase-schema.sql) ---------------- */
const buscarPasante = nombre => db.pasantes.find(p => p.nombre.trim().toLowerCase() === String(nombre || '').trim().toLowerCase());

function haversine(lat1, lng1, lat2, lng2) {
  const r = x => x * Math.PI / 180;
  const a = Math.sin(r(lat1 - lat2) / 2) ** 2 + Math.cos(r(lat2)) * Math.cos(r(lat1)) * Math.sin(r(lng1 - lng2) / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(a));
}

function autenticar(nombre, pin, ip) {
  if (bloqueado(ip)) return { error: { ok: false, error: 'demasiados_intentos' } };
  const p = buscarPasante(nombre);
  if (!p || !igual(p.pin, pin)) { falla(ip); return { error: { ok: false, error: 'credenciales' } }; }
  return p;
}
const metaCert = c => { const { archivo, ...resto } = c; return resto; };

const rpc = {
  soy_rrhh: (_a, req) => esRRHH(req),

  login_pasante: ({ p_nombre, p_pin }, _req, ip) => {
    if (bloqueado(ip)) return { ok: false, error: 'demasiados_intentos' };
    const p = buscarPasante(p_nombre);
    if (!p) { falla(ip); return { ok: false, error: 'pasante_no_encontrado' }; }
    if (!igual(p.pin, p_pin)) { falla(ip); return { ok: false, error: 'pin_incorrecto' }; }
    return { ok: true, nombre: p.nombre, area: p.area, horario: p.horario, fecha_inicio: p.fecha_inicio, fecha_fin: p.fecha_fin,
             sedes: db.sedes.filter(x => (p.sedes_ids || []).includes(x.id)).map(x => x.nombre) };
  },

  mis_fichajes: ({ p_nombre, p_pin }, _req, ip) => {
    if (bloqueado(ip)) return { ok: false, error: 'demasiados_intentos' };
    const p = buscarPasante(p_nombre);
    if (!p || !igual(p.pin, p_pin)) { falla(ip); return { ok: false, error: 'credenciales' }; }
    return { ok: true, fichajes: db.fichajes.filter(f => f.nombre === p.nombre).sort((a, b) => a.ts < b.ts ? -1 : 1).map(f => ({ dia: f.dia, tipo: f.tipo, ts: f.ts, sede: f.sede })) };
  },

  editar_pasante: (a, req) => {
    if (!esRRHH(req)) return { ok: false, error: 'no_autorizado' };
    const p = db.pasantes.find(x => x.id === a.p_id);
    if (!p) return { ok: false, error: 'pasante_no_encontrado' };
    const nombre = String(a.p_nombre || '').trim().slice(0, 120), pin = String(a.p_pin || '');
    if (!nombre) return { ok: false, error: 'nombre_vacio' };
    if (pin && !/^\d{4,6}$/.test(pin)) return { ok: false, error: 'pin_invalido' };
    if (a.p_inicio && a.p_fin && a.p_fin < a.p_inicio) return { ok: false, error: 'fechas_invalidas' };
    const ids = (Array.isArray(a.p_sedes_ids) ? a.p_sedes_ids : []).map(Number).filter(Number.isFinite);
    if (!ids.length) return { ok: false, error: 'sin_sede' };
    if (db.pasantes.some(x => x.id !== p.id && x.nombre.trim().toLowerCase() === nombre.toLowerCase())) return { ok: false, error: 'nombre_duplicado' };
    const viejo = p.nombre;
    Object.assign(p, { nombre, area: a.p_area || '', horario: a.p_horario || '', fecha_inicio: a.p_inicio || null, fecha_fin: a.p_fin || null, sedes_ids: ids });
    if (pin) p.pin = pin;
    if (viejo !== nombre) {
      db.fichajes.forEach(f => { if (f.nombre === viejo) f.nombre = nombre; });
      db.certificados.forEach(c => { if (c.pasante === viejo) c.pasante = nombre; });
    }
    guardar(); avisar('pasantes'); avisar('fichajes'); avisar('certificados');
    return { ok: true, nombre };
  },

  mis_certificados: ({ p_nombre, p_pin }, _req, ip) => {
    const p = autenticar(p_nombre, p_pin, ip); if (p.error) return p.error;
    return { ok: true, certificados: db.certificados.filter(c => c.pasante === p.nombre).sort((a, b) => a.creado_en < b.creado_en ? 1 : -1).map(metaCert) };
  },

  mi_certificado_archivo: ({ p_nombre, p_pin, p_id }, _req, ip) => {
    const p = autenticar(p_nombre, p_pin, ip); if (p.error) return p.error;
    const c = db.certificados.find(x => x.id === Number(p_id) && x.pasante === p.nombre);
    return c ? { ok: true, archivo: c.archivo, archivo_nombre: c.archivo_nombre } : { ok: false, error: 'no_encontrado' };
  },

  subir_certificado: (a, _req, ip) => {
    const p = autenticar(a.p_nombre, a.p_pin, ip); if (p.error) return p.error;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(a.p_desde || '') || !/^\d{4}-\d{2}-\d{2}$/.test(a.p_hasta || '') || a.p_hasta < a.p_desde) return { ok: false, error: 'fechas_invalidas' };
    const archivo = String(a.p_archivo || '');
    if (!/^data:(image\/(jpeg|png|webp)|application\/pdf);base64,/.test(archivo)) return { ok: false, error: 'archivo_invalido' };
    if (archivo.length > 2000000) return { ok: false, error: 'archivo_grande' };
    if (db.certificados.filter(c => c.pasante === p.nombre).length >= 30) return { ok: false, error: 'demasiados_certificados' };
    const c = { id: ++db.seq.certificados, pasante: p.nombre, desde: a.p_desde, hasta: a.p_hasta, motivo: String(a.p_motivo || 'Otro').slice(0, 60), detalle: String(a.p_detalle || '').slice(0, 200),
      archivo_nombre: String(a.p_archivo_nombre || '').slice(0, 120), archivo_tipo: archivo.slice(5, archivo.indexOf(';')), archivo, estado: 'pendiente', motivo_rechazo: null, creado_en: new Date().toISOString(), resuelto_en: null };
    db.certificados.push(c); guardar(); avisar('certificados');
    return { ok: true, id: c.id };
  },

  borrar_certificado: ({ p_nombre, p_pin, p_id }, _req, ip) => {
    const p = autenticar(p_nombre, p_pin, ip); if (p.error) return p.error;
    const c = db.certificados.find(x => x.id === Number(p_id) && x.pasante === p.nombre);
    if (!c) return { ok: false, error: 'no_encontrado' };
    if (c.estado === 'aprobado') return { ok: false, error: 'aprobado_no_se_borra' };
    db.certificados = db.certificados.filter(x => x !== c); guardar(); avisar('certificados');
    return { ok: true };
  },

  marcar_fichaje: ({ p_nombre, p_pin, p_tipo, p_lat, p_lng }, _req, ip) => {
    if (bloqueado(ip)) return { ok: false, error: 'demasiados_intentos' };
    if (!['entrada', 'salida'].includes(p_tipo)) return { ok: false, error: 'tipo_invalido' };
    const p = buscarPasante(p_nombre);
    if (!p) { falla(ip); return { ok: false, error: 'pasante_no_encontrado' }; }
    if (!igual(p.pin, p_pin)) { falla(ip); return { ok: false, error: 'pin_incorrecto' }; }

    let sede = '(modo prueba)', lat = null, lng = null;
    if (!SIN_GEOCERCA) {
      lat = Number(p_lat); lng = Number(p_lng);
      if (p_lat == null || p_lng == null || !isFinite(lat) || !isFinite(lng)) return { ok: false, error: 'sin_ubicacion' };
      if (!(p.sedes_ids || []).length) return { ok: false, error: 'sin_sede_asignada' };
      const activas = db.sedes.filter(s => p.sedes_ids.includes(s.id) && s.activa && s.lat != null && s.lng != null);
      if (!activas.length) return { ok: false, error: 'sedes_no_configuradas' };
      const cerca = activas.map(s => ({ s, d: haversine(lat, lng, s.lat, s.lng) })).sort((a, b) => a.d - b.d)[0];
      if (cerca.d > cerca.s.radio_m) return { ok: false, error: 'fuera_de_zona', distancia: Math.round(cerca.d), sede: cerca.s.nombre, radio: cerca.s.radio_m };
      sede = cerca.s.nombre;
    }

    const hoy = diaDe();
    const hechos = db.fichajes.filter(f => f.nombre === p.nombre && f.dia === hoy);
    const ent = hechos.filter(f => f.tipo === 'entrada').length, sal = hechos.filter(f => f.tipo === 'salida').length;
    if (p_tipo === 'entrada' && ent) return { ok: false, error: 'ya_entrada' };
    if (p_tipo === 'salida' && !ent) return { ok: false, error: 'sin_entrada' };
    if (p_tipo === 'salida' && sal) return { ok: false, error: 'ya_salida' };

    db.fichajes.push({ id: ++db.seq.fichajes, nombre: p.nombre, tipo: p_tipo, dia: hoy, ts: new Date().toISOString(), ubicacion_lat: lat, ubicacion_lng: lng, sede });
    guardar(); avisar('fichajes');
    return { ok: true, nombre: p.nombre, sede };
  }
};

/* ---------------- Consultas genéricas (solo RRHH) ---------------- */
const TABLAS = { pasantes: 'pasantes', fichajes: 'fichajes', sedes: 'sedes', certificados: 'certificados' };
const CAMPOS_CERT = ['estado', 'motivo_rechazo', 'resuelto_en'];
const CAMPOS_PASANTE = ['id', 'nombre', 'pin', 'area', 'horario', 'fecha_inicio', 'fecha_fin', 'sedes_ids'];
const CAMPOS_SEDE = ['nombre', 'direccion', 'lat', 'lng', 'radio_m', 'activa', 'localidad', 'ubicacion_texto', 'ubicacion_aprox'];

function consulta({ table, op, filters = [], order, limit, offset, values, cols, returning }) {
  if (!TABLAS[table]) throw new Error('tabla_invalida');
  const rows = db[table];
  const coincide = r => filters.every(([c, v, o]) => o === 'gte' ? String(r[c]) >= String(v) : o === 'lte' ? String(r[c]) <= String(v) : String(r[c]) === String(v));
  const salida = r => {
    const o = { ...r };
    if (table === 'pasantes') delete o.pin;                       // el PIN nunca sale del servidor
    if (cols && cols !== '*') { const k = cols.split(',').map(s => s.trim()); Object.keys(o).forEach(c => { if (!k.includes(c)) delete o[c]; }); }
    return o;
  };
  const cmp = (a, b, k) => a[k] == null ? 1 : b[k] == null ? -1 : a[k] < b[k] ? -1 : a[k] > b[k] ? 1 : 0;
  const claves = order ? [].concat(order) : [];
  const ordenar = arr => claves.length ? arr.slice().sort((a, b) => { for (const k of claves) { const r = cmp(a, b, k); if (r) return r; } return 0; }) : arr;

  if (op === 'select') {
    let r = ordenar(rows.filter(coincide));
    if (offset) r = r.slice(Number(offset));
    if (limit) r = r.slice(0, Number(limit));
    return r.map(salida);
  }
  if (op === 'delete') {
    if (!filters.length) throw new Error('delete_sin_filtro');
    const borrar = rows.filter(coincide);
    db[table] = rows.filter(r => !borrar.includes(r));
    guardar(); avisar(table);
    return returning ? borrar.map(salida) : null;
  }
  if (op === 'update') {
    if (!filters.length) throw new Error('update_sin_filtro');
    const permitidos = table === 'sedes' ? CAMPOS_SEDE : table === 'pasantes' ? CAMPOS_PASANTE.filter(c => c !== 'id') : table === 'certificados' ? CAMPOS_CERT : [];
    if (table === 'certificados' && values) {
      if (!['pendiente', 'aprobado', 'rechazado'].includes(values.estado)) throw new Error('estado_invalido');
      if (values.estado === 'rechazado' && !String(values.motivo_rechazo || '').trim()) throw new Error('falta_motivo');
    }
    const tocados = rows.filter(coincide);
    if (table === 'pasantes' && values && 'sedes_ids' in values) values.sedes_ids = (Array.isArray(values.sedes_ids) ? values.sedes_ids : []).map(Number).filter(Number.isFinite);
    tocados.forEach(r => permitidos.forEach(c => { if (c in (values || {})) r[c] = values[c]; }));
    guardar(); avisar(table);
    return returning ? tocados.map(salida) : null;
  }
  if (op === 'insert' && table === 'sedes') {
    const v = values || {};
    const nombre = String(v.nombre || '').trim().slice(0, 120);
    if (!nombre) throw new Error('datos_invalidos');
    const fila = { id: ++db.seq.sedes, nombre, direccion: String(v.direccion || '').slice(0, 300), localidad: String(v.localidad || '').slice(0, 100),
                   ubicacion_texto: '', ubicacion_aprox: false, lat: null, lng: null, radio_m: 300, activa: false };
    db.sedes.push(fila);
    guardar(); avisar(table);
    return returning ? [salida(fila)] : null;
  }
  if (op === 'upsert' && table === 'pasantes') {
    const v = values || {};
    const nombre = String(v.nombre || '').trim(), pin = String(v.pin || '');
    if (!nombre || !/^\d{4,6}$/.test(pin)) throw new Error('datos_invalidos');
    const fila = { id: String(v.id || nombre).slice(0, 80), nombre, pin, area: v.area || '', horario: v.horario || '', fecha_inicio: v.fecha_inicio || null, fecha_fin: v.fecha_fin || null,
      sedes_ids: Array.isArray(v.sedes_ids) ? v.sedes_ids.map(Number).filter(Number.isFinite) : [] };
    const i = rows.findIndex(r => r.id === fila.id);
    if (i >= 0) rows[i] = { ...rows[i], ...fila }; else rows.push({ ...fila, creado_en: new Date().toISOString() });
    guardar(); avisar(table);
    return returning ? [salida(fila)] : null;
  }
  throw new Error('operacion_invalida');
}

/* ---------------- Eventos en vivo (SSE) ---------------- */
const oyentes = new Set();
function avisar(table) { oyentes.forEach(res => res.write('data: ' + JSON.stringify({ table }) + '\n\n')); }

/* ---------------- HTTP ---------------- */
const ESTATICOS = {
  'design.css': 'text/css; charset=utf-8', 'index.html': 'text/html; charset=utf-8', 'sw.js': 'text/javascript; charset=utf-8',
  'local-client.js': 'text/javascript; charset=utf-8', 'manifest.webmanifest': 'application/manifest+json',
  'logo.png': 'image/png', 'icon-192.png': 'image/png', 'icon-512.png': 'image/png'
};

function leerCuerpo(req) {
  return new Promise((res, rej) => {
    let b = '';
    req.on('data', c => { b += c; if (b.length > 3.5e6) { rej(new Error('cuerpo_grande')); req.destroy(); } });
    req.on('end', () => { try { res(b ? JSON.parse(b) : {}); } catch { rej(new Error('json_invalido')); } });
  });
}
const responder = (res, code, obj) => { res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(obj)); };

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const ip = req.socket.remoteAddress || '?';
  try {
    if (req.method === 'GET' && url.pathname === '/config.js') {
      res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8', 'Cache-Control': 'no-store' });
      return res.end('window.FICHAJE_LOCAL=true;window.FICHAJE_SIN_GEOCERCA=' + SIN_GEOCERCA + ';');
    }
    if (req.method === 'GET' && url.pathname === '/api/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
      res.write(': ok\n\n'); oyentes.add(res);
      req.on('close', () => oyentes.delete(res));
      return;
    }
    if (url.pathname.startsWith('/api/')) {
      if (req.method !== 'POST' && !(req.method === 'GET' && url.pathname === '/api/auth/session')) return responder(res, 405, { error: 'metodo' });

      if (url.pathname === '/api/auth/session') return responder(res, 200, { rrhh: esRRHH(req) });

      const body = await leerCuerpo(req);
      if (url.pathname === '/api/auth/login') {
        if (bloqueado(ip)) return responder(res, 429, { error: 'demasiados_intentos' });
        if (String(body.email || '').trim().toLowerCase() === RRHH_EMAIL && igual(body.password || '', RRHH_PASS))
          return responder(res, 200, { token: nuevaSesion() });
        falla(ip); return responder(res, 401, { error: 'credenciales' });
      }
      if (url.pathname === '/api/auth/logout') { sesiones.delete(tokenDe(req)); return responder(res, 200, {}); }
      if (url.pathname.startsWith('/api/rpc/')) {
        const fn = rpc[url.pathname.slice(9)];
        if (!fn) return responder(res, 404, { error: 'rpc' });
        return responder(res, 200, fn(body, req, ip));
      }
      if (url.pathname === '/api/q') {
        if (!esRRHH(req)) return responder(res, 401, { error: 'no_autorizado' });
        return responder(res, 200, { data: consulta(body) });
      }
      return responder(res, 404, { error: 'no_existe' });
    }

    // estáticos (lista blanca: server.js y data.json NO se sirven)
    let nombre = decodeURIComponent(url.pathname.replace(/^\/+/, '')) || 'index.html';
    if (!Object.prototype.hasOwnProperty.call(ESTATICOS, nombre)) { res.writeHead(404); return res.end('No encontrado'); }
    res.writeHead(200, { 'Content-Type': ESTATICOS[nombre], 'Cache-Control': 'no-cache' });
    fs.createReadStream(path.join(__dirname, nombre)).pipe(res);
  } catch (e) {
    responder(res, 400, { error: e.message });
  }
});

cargar();
server.listen(PORT, () => {
  console.log('\n  Fichaje de Pasantes — servidor de prueba');
  console.log('  → http://localhost:' + PORT);
  console.log('\n  RRHH:     ' + RRHH_EMAIL + '  /  ' + RRHH_PASS);
  if (db.pasantes.length) console.log('  Pasantes: ' + db.pasantes.map(p => p.nombre).join(', ') + (DEMO ? '  (PIN demo: 1234 / 4321)' : ''));
  console.log('  Geocerca: ' + (SIN_GEOCERCA ? 'DESACTIVADA (--sin-geocerca)' : 'activa — activá las sedes en RRHH > Sedes (la ubicación se busca sola)'));
  console.log('  Datos:    ' + DATA_FILE + '\n');
});
