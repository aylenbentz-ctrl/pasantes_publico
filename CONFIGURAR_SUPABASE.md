# Supabase en GitHub Pages

La web carga config.public.js, que contiene únicamente la URL del proyecto y su clave publishable. Es configuración pública del navegador, no una contraseña. config.js sigue ignorado y puede usarse como configuración local adicional; el servidor demo genera ese archivo con FICHAJE_LOCAL=true.

No poner claves secret, service_role, contraseñas ni datos de pasantes en ningún archivo público. RLS y las funciones SQL controlan el acceso a los datos. Este cambio reutiliza el proyecto que ya usaba la aplicación; no modifica tablas ni usuarios.

Después de fusionar, esperar el despliegue de Pages y probar el ingreso con una cuenta real existente de RRHH o un pasante existente en Supabase. Los accesos de npm run demo solo pertenecen al servidor local.

Para cambiar de proyecto, actualizar únicamente URL y publishableKey en config.public.js y preparar el esquema y las políticas en el nuevo proyecto. Las claves públicas son visibles en la web por diseño.
