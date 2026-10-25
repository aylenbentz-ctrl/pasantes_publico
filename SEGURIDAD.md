# Configuración y publicación segura

- `npm run demo` funciona sin dependencias ni configuración externa. Los accesos incluidos son ficticios y exclusivos del demo local.
- No publiques `data.json`: contiene PIN, fichajes y archivos de certificados. Los adjuntos están incluidos en ese JSON.
- `.gitignore` excluye datos locales, archivos de entorno, configuración, claves privadas, logs, respaldos y entregables.
- Para alojamiento estático, copiá `config.example.js` como `config.js` y completá la URL y clave pública de Supabase. Generá o copiá ese archivo en el entorno de despliegue; no lo agregues al repositorio. El servidor demo genera su propio `/config.js`.
- La configuración del navegador siempre es visible para quien visita la aplicación. Usá únicamente una clave publishable/anon; nunca service_role, claves secretas ni contraseñas. La protección de datos depende de las políticas RLS y las funciones SQL.
- El workflow de mantenimiento usa los secretos de Actions `SUPABASE_URL` y `SUPABASE_PUBLISHABLE_KEY`. Sin ellos, omite la consulta.
- El servidor Node es de prueba; no lo despliegues como servidor público con credenciales demo.
- Si un secreto real ya se publicó, hay que revocarlo o rotarlo. `.gitignore` no elimina archivos ya versionados ni secretos de commits anteriores. Esta preparación local no certifica el historial remoto.