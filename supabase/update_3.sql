-- Proyecto JC · actualización 3: historial de actividad y más avisos por correo
-- Ejecutar una sola vez en Supabase → SQL Editor, DESPUÉS de update_2.sql.
-- No borra ni modifica datos existentes.
--
--  · Historial: quién creó, movió, completó, archivó o asignó cada tarjeta, y cuándo.
--  · Correo al comentar (a las personas asignadas) y al mencionar con @ (a la persona mencionada).
--  · Correo cuando cambia la fecha límite de una tarjeta asignada.

-- ============ Historial ============

create table if not exists public.activity (
  id         uuid primary key default gen_random_uuid(),
  board_id   uuid not null references public.boards(id) on delete cascade,
  card_id    uuid,
  user_id    uuid default auth.uid() references public.profiles(id) on delete set null,
  kind       text not null,
  detail     jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists activity_board_idx on public.activity (board_id, created_at desc);
create index if not exists activity_card_idx on public.activity (card_id, created_at desc);

alter table public.activity enable row level security;
drop policy if exists activity_select on public.activity;
create policy activity_select on public.activity for select to authenticated
  using (is_board_member(board_id));
revoke all on public.activity from anon, authenticated;
grant select on public.activity to authenticated;
-- Nadie escribe aquí desde la web: lo hacen los triggers de abajo.

-- Tarjetas
create or replace function public.log_card_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  added jsonb; removed jsonb; rid uuid;
begin
  if tg_op = 'DELETE' then
    -- si el tablero ya no existe (se está borrando entero), no se registra nada
    if exists (select 1 from boards where id = old.board_id) then
      insert into activity (board_id, card_id, kind, detail)
      values (old.board_id, old.id, 'card_deleted', jsonb_build_object('title', old.title));
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    insert into activity (board_id, card_id, kind, detail)
    values (new.board_id, new.id, 'card_created',
            jsonb_build_object('title', new.title, 'list', (select title from lists where id = new.list_id)));
    return new;
  end if;

  if new.list_id is distinct from old.list_id then
    insert into activity (board_id, card_id, kind, detail)
    values (new.board_id, new.id, 'card_moved', jsonb_build_object('title', new.title,
            'from', (select title from lists where id = old.list_id), 'to', (select title from lists where id = new.list_id)));
  end if;

  if new.title is distinct from old.title then
    -- al escribir un título se guarda varias veces; se junta en una sola entrada si es reciente
    select id into rid from activity
     where card_id = new.id and kind = 'card_renamed' and user_id is not distinct from auth.uid()
       and created_at > now() - interval '10 minutes'
     order by created_at desc limit 1;
    if rid is not null then
      update activity set detail = jsonb_set(detail, '{to}', to_jsonb(new.title)), created_at = now() where id = rid;
    else
      insert into activity (board_id, card_id, kind, detail)
      values (new.board_id, new.id, 'card_renamed', jsonb_build_object('from', old.title, 'to', new.title));
    end if;
  end if;

  if new.due is distinct from old.due then
    insert into activity (board_id, card_id, kind, detail)
    values (new.board_id, new.id, 'due_changed', jsonb_build_object('title', new.title, 'from', old.due, 'to', new.due));
  end if;

  if new.done is distinct from old.done then
    insert into activity (board_id, card_id, kind, detail)
    values (new.board_id, new.id, case when new.done then 'card_done' else 'card_undone' end, jsonb_build_object('title', new.title));
  end if;

  if new.archived is distinct from old.archived then
    insert into activity (board_id, card_id, kind, detail)
    values (new.board_id, new.id, case when new.archived then 'card_archived' else 'card_restored' end, jsonb_build_object('title', new.title));
  end if;

  if new.assignees is distinct from old.assignees then
    select coalesce(jsonb_agg(coalesce(p.display_name, p.email)), '[]') into added
      from profiles p where p.id = any (new.assignees) and not (p.id = any (old.assignees));
    select coalesce(jsonb_agg(coalesce(p.display_name, p.email)), '[]') into removed
      from profiles p where p.id = any (old.assignees) and not (p.id = any (new.assignees));
    insert into activity (board_id, card_id, kind, detail)
    values (new.board_id, new.id, 'assigned', jsonb_build_object('title', new.title, 'added', added, 'removed', removed));
  end if;
  return new;
end $$;

drop trigger if exists cards_log on public.cards;
create trigger cards_log after insert or update or delete on public.cards
  for each row execute function public.log_card_activity();

-- Listas
create or replace function public.log_list_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into activity (board_id, kind, detail) values (new.board_id, 'list_created', jsonb_build_object('title', new.title));
  elsif new.archived is distinct from old.archived then
    insert into activity (board_id, kind, detail)
    values (new.board_id, case when new.archived then 'list_archived' else 'list_restored' end, jsonb_build_object('title', new.title));
  end if;
  return new;
end $$;

drop trigger if exists lists_log on public.lists;
create trigger lists_log after insert or update on public.lists
  for each row execute function public.log_list_activity();

-- Comentarios
create or replace function public.log_comment_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into activity (board_id, card_id, user_id, kind, detail)
  values (new.board_id, new.card_id, new.user_id, 'commented',
          jsonb_build_object('title', (select title from cards where id = new.card_id), 'excerpt', left(new.body, 140)));
  return new;
end $$;

drop trigger if exists comments_log on public.comments;
create trigger comments_log after insert on public.comments
  for each row execute function public.log_comment_activity();

-- Se conservan 180 días de historial
select cron.schedule('limpiar-actividad', '30 5 * * *', $$delete from public.activity where created_at < now() - interval '180 days'$$);

-- ============ Correos nuevos ============

-- El aviso de asignación ahora enlaza directamente a la tarjeta
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
          '<p><a href="%s?b=%s&c=%s" style="background:#0c66e4;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Abrir la tarjeta</a></p>'
          '</div>',
          html_escape(r.nm), html_escape(coalesce(actor, 'Alguien')), html_escape(bname), html_escape(new.title),
          coalesce(to_char(new.due, 'DD/MM/YYYY'), 'sin fecha'), site, new.board_id, new.id)
      );
    exception when others then
      raise warning 'No se pudo avisar a %: %', r.email, sqlerrm;
    end;
  end loop;
  return new;
end $$;

-- Cambio de fecha límite: avisa a las personas asignadas
create or replace function public.notify_due_changed() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  site constant text := 'https://proyectojc.oscarzarateph.com/';
  actor text; bname text; r record;
begin
  if new.due is not distinct from old.due or new.done or new.archived or cardinality(new.assignees) = 0 then
    return new;
  end if;
  select coalesce(display_name, email) into actor from profiles where id = auth.uid();
  select name into bname from boards where id = new.board_id;
  for r in
    select p.email, coalesce(p.display_name, split_part(p.email, '@', 1)) as nm
    from profiles p
    where p.id = any (new.assignees)
      and p.id is distinct from auth.uid()
      and exists (select 1 from board_members m where m.board_id = new.board_id and m.user_id = p.id)
  loop
    begin
      perform public.send_email(
        r.email,
        'Cambió la fecha límite: ' || new.title,
        format(
          '<div style="font-family:system-ui,Arial,sans-serif;max-width:520px;color:#172b4d">'
          '<p>Hola %s,</p>'
          '<p><b>%s</b> cambió la fecha límite de una tarea tuya en el tablero <b>%s</b>:</p>'
          '<p style="background:#f4f5f7;border-radius:8px;padding:12px 14px;font-size:16px">%s</p>'
          '<p>Antes: <b>%s</b> &nbsp;→&nbsp; Ahora: <b>%s</b></p>'
          '<p><a href="%s?b=%s&c=%s" style="background:#0c66e4;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Abrir la tarjeta</a></p>'
          '</div>',
          html_escape(r.nm), html_escape(coalesce(actor, 'Alguien')), html_escape(bname), html_escape(new.title),
          coalesce(to_char(old.due, 'DD/MM/YYYY'), 'sin fecha'), coalesce(to_char(new.due, 'DD/MM/YYYY'), 'sin fecha'),
          site, new.board_id, new.id)
      );
    exception when others then
      raise warning 'No se pudo avisar a %: %', r.email, sqlerrm;
    end;
  end loop;
  return new;
end $$;

drop trigger if exists cards_notify_due on public.cards;
create trigger cards_notify_due after update of due on public.cards
  for each row execute function public.notify_due_changed();

-- Comentarios: avisa a las personas asignadas a la tarjeta y a quien se mencione con @usuario
-- (@usuario es la parte del correo antes de la @, por ejemplo @maria para maria@correo.com)
create or replace function public.notify_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  site constant text := 'https://proyectojc.oscarzarateph.com/';
  c cards%rowtype; author text; bname text; r record; subj text; lead text;
begin
  select * into c from cards where id = new.card_id;
  if not found then return new; end if;
  select coalesce(display_name, email) into author from profiles where id = new.user_id;
  select name into bname from boards where id = new.board_id;

  for r in
    select * from (
      select p.id, p.email, coalesce(p.display_name, split_part(p.email, '@', 1)) as nm,
             (new.body ~* ('(^|[^[:alnum:]_.])@' || replace(replace(lower(split_part(p.email, '@', 1)), '.', '\.'), '+', '\+') || '($|[^[:alnum:]_])')) as mentioned,
             (p.id = any (c.assignees)) as assigned
      from profiles p
      where p.id is distinct from new.user_id
        and exists (select 1 from board_members m where m.board_id = new.board_id and m.user_id = p.id)
    ) q
    where q.mentioned or q.assigned
  loop
    begin
      if r.mentioned then
        subj := coalesce(author, 'Alguien') || ' te mencionó en: ' || c.title;
        lead := ' te mencionó en un comentario';
      else
        subj := 'Nuevo comentario en: ' || c.title;
        lead := ' comentó en una tarea tuya';
      end if;
      perform public.send_email(
        r.email, subj,
        format(
          '<div style="font-family:system-ui,Arial,sans-serif;max-width:520px;color:#172b4d">'
          '<p>Hola %s,</p>'
          '<p><b>%s</b>%s, en la tarjeta <b>%s</b> del tablero <b>%s</b>:</p>'
          '<blockquote style="margin:0;border-left:4px solid #0c66e4;background:#f4f5f7;padding:10px 14px;white-space:pre-wrap">%s</blockquote>'
          '<p><a href="%s?b=%s&c=%s" style="background:#0c66e4;color:#fff;padding:10px 16px;border-radius:6px;text-decoration:none">Abrir la tarjeta</a></p>'
          '</div>',
          html_escape(r.nm), html_escape(coalesce(author, 'Alguien')), lead, html_escape(c.title), html_escape(bname),
          html_escape(left(new.body, 600)), site, new.board_id, new.card_id)
      );
    exception when others then
      raise warning 'No se pudo avisar a %: %', r.email, sqlerrm;
    end;
  end loop;
  return new;
end $$;

drop trigger if exists comments_notify on public.comments;
create trigger comments_notify after insert on public.comments
  for each row execute function public.notify_comment();

-- ============ Permisos ============
revoke execute on function public.log_card_activity() from public, anon, authenticated;
revoke execute on function public.log_list_activity() from public, anon, authenticated;
revoke execute on function public.log_comment_activity() from public, anon, authenticated;
revoke execute on function public.notify_card_assigned() from public, anon, authenticated;
revoke execute on function public.notify_due_changed() from public, anon, authenticated;
revoke execute on function public.notify_comment() from public, anon, authenticated;
