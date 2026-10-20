-- Proyecto JC · actualización 2: archivar y etiquetas con nombre
-- Ejecutar una sola vez en Supabase → SQL Editor, DESPUÉS de schema.sql y notifications.sql.
-- No borra ni modifica datos existentes.

-- Archivar tarjetas y listas en vez de borrarlas
alter table public.cards add column if not exists archived boolean not null default false;
alter table public.lists add column if not exists archived boolean not null default false;

-- Nombres de las etiquetas por tablero, por ejemplo {"#f87168": "Urgente"}
alter table public.boards add column if not exists label_names jsonb not null default '{}';
grant update (label_names) on public.boards to authenticated;

-- Los recordatorios por correo ignoran lo archivado
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
    and not c.archived
    and not l.archived
    and c.due between today - 7 and today + 1
    and l.title !~* '^\s*(hech[oa]s?|done|terminad[oa]s?|completad[oa]s?|finalizad[oa]s?)\s*$'
    and exists (select 1 from board_members m where m.board_id = c.board_id and m.user_id = u)
  order by c.due, c.title
$$;
