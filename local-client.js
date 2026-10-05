/* Cliente "tipo Supabase" que habla con server.js (modo prueba local).
   Implementa solo lo que usa index.html: auth, rpc, from(...).select/eq/order/limit/
   update/delete/upsert y channel(...).on(...).subscribe(). */
(function () {
  const KEY = 'fichaje_token';
  const getTok = () => { try { return localStorage.getItem(KEY); } catch { return null; } };
  const setTok = t => { try { t ? localStorage.setItem(KEY, t) : localStorage.removeItem(KEY); } catch {} };

  async function llamar(ruta, cuerpo, metodo) {
    const h = { 'Content-Type': 'application/json' };
    const t = getTok(); if (t) h.Authorization = 'Bearer ' + t;
    try {
      const r = await fetch(ruta, { method: metodo || 'POST', headers: h, body: metodo === 'GET' ? undefined : JSON.stringify(cuerpo || {}) });
      let j = null; try { j = await r.json(); } catch {}
      return { ok: r.ok, status: r.status, json: j };
    } catch (e) { return { ok: false, status: 0, json: null, red: true }; }
  }

  class Consulta {
    constructor(table) { this.q = { table, filters: [], op: null }; }
    select(cols) { if (!this.q.op) { this.q.op = 'select'; this.q.cols = cols || '*'; } else this.q.returning = true; return this; }
    eq(c, v) { this.q.filters.push([c, v]); return this; }
    order(c) { this.q.order = c; return this; }
    limit(n) { this.q.limit = n; return this; }
    delete() { this.q.op = 'delete'; return this; }
    update(v) { this.q.op = 'update'; this.q.values = v; return this; }
    upsert(v) { this.q.op = 'upsert'; this.q.values = v; return this; }
    insert(v) { this.q.op = 'insert'; this.q.values = v; return this; }
    then(ok, ko) {
      return llamar('/api/q', this.q).then(r => r.ok
        ? { data: r.json.data, error: null }
        : { data: null, error: { message: (r.json && r.json.error) || 'error_red' } }).then(ok, ko);
    }
  }

  let es = null; const oyentes = [];
  function abrirEventos() {
    if (es || !window.EventSource) return;
    es = new EventSource('/api/events');
    es.onmessage = m => { let d = {}; try { d = JSON.parse(m.data); } catch {} oyentes.forEach(o => { if (!o.table || o.table === d.table) o.cb(d); }); };
  }

  window.createLocalClient = function () {
    return {
      auth: {
        async getSession() {
          if (!getTok()) return { data: { session: null } };
          const r = await llamar('/api/auth/session', null, 'GET');
          if (r.ok && r.json && r.json.rrhh) return { data: { session: { access_token: getTok() } } };
          setTok(null); return { data: { session: null } };
        },
        async signInWithPassword({ email, password }) {
          const r = await llamar('/api/auth/login', { email, password });
          if (!r.ok) return { error: { message: (r.json && r.json.error) || 'credenciales' } };
          setTok(r.json.token); return { error: null };
        },
        async signOut() { await llamar('/api/auth/logout'); setTok(null); },
        onAuthStateChange() {}
      },
      async rpc(nombre, args) {
        const r = await llamar('/api/rpc/' + nombre, args);
        return r.ok ? { data: r.json, error: null } : { data: null, error: { message: 'error_red' } };
      },
      from: t => new Consulta(t),
      channel() {
        const ch = {
          on(_tipo, filtro, cb) { oyentes.push({ table: filtro && filtro.table, cb }); return ch; },
          subscribe() { abrirEventos(); return ch; }
        };
        return ch;
      },
      removeAllChannels() { oyentes.length = 0; if (es) { es.close(); es = null; } }
    };
  };
})();
