-- Formula Life online play: accounts, friends, race rooms.
-- All access goes through the functions below; the tables have row level security on and no policies,
-- so nobody can read or write them directly. Only signed-in users can call the functions.

create table if not exists public.mp_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,16}$'),
  last_seen timestamptz not null default now()
);
create unique index if not exists mp_profiles_username on public.mp_profiles (lower(username));

create table if not exists public.mp_friends (
  a uuid not null references public.mp_profiles(id) on delete cascade,
  b uuid not null references public.mp_profiles(id) on delete cascade,
  accepted boolean not null default false,
  created timestamptz not null default now(),
  primary key (a, b),
  check (a <> b)
);
create unique index if not exists mp_friends_pair on public.mp_friends (least(a, b), greatest(a, b));

create table if not exists public.mp_rooms (
  id uuid primary key default gen_random_uuid(),
  host uuid not null references public.mp_profiles(id) on delete cascade,
  tier int not null default 0,
  lvl int not null default 1,
  trk int not null default 0,
  wet boolean not null default false,
  status text not null default 'lobby',
  created timestamptz not null default now()
);

create table if not exists public.mp_members (
  room uuid not null references public.mp_rooms(id) on delete cascade,
  uid uuid not null references public.mp_profiles(id) on delete cascade,
  joined boolean not null default false,
  primary key (room, uid)
);

alter table public.mp_profiles enable row level security;
alter table public.mp_friends enable row level security;
alter table public.mp_rooms enable row level security;
alter table public.mp_members enable row level security;
revoke all on public.mp_profiles, public.mp_friends, public.mp_rooms, public.mp_members from anon, authenticated;

-- profile -------------------------------------------------------------
create or replace function public.mp_me() returns json
language sql security definer set search_path = public as $$
  select to_json(p) from (select id, username from public.mp_profiles where id = auth.uid()) p;
$$;

create or replace function public.mp_set_username(u text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if u !~ '^[A-Za-z0-9_]{3,16}$' then raise exception 'Username: 3 to 16 letters, numbers or _'; end if;
  begin
    insert into public.mp_profiles (id, username) values (auth.uid(), u)
      on conflict (id) do update set username = excluded.username;
  exception when unique_violation then
    raise exception 'That username is taken';
  end;
end $$;

create or replace function public.mp_heartbeat() returns void
language sql security definer set search_path = public as $$
  update public.mp_profiles set last_seen = now() where id = auth.uid();
$$;

-- friends -------------------------------------------------------------
create or replace function public.mp_friends() returns table (uid uuid, username text, rel text, online boolean)
language sql security definer set search_path = public as $$
  select p.id, p.username,
         case when f.accepted then 'friend' when f.a = auth.uid() then 'outgoing' else 'incoming' end,
         (f.accepted and p.last_seen > now() - interval '60 seconds')
  from public.mp_friends f
  join public.mp_profiles p on p.id = case when f.a = auth.uid() then f.b else f.a end
  where auth.uid() in (f.a, f.b)
  order by f.accepted desc, p.username;
$$;

create or replace function public.mp_request(u text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid; ex public.mp_friends;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select id into t from public.mp_profiles where lower(username) = lower(u);
  if t is null then raise exception 'No player with that username'; end if;
  if t = auth.uid() then raise exception 'That is you'; end if;
  select * into ex from public.mp_friends where (a = t and b = auth.uid()) or (a = auth.uid() and b = t);
  if found then
    if ex.accepted then raise exception 'Already friends'; end if;
    if ex.a = t then
      update public.mp_friends set accepted = true where a = t and b = auth.uid();
      return 'accepted';
    end if;
    raise exception 'Request already sent';
  end if;
  insert into public.mp_friends (a, b) values (auth.uid(), t);
  return 'sent';
end $$;

create or replace function public.mp_respond(other uuid, accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if accept then
    update public.mp_friends set accepted = true where a = other and b = auth.uid();
  else
    delete from public.mp_friends where a = other and b = auth.uid() and not accepted;
  end if;
end $$;

create or replace function public.mp_unfriend(other uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.mp_friends where (a = other and b = auth.uid()) or (a = auth.uid() and b = other);
$$;

-- race rooms ----------------------------------------------------------
create or replace function public.mp_create_room(tier_ int, lvl_ int, trk_ int, wet_ boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if auth.uid() is null or not exists (select 1 from public.mp_profiles where id = auth.uid()) then raise exception 'Not signed in'; end if;
  delete from public.mp_rooms where created < now() - interval '6 hours';
  delete from public.mp_rooms where host = auth.uid();
  insert into public.mp_rooms (host, tier, lvl, trk, wet)
    values (auth.uid(), least(greatest(tier_, 0), 5), least(greatest(lvl_, 1), 10), least(greatest(trk_, 0), 9), wet_)
    returning id into rid;
  insert into public.mp_members (room, uid, joined) values (rid, auth.uid(), true);
  return rid;
end $$;

create or replace function public.mp_room_set(rid uuid, tier_ int, lvl_ int, trk_ int, wet_ boolean) returns void
language sql security definer set search_path = public as $$
  update public.mp_rooms set tier = least(greatest(tier_, 0), 5), lvl = least(greatest(lvl_, 1), 10),
         trk = least(greatest(trk_, 0), 9), wet = wet_
  where id = rid and host = auth.uid() and status = 'lobby';
$$;

create or replace function public.mp_invite(rid uuid, other uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.mp_rooms where id = rid and host = auth.uid() and status = 'lobby') then raise exception 'Only the host can invite'; end if;
  if not exists (select 1 from public.mp_friends where accepted and ((a = auth.uid() and b = other) or (b = auth.uid() and a = other))) then raise exception 'You can only invite friends'; end if;
  if (select count(*) from public.mp_members where room = rid) >= 4 then raise exception 'The room is full (4 players)'; end if;
  insert into public.mp_members (room, uid, joined) values (rid, other, false) on conflict do nothing;
end $$;

create or replace function public.mp_invites() returns table (room uuid, host_name text, tier int, lvl int, wet boolean)
language sql security definer set search_path = public as $$
  select r.id, p.username, r.tier, r.lvl, r.wet
  from public.mp_members m
  join public.mp_rooms r on r.id = m.room
  join public.mp_profiles p on p.id = r.host
  where m.uid = auth.uid() and not m.joined and r.status = 'lobby' and r.created > now() - interval '2 hours';
$$;

create or replace function public.mp_join(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.mp_rooms where id = rid and status = 'lobby') then raise exception 'The room is closed'; end if;
  update public.mp_members set joined = true where room = rid and uid = auth.uid();
  if not found then raise exception 'You are not invited'; end if;
end $$;

create or replace function public.mp_leave(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.mp_rooms where id = rid and host = auth.uid()) then
    delete from public.mp_rooms where id = rid;
  else
    delete from public.mp_members where room = rid and uid = auth.uid();
  end if;
end $$;

create or replace function public.mp_room(rid uuid) returns json
language plpgsql security definer set search_path = public as $$
declare res json;
begin
  if not exists (select 1 from public.mp_members where room = rid and uid = auth.uid()) then return null; end if;
  select json_build_object(
    'id', r.id, 'tier', r.tier, 'lvl', r.lvl, 'trk', r.trk, 'wet', r.wet, 'status', r.status, 'host', r.host,
    'members', (select coalesce(json_agg(json_build_object('uid', m.uid, 'name', p.username, 'joined', m.joined, 'host', m.uid = r.host) order by (m.uid = r.host) desc, p.username), '[]'::json)
                from public.mp_members m join public.mp_profiles p on p.id = m.uid where m.room = r.id))
  into res from public.mp_rooms r where r.id = rid;
  return res;
end $$;

create or replace function public.mp_room_status(rid uuid, st text) returns void
language sql security definer set search_path = public as $$
  update public.mp_rooms set status = st where id = rid and host = auth.uid() and st in ('lobby', 'racing');
$$;

-- realtime: only joined members may use the room channel "room:<id>" ----------
create or replace function public.mp_can_room(topic text) returns boolean
language plpgsql security definer stable set search_path = public as $$
declare rid uuid;
begin
  if topic is null or topic not like 'room:%' then return false; end if;
  begin rid := substring(topic from 6)::uuid; exception when others then return false; end;
  return exists (select 1 from public.mp_members where room = rid and uid = auth.uid() and joined);
end $$;

revoke all on function public.mp_me(), public.mp_set_username(text), public.mp_heartbeat(), public.mp_friends(), public.mp_request(text),
  public.mp_respond(uuid, boolean), public.mp_unfriend(uuid), public.mp_create_room(int, int, int, boolean),
  public.mp_room_set(uuid, int, int, int, boolean), public.mp_invite(uuid, uuid), public.mp_invites(), public.mp_join(uuid),
  public.mp_leave(uuid), public.mp_room(uuid), public.mp_room_status(uuid, text), public.mp_can_room(text) from public, anon;
grant execute on function public.mp_me(), public.mp_set_username(text), public.mp_heartbeat(), public.mp_friends(), public.mp_request(text),
  public.mp_respond(uuid, boolean), public.mp_unfriend(uuid), public.mp_create_room(int, int, int, boolean),
  public.mp_room_set(uuid, int, int, int, boolean), public.mp_invite(uuid, uuid), public.mp_invites(), public.mp_join(uuid),
  public.mp_leave(uuid), public.mp_room(uuid), public.mp_room_status(uuid, text), public.mp_can_room(text) to authenticated;

drop policy if exists mp_room_read on realtime.messages;
drop policy if exists mp_room_write on realtime.messages;
create policy mp_room_read on realtime.messages for select to authenticated using (public.mp_can_room((select realtime.topic())));
create policy mp_room_write on realtime.messages for insert to authenticated with check (public.mp_can_room((select realtime.topic())));

-- Formula Life online play, part 2: room codes, guests (join with a code, no account), username checks.

alter table public.mp_rooms add column if not exists code text;
create unique index if not exists mp_rooms_code on public.mp_rooms (code);

create or replace function public.mp_is_guest() returns boolean
language sql stable set search_path = public as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
$$;

-- which of these usernames are still free (callable before signing up)
create or replace function public.mp_free_names(names text[]) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(n), '{}') from unnest(names) n
  where n ~ '^[A-Za-z0-9_]{3,16}$' and not exists (select 1 from public.mp_profiles p where lower(p.username) = lower(n));
$$;

create or replace function public.mp_create_room(tier_ int, lvl_ int, trk_ int, wet_ boolean) returns uuid
language plpgsql security definer set search_path = public as $$
declare rid uuid; c text; k int := 0; chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null or not exists (select 1 from public.mp_profiles where id = auth.uid()) then raise exception 'Not signed in'; end if;
  if public.mp_is_guest() then raise exception 'Guests can only join a room with a code'; end if;
  delete from public.mp_rooms where created < now() - interval '6 hours';
  delete from auth.users where is_anonymous and created_at < now() - interval '2 days';
  delete from public.mp_rooms where host = auth.uid();
  loop
    c := ''; for k in 1..6 loop c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from public.mp_rooms where code = c);
  end loop;
  insert into public.mp_rooms (host, tier, lvl, trk, wet, code)
    values (auth.uid(), least(greatest(tier_, 0), 5), least(greatest(lvl_, 1), 10), least(greatest(trk_, 0), 9), wet_, c)
    returning id into rid;
  insert into public.mp_members (room, uid, joined) values (rid, auth.uid(), true);
  return rid;
end $$;

create or replace function public.mp_join_code(c text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.mp_rooms;
begin
  if auth.uid() is null or not exists (select 1 from public.mp_profiles where id = auth.uid()) then raise exception 'Not signed in'; end if;
  select * into r from public.mp_rooms where code = upper(trim(c)) and status = 'lobby' and created > now() - interval '6 hours';
  if not found then raise exception 'No open room with that code'; end if;
  if not exists (select 1 from public.mp_members where room = r.id and uid = auth.uid()) and (select count(*) from public.mp_members where room = r.id) >= 4 then
    raise exception 'The room is full (4 players)';
  end if;
  insert into public.mp_members (room, uid, joined) values (r.id, auth.uid(), true) on conflict (room, uid) do update set joined = true;
  return r.id;
end $$;

create or replace function public.mp_room(rid uuid) returns json
language plpgsql security definer set search_path = public as $$
declare res json;
begin
  if not exists (select 1 from public.mp_members where room = rid and uid = auth.uid()) then return null; end if;
  select json_build_object(
    'id', r.id, 'tier', r.tier, 'lvl', r.lvl, 'trk', r.trk, 'wet', r.wet, 'status', r.status, 'host', r.host,
    'code', case when r.host = auth.uid() then r.code else null end,
    'members', (select coalesce(json_agg(json_build_object('uid', m.uid, 'name', p.username, 'joined', m.joined, 'host', m.uid = r.host) order by (m.uid = r.host) desc, p.username), '[]'::json)
                from public.mp_members m join public.mp_profiles p on p.id = m.uid where m.room = r.id))
  into res from public.mp_rooms r where r.id = rid;
  return res;
end $$;

-- guests cannot send friend requests
create or replace function public.mp_request(u text) returns text
language plpgsql security definer set search_path = public as $$
declare t uuid; ex public.mp_friends;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if public.mp_is_guest() then raise exception 'Guests cannot add friends. Create an account first'; end if;
  select id into t from public.mp_profiles where lower(username) = lower(u);
  if t is null then raise exception 'No player with that username'; end if;
  if t = auth.uid() then raise exception 'That is you'; end if;
  select * into ex from public.mp_friends where (a = t and b = auth.uid()) or (a = auth.uid() and b = t);
  if found then
    if ex.accepted then raise exception 'Already friends'; end if;
    if ex.a = t then
      update public.mp_friends set accepted = true where a = t and b = auth.uid();
      return 'accepted';
    end if;
    raise exception 'Request already sent';
  end if;
  insert into public.mp_friends (a, b) values (auth.uid(), t);
  return 'sent';
end $$;

revoke all on function public.mp_is_guest(), public.mp_free_names(text[]), public.mp_join_code(text) from public;
grant execute on function public.mp_is_guest(), public.mp_join_code(text) to authenticated;
grant execute on function public.mp_free_names(text[]) to anon, authenticated;

-- Part 3: a room stays joinable by code after a race has started (so a player who left can come back, and the host can race again).
create or replace function public.mp_join_code(c text) returns uuid
language plpgsql security definer set search_path = public as $$
declare r public.mp_rooms;
begin
  if auth.uid() is null or not exists (select 1 from public.mp_profiles where id = auth.uid()) then raise exception 'Not signed in'; end if;
  select * into r from public.mp_rooms where code = upper(trim(c)) and created > now() - interval '6 hours';
  if not found then raise exception 'No open room with that code'; end if;
  if not exists (select 1 from public.mp_members where room = r.id and uid = auth.uid()) and (select count(*) from public.mp_members where room = r.id) >= 4 then
    raise exception 'The room is full (4 players)';
  end if;
  insert into public.mp_members (room, uid, joined) values (r.id, auth.uid(), true) on conflict (room, uid) do update set joined = true;
  return r.id;
end $$;

create or replace function public.mp_join(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.mp_rooms where id = rid) then raise exception 'The room is closed'; end if;
  update public.mp_members set joined = true where room = rid and uid = auth.uid();
  if not found then raise exception 'You are not invited'; end if;
end $$;

create or replace function public.mp_invites() returns table (room uuid, host_name text, tier int, lvl int, wet boolean)
language sql security definer set search_path = public as $$
  select r.id, p.username, r.tier, r.lvl, r.wet
  from public.mp_members m
  join public.mp_rooms r on r.id = m.room
  join public.mp_profiles p on p.id = r.host
  where m.uid = auth.uid() and not m.joined and r.created > now() - interval '2 hours';
$$;

-- Part 4: race counter, so a player who missed the live "start" message (phone in the background) still joins the race.
alter table public.mp_rooms add column if not exists rnd int not null default 0;

drop function if exists public.mp_room_status(uuid, text);
create or replace function public.mp_room_status(rid uuid, st text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.mp_rooms set status = st, rnd = case when st = 'racing' then rnd + 1 else rnd end
  where id = rid and host = auth.uid() and st in ('lobby', 'racing') returning rnd into n;
  return n;
end $$;
revoke all on function public.mp_room_status(uuid, text) from public, anon;
grant execute on function public.mp_room_status(uuid, text) to authenticated;

create or replace function public.mp_room(rid uuid) returns json
language plpgsql security definer set search_path = public as $$
declare res json;
begin
  if not exists (select 1 from public.mp_members where room = rid and uid = auth.uid()) then return null; end if;
  select json_build_object(
    'id', r.id, 'tier', r.tier, 'lvl', r.lvl, 'trk', r.trk, 'wet', r.wet, 'status', r.status, 'host', r.host, 'rnd', r.rnd,
    'code', case when r.host = auth.uid() then r.code else null end,
    'members', (select coalesce(json_agg(json_build_object('uid', m.uid, 'name', p.username, 'joined', m.joined, 'host', m.uid = r.host) order by (m.uid = r.host) desc, p.username), '[]'::json)
                from public.mp_members m join public.mp_profiles p on p.id = m.uid where m.room = r.id))
  into res from public.mp_rooms r where r.id = rid;
  return res;
end $$;

-- Formula Life, part 3: quick-race progress per account and the leaderboard.
create table if not exists public.mp_progress (
  id uuid primary key references auth.users(id) on delete cascade,
  tier int not null default 0,
  lvl int not null default 1,
  unlocked int not null default 0,
  prog jsonb not null default '{}'::jsonb,
  cleared int not null default 0,
  points int not null default 0,
  money bigint not null default 0,
  updated timestamptz not null default now()
);
alter table public.mp_progress enable row level security;

-- merge: the highest value wins, so progress never goes backwards and works from several devices
create or replace function public.mp_progress_save(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare old public.mp_progress; k text; v numeric; np jsonb; ncl int := 0; nun int; npts int; nmon bigint; ntier int; nlvl int; r public.mp_progress;
begin
  if auth.uid() is null or public.mp_is_guest() then return null; end if;
  if not exists (select 1 from public.mp_profiles where id = auth.uid()) then return null; end if;
  select * into old from public.mp_progress where id = auth.uid();
  np := coalesce(old.prog, '{}'::jsonb);
  for k, v in select key, case when jsonb_typeof(value) = 'number' then (value #>> '{}')::numeric else 0 end
              from jsonb_each(coalesce(p -> 'prog', '{}'::jsonb)) where key ~ '^[0-5]$' loop
    np := jsonb_set(np, array[k], to_jsonb(greatest(coalesce((np ->> k)::int, 0), least(10, greatest(0, floor(v)::int)))));
  end loop;
  for k in select key from jsonb_each(np) loop ncl := ncl + coalesce((np ->> k)::int, 0); end loop;
  nun := least(5, greatest(0, coalesce(old.unlocked, 0), coalesce(floor((p ->> 'unlocked')::numeric)::int, 0)));
  npts := least(1000000000, greatest(coalesce(old.points, 0), coalesce(floor((p ->> 'points')::numeric)::int, 0)));
  nmon := least(1000000000000::bigint, greatest(coalesce(old.money, 0), coalesce(floor((p ->> 'money')::numeric)::bigint, 0)));
  if old.id is null or ncl >= old.cleared then
    ntier := least(5, greatest(0, coalesce(floor((p ->> 'tier')::numeric)::int, 0)));
    nlvl := least(10, greatest(1, coalesce(floor((p ->> 'lvl')::numeric)::int, 1)));
  else
    ntier := old.tier; nlvl := old.lvl;
  end if;
  insert into public.mp_progress (id, tier, lvl, unlocked, prog, cleared, points, money, updated)
    values (auth.uid(), ntier, nlvl, nun, np, ncl, npts, nmon, now())
    on conflict (id) do update set tier = excluded.tier, lvl = excluded.lvl, unlocked = excluded.unlocked, prog = excluded.prog,
      cleared = excluded.cleared, points = excluded.points, money = excluded.money, updated = now()
    returning * into r;
  return json_build_object('tier', r.tier, 'lvl', r.lvl, 'unlocked', r.unlocked, 'prog', r.prog, 'points', r.points, 'money', r.money);
end $$;

create or replace function public.mp_leaderboard() returns table (username text, unlocked int, prog jsonb, cleared int, points int, money bigint)
language sql stable security definer set search_path = public as $$
  select pr.username, g.unlocked, g.prog, g.cleared, g.points, g.money
  from public.mp_progress g join public.mp_profiles pr on pr.id = g.id
  order by g.cleared desc, g.points desc, pr.username
  limit 50;
$$;

revoke all on function public.mp_progress_save(jsonb), public.mp_leaderboard() from public, anon;
grant execute on function public.mp_progress_save(jsonb) to authenticated;
grant execute on function public.mp_leaderboard() to anon, authenticated;

-- Formula Life, part 4: leaderboards per class x opponents x corners.
create table if not exists public.mp_scores (
  id uuid not null references auth.users(id) on delete cascade,
  diff smallint not null check (diff between 0 and 2),
  corners smallint not null check (corners between 0 and 2),
  tier smallint not null check (tier between 0 and 5),
  mask int not null default 0 check (mask between 0 and 1023),
  points int not null default 0,
  updated timestamptz not null default now(),
  primary key (id, diff, corners, tier)
);
alter table public.mp_scores enable row level security;

create or replace function public.mp_progress_save(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare old public.mp_progress; k text; v numeric; e jsonb; np jsonb; ncl int := 0; nun int; npts int; nmon bigint; ntier int; nlvl int; r public.mp_progress; sc jsonb;
begin
  if auth.uid() is null or public.mp_is_guest() then return null; end if;
  if not exists (select 1 from public.mp_profiles where id = auth.uid()) then return null; end if;
  select * into old from public.mp_progress where id = auth.uid();
  np := coalesce(old.prog, '{}'::jsonb);
  for k, v in select key, case when jsonb_typeof(value) = 'number' then (value #>> '{}')::numeric else 0 end
              from jsonb_each(coalesce(p -> 'prog', '{}'::jsonb)) where key ~ '^[0-5]$' loop
    np := jsonb_set(np, array[k], to_jsonb(greatest(coalesce((np ->> k)::int, 0), least(10, greatest(0, floor(v)::int)))));
  end loop;
  for k in select key from jsonb_each(np) loop ncl := ncl + coalesce((np ->> k)::int, 0); end loop;
  nun := least(5, greatest(0, coalesce(old.unlocked, 0), coalesce(floor((p ->> 'unlocked')::numeric)::int, 0)));
  npts := least(1000000000, greatest(coalesce(old.points, 0), coalesce(floor((p ->> 'points')::numeric)::int, 0)));
  nmon := least(1000000000000::bigint, greatest(coalesce(old.money, 0), coalesce(floor((p ->> 'money')::numeric)::bigint, 0)));
  if old.id is null or ncl >= old.cleared then
    ntier := least(5, greatest(0, coalesce(floor((p ->> 'tier')::numeric)::int, 0)));
    nlvl := least(10, greatest(1, coalesce(floor((p ->> 'lvl')::numeric)::int, 1)));
  else
    ntier := old.tier; nlvl := old.lvl;
  end if;
  insert into public.mp_progress (id, tier, lvl, unlocked, prog, cleared, points, money, updated)
    values (auth.uid(), ntier, nlvl, nun, np, ncl, npts, nmon, now())
    on conflict (id) do update set tier = excluded.tier, lvl = excluded.lvl, unlocked = excluded.unlocked, prog = excluded.prog,
      cleared = excluded.cleared, points = excluded.points, money = excluded.money, updated = now()
    returning * into r;
  -- scores per combination "opponents,corners,class": cleared tracks are OR-ed, points keep the highest
  for k, e in select key, value from jsonb_each(case when jsonb_typeof(p -> 'sc') = 'object' then p -> 'sc' else '{}'::jsonb end) where key ~ '^[0-2],[0-2],[0-5]$' loop
    insert into public.mp_scores (id, diff, corners, tier, mask, points)
      values (auth.uid(), split_part(k, ',', 1)::smallint, split_part(k, ',', 2)::smallint, split_part(k, ',', 3)::smallint,
        case when jsonb_typeof(e -> 'm') = 'number' then least(1023, greatest(0, floor((e ->> 'm')::numeric)::int)) else 0 end,
        case when jsonb_typeof(e -> 'p') = 'number' then least(1000000000, greatest(0, floor((e ->> 'p')::numeric)::int)) else 0 end)
      on conflict (id, diff, corners, tier) do update set mask = public.mp_scores.mask | excluded.mask,
        points = greatest(public.mp_scores.points, excluded.points), updated = now();
  end loop;
  select coalesce(jsonb_object_agg(s.diff || ',' || s.corners || ',' || s.tier, jsonb_build_object('m', s.mask, 'p', s.points)), '{}'::jsonb)
    into sc from public.mp_scores s where s.id = auth.uid();
  return json_build_object('tier', r.tier, 'lvl', r.lvl, 'unlocked', r.unlocked, 'prog', r.prog, 'points', r.points, 'money', r.money, 'sc', sc);
end $$;

drop function if exists public.mp_leaderboard();
create or replace function public.mp_board(d int, c int, t int) returns table (username text, mask int, points int)
language sql stable security definer set search_path = public as $$
  select pr.username, s.mask, s.points
  from public.mp_scores s join public.mp_profiles pr on pr.id = s.id
  where s.diff = d and s.corners = c and s.tier = t and (s.mask <> 0 or s.points > 0)
  order by (select count(*) from generate_series(0, 9) b where (s.mask >> b) & 1 = 1) desc, s.points desc, pr.username
  limit 50;
$$;
revoke all on function public.mp_board(int, int, int) from public, anon;
grant execute on function public.mp_board(int, int, int) to anon, authenticated;

-- Part 5: recover a forgotten password by email.
-- The auth email of every account starts as username@players.formula-life.game (cannot receive mail).
-- Adding a real email replaces it (mp_email_set); signing in by username then needs mp_login_email,
-- which only returns the email when the password is right. Reset links are sent by Supabase Auth
-- (resetPasswordForEmail), which needs an SMTP server in Authentication > Emails > SMTP Settings.
create table if not exists public.mp_login_try (uname text primary key, n int not null default 0, t timestamptz not null default now());
alter table public.mp_login_try enable row level security;
revoke all on public.mp_login_try from anon, authenticated;

create or replace function public.mp_login_email(u text, p text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare un text := lower(trim(coalesce(u, ''))); em text; pw text; tr public.mp_login_try;
begin
  select * into tr from public.mp_login_try where uname = un;
  if found and tr.n >= 8 and tr.t > now() - interval '10 minutes' then raise exception 'Too many tries. Wait a few minutes.'; end if;
  select a.email, a.encrypted_password into em, pw from public.mp_profiles pr join auth.users a on a.id = pr.id
    where lower(pr.username) = un and a.is_anonymous is not true;
  if em is not null and pw is not null and pw <> '' and crypt(p, pw) = pw then
    delete from public.mp_login_try where uname = un;
    return em;
  end if;
  insert into public.mp_login_try (uname, n, t) values (un, 1, now())
    on conflict (uname) do update set n = case when public.mp_login_try.t > now() - interval '10 minutes' then public.mp_login_try.n + 1 else 1 end, t = now();
  return null;
end $$;

create or replace function public.mp_email_hint(u text) returns json
language plpgsql stable security definer set search_path = public as $$
declare em text; dom text;
begin
  select a.email into em from public.mp_profiles pr join auth.users a on a.id = pr.id
    where lower(pr.username) = lower(trim(coalesce(u, ''))) and a.is_anonymous is not true;
  if em is null then return json_build_object('state', 'noaccount'); end if;
  if em like '%@players.formula-life.game' then return json_build_object('state', 'none'); end if;
  dom := split_part(em, '@', 2);
  return json_build_object('state', 'set', 'hint', left(em, 1) || '***@' || left(dom, 1) || '***' || coalesce(substring(dom from '\.[^.]+$'), ''));
end $$;

create or replace function public.mp_email_get() returns text
language sql stable security definer set search_path = public as $$
  select case when a.email like '%@players.formula-life.game' then null else a.email end from auth.users a where a.id = auth.uid();
$$;

create or replace function public.mp_email_set(e text) returns void
language plpgsql security definer set search_path = public as $$
declare em text := lower(trim(coalesce(e, '')));
begin
  if auth.uid() is null or public.mp_is_guest() or not exists (select 1 from public.mp_profiles where id = auth.uid()) then raise exception 'Sign in with your password first'; end if;
  if length(em) > 254 or em !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' then raise exception 'That email address does not look right'; end if;
  if em like '%@players.formula-life.game' then raise exception 'That email address does not look right'; end if;
  if exists (select 1 from auth.users where lower(email) = em and id <> auth.uid()) then raise exception 'That email is already used by another account'; end if;
  update auth.users set email = em, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = auth.uid();
  update auth.identities set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(em)) where user_id = auth.uid() and provider = 'email';
end $$;

revoke all on function public.mp_login_email(text, text), public.mp_email_hint(text), public.mp_email_get(), public.mp_email_set(text) from public, anon, authenticated;
grant execute on function public.mp_login_email(text, text), public.mp_email_hint(text) to anon, authenticated;
grant execute on function public.mp_email_get(), public.mp_email_set(text) to authenticated;

-- Part 6: the email must be confirmed (Verified) before it can be used to recover a password.
-- The email is now changed with Supabase Auth itself (auth.updateUser({email})): the account keeps its old login email
-- until the link in the confirmation mail is opened, so auth.users.email is always a confirmed address.
-- Needs: Authentication > Sign In / Providers > Email > "Secure email change" OFF, and a working custom SMTP server.
drop function if exists public.mp_email_set(text);
drop function if exists public.mp_email_get();

create or replace function public.mp_email_status() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'email', case when a.email like '%@players.formula-life.game' then null else a.email end,
    'pending', nullif(a.email_change, ''))
  from auth.users a where a.id = auth.uid();
$$;

create or replace function public.mp_email_hint(u text) returns json
language plpgsql stable security definer set search_path = public as $$
declare em text; pend text; dom text;
begin
  select a.email, nullif(a.email_change, '') into em, pend from public.mp_profiles pr join auth.users a on a.id = pr.id
    where lower(pr.username) = lower(trim(coalesce(u, ''))) and a.is_anonymous is not true;
  if em is null then return json_build_object('state', 'noaccount'); end if;
  if em like '%@players.formula-life.game' then
    return json_build_object('state', case when pend is not null then 'unverified' else 'none' end);
  end if;
  dom := split_part(em, '@', 2);
  return json_build_object('state', 'set', 'hint', left(em, 1) || '***@' || left(dom, 1) || '***' || coalesce(substring(dom from '\.[^.]+$'), ''));
end $$;

revoke all on function public.mp_email_status(), public.mp_email_hint(text) from public, anon, authenticated;
grant execute on function public.mp_email_status() to authenticated;
grant execute on function public.mp_email_hint(text) to anon, authenticated;
