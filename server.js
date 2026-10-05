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
  catch { db = { pasantes: [], fichajes: [], sedes: [], seq: { fichajes: 0, sedes: 0 } }; }
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

function sembrarDemo() {
  db.pasantes.push(
    { id: 'ana_perez', nombre: 'Ana Perez', pin: '1234', area: 'Ventas', horario: 'Lun a Vie 9 a 18', fecha_inicio: null, fecha_fin: null, sedes_ids: db.sedes.map(x => x.id), creado_en: new Date().toISOString() },
    { id: 'juan_gomez', nombre: 'Juan Gomez', pin: '4321', area: 'Taller', horario: 'Lun a Vie 8 a 17', fecha_inicio: null, fecha_fin: null, sedes_ids: db.sedes.slice(-1).map(x => x.id), creado_en: new Date().toISOString() });
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
const TABLAS = { pasantes: 'pasantes', fichajes: 'fichajes', sedes: 'sedes' };
const CAMPOS_PASANTE = ['id', 'nombre', 'pin', 'area', 'horario', 'fecha_inicio', 'fecha_fin', 'sedes_ids'];
const CAMPOS_SEDE = ['nombre', 'direccion', 'lat', 'lng', 'radio_m', 'activa', 'localidad', 'ubicacion_texto', 'ubicacion_aprox'];

function consulta({ table, op, filters = [], order, limit, values, cols, returning }) {
  if (!TABLAS[table]) throw new Error('tabla_invalida');
  const rows = db[table];
  const coincide = r => filters.every(([c, v]) => String(r[c]) === String(v));
  const salida = r => {
    const o = { ...r };
    if (table === 'pasantes') delete o.pin;                       // el PIN nunca sale del servidor
    if (cols && cols !== '*') { const k = cols.split(',').map(s => s.trim()); Object.keys(o).forEach(c => { if (!k.includes(c)) delete o[c]; }); }
    return o;
  };
  const ordenar = arr => order ? arr.slice().sort((a, b) => a[order] == null ? 1 : b[order] == null ? -1 : a[order] < b[order] ? -1 : a[order] > b[order] ? 1 : 0) : arr;

  if (op === 'select') {
    let r = ordenar(rows.filter(coincide));
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
    const permitidos = table === 'sedes' ? CAMPOS_SEDE : table === 'pasantes' ? CAMPOS_PASANTE.filter(c => c !== 'id') : [];
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
  'index.html': 'text/html; charset=utf-8', 'sw.js': 'text/javascript; charset=utf-8',
  'local-client.js': 'text/javascript; charset=utf-8', 'manifest.webmanifest': 'application/manifest+json',
  'logo.png': 'image/png', 'icon-192.png': 'image/png', 'icon-512.png': 'image/png'
};

function leerCuerpo(req) {
  return new Promise((res, rej) => {
    let b = '';
    req.on('data', c => { b += c; if (b.length > 100e3) { rej(new Error('cuerpo_grande')); req.destroy(); } });
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
