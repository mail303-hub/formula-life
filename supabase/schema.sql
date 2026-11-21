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
