# Fichaje de Pasantes

App de registro de entrada/salida para pasantes, con panel de RRHH.
Es una **PWA** (Progressive Web App): se puede instalar desde el navegador
en el celular o la compu y se abre como una app aparte, sin la barra del
navegador.

## Archivos

- `index.html` — la app (interfaz + lógica, conectada a Supabase).
- `manifest.webmanifest` — hace que sea instalable.
- `sw.js` — service worker mínimo (requisito técnico para instalar).
- `icon-192.png`, `icon-512.png` — íconos de la app.
- `supabase-schema.sql` — tablas, seguridad (RLS) y funciones a correr en Supabase.

## 1) Crear el proyecto en Supabase

1. Entrá a [supabase.com](https://supabase.com) → **New project**.
2. Andá a **SQL Editor** → pegá el contenido de `supabase-schema.sql` → **Run**.
3. Andá a **Database → Replication** y activá `fichajes` y `pasantes` en la
   publicación `supabase_realtime` (para que el panel se actualice solo).
4. Andá a **Authentication → Users → Add user** y creá el login de RRHH
   (email + contraseña). Ese es el que se usa para entrar al Panel RRHH.
5. Andá a **Project Settings → API** y copiá el **Project URL** y la
   **anon public key**.

## 2) Configurar la app

Abrí `index.html` y completá estas dos líneas con los datos del paso anterior:

```js
const SUPABASE_URL = "https://TU-PROYECTO.supabase.co";
const SUPABASE_ANON_KEY = "TU-ANON-KEY-PUBLICA";
```

## 3) Subir a GitHub y publicar

```bash
git init
git add .
git commit -m "Fichaje de pasantes"
git branch -M main
git remote add origin https://github.com/TU-USUARIO/TU-REPO.git
git push -u origin main
```

Después, en el repo de GitHub: **Settings → Pages → Source: `main` / `/root`**.
En unos minutos la app queda disponible en
`https://TU-USUARIO.github.io/TU-REPO/`.

Para "instalar" la app: abrir esa URL desde el celular y usar
"Agregar a pantalla de inicio" (Android/Chrome) o "Compartir → Agregar a
inicio" (iPhone/Safari).

---

## Riesgos a tener en cuenta

Te los dejo en detalle porque los pediste explícitamente — ninguno de estos
te debería sorprender después de publicarlo:

**1. La `anon key` va a quedar visible en el código, en un repo público.**
Esto es esperado en apps de Supabase que hablan directo desde el navegador
(no es una fuga de una clave secreta) — pero significa que **la única
protección real de tus datos son las políticas RLS** del archivo SQL, no el
hecho de que nadie vea la key. Cualquiera puede tomar esa URL + key y hacer
consultas directas a tu API con `curl`, sin pasar por tu interfaz. Probá cada
política antes de confiar en ella (por ejemplo, intentá leer `pasantes` sin
estar logueado y confirmá que te lo rechaza).

**2. Los PIN de 4–6 dígitos son una autenticación débil.**
Ya los saqué de las tablas que viajan al cliente (antes, en la versión
original, la lista completa de pasantes *con sus PIN* se descargaba entera al
teléfono de cualquiera que abriera la app — eso ya no pasa: ahora la
validación ocurre adentro de la base de datos). Pero un PIN corto sigue
siendo adivinable por fuerza bruta si alguien lo intenta muchas veces, y no
hay límite de intentos configurado. Si esto te importa, subí a PIN más largos
o agregá un bloqueo temporal tras varios intentos fallidos.

**3. Cualquiera que sepa nombre + PIN de otra persona puede fichar en su
nombre**, y la ubicación es la que el navegador de esa persona reporta — se
puede negar el permiso o, con herramientas, simularla. No es una prueba dura
de presencia física, es una referencia.

**4. El panel de RRHH ahora usa login real (Supabase Auth)** en vez de la
contraseña fija que tenía el archivo original escrita en el código (visible
para cualquiera que abriera el "ver código fuente" de la página). Sigue
siendo importante: quien tenga esas credenciales puede ver y editar todo,
incluidos los datos de ubicación de los pasantes.

**5. Datos personales de los pasantes** (nombre, PIN, horarios, ubicación
geográfica) están sujetos a la Ley 25.326 de Protección de Datos Personales.
Vale la pena avisarles qué se registra y para qué, no guardar la ubicación
más tiempo del necesario, y tener forma de borrar los datos de alguien si lo
pide.

**6. GitHub Pages es público** — no hay forma de restringirlo a una red o
lista de personas sin agregar una capa de autenticación aparte. Si esto tiene
que ser de acceso interno/restringido, GitHub Pages solo no alcanza.

Nada de esto es motivo para no hacerlo — son los mismos riesgos que tiene
cualquier app chica hecha con Supabase + hosting estático. Simplemente
conviene tenerlos en la cabeza antes de que empiecen a fichar pasantes reales.
