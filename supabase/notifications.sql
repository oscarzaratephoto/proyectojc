-- Proyecto JC · avisos por correo
-- Ejecutar DESPUÉS de schema.sql, una sola vez, en Supabase → SQL Editor.
--
--  1. Cuando se asigna una tarjeta a alguien, esa persona recibe un correo.
--  2. Cada mañana, cada persona recibe UN correo con sus tareas vencidas,
--     que vencen hoy y que vencen mañana (solo si tiene alguna).
--
-- Los correos se envían con Resend (https://resend.com) desde la propia base de datos.
-- La clave de Resend se guarda cifrada en Supabase Vault (ver README, paso "Avisos por correo").

-- ============ Extensiones ============
-- Si alguna da error de permisos, actívala en Database → Extensions y vuelve a ejecutar.
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ============ Estado "completada" de una tarjeta ============
alter table public.cards add column if not exists done boolean not null default false;

-- ============ Registro de resúmenes enviados (evita duplicados el mismo día) ============
create table if not exists public.reminder_log (
  user_id uuid not null references public.profiles(id) on delete cascade,
  sent_on date not null,
  primary key (user_id, sent_on)
);
alter table public.reminder_log enable row level security;
revoke all on public.reminder_log from anon, authenticated;

-- ============ Utilidades ============

create or replace function public.html_escape(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;')
$$;

-- Envía un correo con Resend. Lee la clave y el remitente de Vault.
create or replace function public.send_email(p_to text, p_subject text, p_html text) returns void
language plpgsql security definer set search_path = public as $$
declare k text; f text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'resend_api_key';
  select decrypted_secret into f from vault.decrypted_secrets where name = 'mail_from';
  if k is null or f is null then
    raise warning 'send_email: faltan los secretos resend_api_key y/o mail_from en Vault';
    return;
  end if;
  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object('Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object('from', f, 'to', jsonb_build_array(p_to), 'subject', p_subject, 'html', p_html)
  );
end $$;

-- ============ 1. Aviso al asignar una tarjeta ============

create or replace function public.notify_card_assigned() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  site constant text := 'https://proyectojc.oscarzarateph.com/';
  old_a uuid[] := case when tg_op = 'UPDATE' then old.assignees else '{}'::uuid[] end;
  actor text; bname text; r record;
begin
  if tg_op = 'UPDATE' and new.assignees is not distinct from old.assignees then
    return new;
  end if;
  select coalesce(display_name, email) into actor from profiles where id = auth.uid();
  select name into bname from boards where id = new.board_id;

  for r in
    select p.email, coalesce(p.display_name, split_part(p.email, '@', 1)) as nm
    from profiles p
    where p.id = any (new.assignees)
      and not (p.id = any (old_a))
      and p.id is distinct from auth.uid()
      and exists (select 1 from board_members m where m.board_id = new.board_id and m.user_id = p.id)
  loop
    begin
      perform public.send_email(
        r.email,
        'Te asignaron una tarea: ' || new.title,
        format(
          '<div style="font-family:system-ui,Arial,sans-serif;max-width:520px;color:#172b4d">'
          '<p>Hola %s,</p>'
          '<p><b>%s</b> te asignó una tarea en el tablero <b>%s</b>:</p>'
          '<p style="background:#f4f5f7;border-radius:8px;padding:12px 14px;font-size:16px">%s</p>'
          '<p>Fecha límite: <b>%s</b></p>'
          '<p><a href="%s?b=%s" style="background:#0c66e4;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Abrir el tablero</a></p>'
          '</div>',
          html_escape(r.nm), html_escape(coalesce(actor, 'Alguien')), html_escape(bname), html_escape(new.title),
          coalesce(to_char(new.due, 'DD/MM/YYYY'), 'sin fecha'), site, new.board_id)
      );
    exception when others then
      raise warning 'No se pudo avisar a %: %', r.email, sqlerrm;  -- un fallo de correo nunca debe impedir guardar la tarjeta
    end;
  end loop;
  return new;
end $$;

drop trigger if exists cards_notify_assigned on public.cards;
create trigger cards_notify_assigned after insert or update of assignees on public.cards
  for each row execute function public.notify_card_assigned();

-- ============ 2. Resumen diario de tareas con fecha límite ============

-- Tareas pendientes de una persona: vencidas (hasta 7 días atrás), de hoy y de mañana.
-- Se ignoran las completadas y las que están en una lista llamada "Hecho", "Terminado", "Completado", etc.
create or replace function public.pending_for(u uuid, today date)
returns table (title text, board_id uuid, board_name text, due date)
language sql stable security definer set search_path = public as $$
  select c.title, c.board_id, b.name, c.due
  from cards c
  join boards b on b.id = c.board_id
  join lists l on l.id = c.list_id
  where u = any (c.assignees)
    and c.due is not null
    and not c.done
    and c.due between today - 7 and today + 1
    and l.title !~* '^\s*(hech[oa]s?|done|terminad[oa]s?|completad[oa]s?|finalizad[oa]s?)\s*$'
    and exists (select 1 from board_members m where m.board_id = c.board_id and m.user_id = u)
  order by c.due, c.title
$$;

create or replace function public.reminder_section(u uuid, today date, kind text, heading text, color text)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  site constant text := 'https://proyectojc.oscarzarateph.com/';
  items text;
begin
  select string_agg(format(
      '<li style="margin:5px 0"><a href="%s?b=%s" style="color:#0c66e4;text-decoration:none">%s</a> <span style="color:#6b778c">— %s · %s</span></li>',
      site, p.board_id, html_escape(p.title), html_escape(p.board_name), to_char(p.due, 'DD/MM')), '')
  into items
  from pending_for(u, today) p
  where case kind when 'late' then p.due < today when 'today' then p.due = today else p.due = today + 1 end;
  if items is null then return ''; end if;
  return format('<h3 style="margin:20px 0 6px;font-size:15px;color:%s">%s</h3><ul style="padding-left:18px;margin:0">%s</ul>', color, heading, items);
end $$;

-- Envía el resumen a cada persona que tenga algo pendiente. Devuelve cuántos correos envió.
-- Con p_force = true ignora si ya se envió hoy (útil para probar).
create or replace function public.send_due_reminders(p_force boolean default false) returns integer
language plpgsql security definer set search_path = public as $$
declare
  tz constant text := 'America/Bogota';           -- zona horaria para decidir qué es "hoy"
  site constant text := 'https://proyectojc.oscarzarateph.com/';
  today date := (now() at time zone tz)::date;
  u record; total int; n int := 0; body text;
begin
  for u in
    select p.id, p.email, coalesce(p.display_name, split_part(p.email, '@', 1)) as nm
    from profiles p
    where exists (select 1 from pending_for(p.id, today))
  loop
    if not p_force and exists (select 1 from reminder_log where user_id = u.id and sent_on = today) then
      continue;
    end if;
    select count(*) into total from pending_for(u.id, today);
    body := public.reminder_section(u.id, today, 'late', 'Vencidas', '#c9372c')
         || public.reminder_section(u.id, today, 'today', 'Vencen hoy', '#b65c02')
         || public.reminder_section(u.id, today, 'tomorrow', 'Vencen mañana', '#1f845a');
    begin
      perform public.send_email(
        u.email,
        format('Recordatorio: %s %s por atender', total, case when total = 1 then 'tarea' else 'tareas' end),
        format('<div style="font-family:system-ui,Arial,sans-serif;max-width:520px;color:#172b4d"><p>Hola %s, estas son tus tareas con fecha límite:</p>%s<p style="margin-top:24px"><a href="%s" style="color:#0c66e4">Abrir Proyecto JC</a></p></div>',
               html_escape(u.nm), body, site));
      insert into reminder_log (user_id, sent_on) values (u.id, today) on conflict do nothing;
      n := n + 1;
    exception when others then
      raise warning 'No se pudo enviar el recordatorio a %: %', u.email, sqlerrm;
    end;
  end loop;
  return n;
end $$;

-- Todos los días a las 13:00 UTC (8:00 a. m. en Colombia).
select cron.schedule('recordatorios-diarios', '0 13 * * *', 'select public.send_due_reminders()');

-- ============ Permisos ============
-- Estas funciones solo las usa la base de datos; nadie desde la web puede llamarlas.
revoke execute on function public.send_email(text, text, text) from public, anon, authenticated;
revoke execute on function public.notify_card_assigned() from public, anon, authenticated;
revoke execute on function public.pending_for(uuid, date) from public, anon, authenticated;
revoke execute on function public.reminder_section(uuid, date, text, text, text) from public, anon, authenticated;
revoke execute on function public.send_due_reminders(boolean) from public, anon, authenticated;
