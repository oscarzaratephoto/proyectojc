# Proyecto JC

Tablero tipo Trello con usuarios, contraseñas y tableros compartidos. Es una página estática (GitHub Pages) que usa [Supabase](https://supabase.com) como base de datos y sistema de login.

- Acceso solo por invitación: nadie puede registrarse por su cuenta.
- Cada tablero tiene un propietario que invita a otros usuarios; cada persona solo ve los tableros a los que pertenece.
- Tarjetas con etiquetas, fecha límite, descripción, checklist, personas asignadas y comentarios.
- Los cambios se ven en vivo entre usuarios.

## Configuración (una sola vez)

1. **Crear el proyecto.** En supabase.com → *New project*. Guarda la contraseña de la base de datos.
2. **Crear las tablas.** *SQL Editor* → *New query* → pega todo `supabase/schema.sql` → *Run*.
3. **Cerrar el registro.** *Authentication* → *Sign In / Providers* (o *Settings*) → desactiva **Allow new users to sign up**.
4. **Direcciones permitidas.** *Authentication* → *URL Configuration*:
   - *Site URL*: `https://proyectojc.oscarzarateph.com`
   - *Redirect URLs*: añade `https://proyectojc.oscarzarateph.com/**`
5. **Crear usuarios.** *Authentication* → *Users*:
   - **Add user → Create new user**: pones correo y contraseña y marcas *Auto Confirm User*. Es lo más rápido y no envía correos.
   - **Invite user**: Supabase envía un correo; al abrir el enlace, la persona elige su contraseña en la propia app.
6. **Conectar la app.** *Project Settings* → *API*: copia la **Project URL** y la clave **anon public** y pégalas en `config.js`.
   Nunca uses la clave `service_role` en este archivo.

## Uso

- Un usuario entra, crea un tablero y lo comparte desde **👥 Miembros → Invitar por correo**. La persona invitada debe tener ya una cuenta (paso 5).
- Quien no es propietario puede salir del tablero; solo el propietario puede eliminarlo o invitar.
- "¿Olvidaste tu contraseña?" envía un enlace para elegir una nueva.

## Actualizaciones de la base de datos

Cada cambio que necesita tocar la base de datos viene en un archivo de `supabase/`. Ejecútalos en orden, una sola vez cada uno, en *SQL Editor*:

1. `schema.sql` (tablas y seguridad)
2. `notifications.sql` (avisos por correo)
3. `update_2.sql` (archivar y nombres de etiquetas)

## Funciones de la app

- **Mis tareas**: todo lo que tienes asignado en todos los tableros, agrupado en vencidas, hoy, próximas y sin fecha.
- **Archivar** tarjetas y listas en vez de borrarlas; se recuperan desde **🗄 Archivados**.
- **Filtros** por persona, etiqueta y vencidas; búsqueda por texto.
- **Etiquetas con nombre** por tablero (en **👥 Miembros → Nombre de las etiquetas**).
- **Calendario** del tablero con las fechas límite (en el móvil se muestra como agenda).
- **App instalable**: en el móvil, abre la web y elige *Añadir a pantalla de inicio* (iPhone: botón Compartir) para usarla a pantalla completa.

## Avisos por correo

- Al **asignar una tarjeta**, la persona asignada recibe un correo (no se avisa a quien se asigna a sí mismo).
- **Cada mañana (8:00, hora de Colombia)** cada persona recibe un solo correo con sus tareas vencidas, las que vencen hoy y las de mañana. Se ignoran las tarjetas marcadas como **Completada**, las que están en una lista llamada "Hecho / Terminado / Completado" y las vencidas hace más de 7 días.

Los correos se envían con [Resend](https://resend.com) (gratis hasta 3.000 al mes) desde la propia base de datos.

1. **Resend.** Crea una cuenta → *Domains* → *Add Domain* → `oscarzarateph.com`. Resend muestra unos registros DNS (TXT y MX); agrégalos en GoDaddy y pulsa *Verify*. Sin dominio verificado, Resend solo deja enviar a tu propio correo.
   Luego *API Keys* → *Create API Key* (permiso *Sending access*) y copia la clave `re_…`.
2. **Supabase.** SQL Editor → ejecuta `supabase/notifications.sql` (después de `schema.sql`). Si pide activar `pg_net` o `pg_cron`, actívalos en *Database → Extensions* y vuelve a ejecutarlo.
3. **Guardar la clave cifrada** (cambia `re_TU_CLAVE` y el remitente por los tuyos; el remitente debe ser de tu dominio):

   ```sql
   select vault.create_secret('re_TU_CLAVE', 'resend_api_key');
   select vault.create_secret('Proyecto JC <avisos@oscarzarateph.com>', 'mail_from');
   ```
4. **Probar.**

   ```sql
   select public.send_email('tu@correo.com', 'Prueba', '<p>Funciona</p>');
   select public.send_due_reminders(true);  -- envía ya el resumen (true = aunque hoy ya se haya enviado)
   ```
5. **Si no llega nada**, mira la respuesta de Resend:

   ```sql
   select id, status_code, content from net._http_response order by created desc limit 5;
   ```

Para cambiar la hora o la zona horaria: la hora está en la línea `cron.schedule(...)` de `notifications.sql` (en UTC) y la zona en la constante `tz` de `send_due_reminders`.

## Notas

- La seguridad no depende de esconder la página: la imponen las reglas de la base de datos (Row Level Security, en `supabase/schema.sql`). La clave `anon` es pública por diseño.
- El plan gratuito de Supabase pausa los proyectos tras una semana sin actividad; se reactivan desde el panel.
- El envío de correos de Supabase sin SMTP propio tiene un límite bajo por hora; crear usuarios con contraseña evita depender de él.
