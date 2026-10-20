-- Proyecto JC · esquema de base de datos para Supabase
-- Ejecutar una sola vez en Supabase → SQL Editor → New query → Run.

-- ============ Tablas ============

create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  display_name text,
  created_at   timestamptz not null default now()
);
create unique index profiles_email_key on public.profiles (lower(email));

create table public.boards (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 120),
  bg         text not null default '#0c66e4',
  owner_id   uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.board_members (
  board_id   uuid not null references public.boards(id) on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (board_id, user_id)
);
create index board_members_user_idx on public.board_members (user_id);

create table public.lists (
  id         uuid primary key default gen_random_uuid(),
  board_id   uuid not null references public.boards(id) on delete cascade,
  title      text not null default '' check (char_length(title) <= 200),
  pos        double precision not null default 0,
  created_at timestamptz not null default now(),
  unique (id, board_id)
);
create index lists_board_idx on public.lists (board_id);

create table public.cards (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid not null,
  list_id     uuid not null,
  title       text not null check (char_length(title) between 1 and 500),
  description text not null default '' check (char_length(description) <= 20000),
  labels      text[] not null default '{}',
  due         date,
  assignees   uuid[] not null default '{}',
  checklist   jsonb not null default '[]',
  pos         double precision not null default 0,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (id, board_id),
  -- la lista debe pertenecer al mismo tablero que la tarjeta
  foreign key (list_id, board_id) references public.lists (id, board_id) on delete cascade
);
create index cards_board_idx on public.cards (board_id);

create table public.comments (
  id         uuid primary key default gen_random_uuid(),
  board_id   uuid not null,
  card_id    uuid not null,
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now(),
  foreign key (card_id, board_id) references public.cards (id, board_id) on delete cascade
);
create index comments_card_idx on public.comments (card_id);

-- ============ Funciones auxiliares ============

create function public.is_board_member(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from board_members where board_id = b and user_id = auth.uid());
$$;

create function public.is_board_owner(b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from board_members where board_id = b and user_id = auth.uid() and role = 'owner');
$$;

create function public.shares_board_with(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from board_members a
    join board_members b on a.board_id = b.board_id
    where a.user_id = auth.uid() and b.user_id = u
  );
$$;

-- Invitar a un usuario existente (solo el propietario del tablero)
create function public.invite_to_board(p_board uuid, p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if not is_board_owner(p_board) then
    raise exception 'Solo el propietario puede invitar' using errcode = '42501';
  end if;
  select id into v from profiles where lower(email) = lower(trim(p_email));
  if v is null then
    raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into board_members (board_id, user_id, role) values (p_board, v, 'member')
  on conflict do nothing;
end $$;

-- ============ Triggers ============

-- Crea el perfil cuando se crea un usuario en Authentication
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, display_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Usuarios que ya existieran antes de ejecutar este script
insert into public.profiles (id, email, display_name)
select id, email, split_part(email, '@', 1) from auth.users
on conflict (id) do nothing;

-- El creador de un tablero pasa a ser su propietario
create function public.handle_new_board() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into board_members (board_id, user_id, role) values (new.id, new.owner_id, 'owner');
  return new;
end $$;
create trigger on_board_created after insert on public.boards
  for each row execute function public.handle_new_board();

create function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;
create trigger cards_touch before update on public.cards
  for each row execute function public.touch_updated_at();

-- ============ Seguridad (Row Level Security) ============

alter table public.profiles      enable row level security;
alter table public.boards        enable row level security;
alter table public.board_members enable row level security;
alter table public.lists         enable row level security;
alter table public.cards         enable row level security;
alter table public.comments      enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or shares_board_with(id));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- owner_id = auth.uid() permite leer el tablero recién creado antes de que el trigger sea visible
create policy boards_select on public.boards for select to authenticated
  using (is_board_member(id) or owner_id = auth.uid());
create policy boards_insert on public.boards for insert to authenticated
  with check (owner_id = auth.uid());
create policy boards_update on public.boards for update to authenticated
  using (is_board_member(id)) with check (is_board_member(id));
create policy boards_delete on public.boards for delete to authenticated
  using (is_board_owner(id));

create policy members_select on public.board_members for select to authenticated
  using (is_board_member(board_id));
-- El propietario expulsa a otros; cualquier miembro (no propietario) puede salirse.
create policy members_delete on public.board_members for delete to authenticated
  using (
    (is_board_owner(board_id) and user_id <> auth.uid())
    or (user_id = auth.uid() and role <> 'owner')
  );

create policy lists_all on public.lists for all to authenticated
  using (is_board_member(board_id)) with check (is_board_member(board_id));
create policy cards_all on public.cards for all to authenticated
  using (is_board_member(board_id)) with check (is_board_member(board_id));

create policy comments_select on public.comments for select to authenticated
  using (is_board_member(board_id));
create policy comments_insert on public.comments for insert to authenticated
  with check (is_board_member(board_id) and user_id = auth.uid());
create policy comments_delete on public.comments for delete to authenticated
  using (user_id = auth.uid() and is_board_member(board_id));

-- ============ Permisos de la API ============
-- Sin sesión (anon) no se puede leer ni escribir nada.

revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon;

grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant select, insert, delete on public.boards to authenticated;
grant update (name, bg) on public.boards to authenticated;
grant select, delete on public.board_members to authenticated;
grant select, insert, update, delete on public.lists, public.cards to authenticated;
grant select, insert, delete on public.comments to authenticated;

grant execute on function public.is_board_member(uuid) to authenticated;
grant execute on function public.is_board_owner(uuid) to authenticated;
grant execute on function public.shares_board_with(uuid) to authenticated;
grant execute on function public.invite_to_board(uuid, text) to authenticated;

-- ============ Tiempo real ============

do $$
declare t text;
begin
  foreach t in array array['boards', 'lists', 'cards', 'comments', 'board_members'] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
