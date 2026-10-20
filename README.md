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

## Notas

- La seguridad no depende de esconder la página: la imponen las reglas de la base de datos (Row Level Security, en `supabase/schema.sql`). La clave `anon` es pública por diseño.
- El plan gratuito de Supabase pausa los proyectos tras una semana sin actividad; se reactivan desde el panel.
- El envío de correos de Supabase sin SMTP propio tiene un límite bajo por hora; crear usuarios con contraseña evita depender de él.
