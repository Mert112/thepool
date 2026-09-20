-- The Pool — game logic: card lifecycle, entries, boosts, crews, settlement, streaks, stickers.
-- Installed in its own schema so it never touches the other tables in this project.
create schema if not exists pool;
set search_path = pool, public, extensions;
-- All writes from the app go through the rpc_* functions below (security definer, explicit checks).

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function is_crew_member(p_crew uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pool, public, extensions as $$
  select exists (select 1 from crew_members where crew_id = p_crew and user_id = p_user);
$$;

-- members of a crew that has named this crew as its rival (crew-v-crew needs the other side's name and score)
create or replace function is_rival_member(p_crew uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pool, public, extensions as $$
  select exists (
    select 1 from crews r join crew_members cm on cm.crew_id = r.id
    where r.rival_crew_id = p_crew and cm.user_id = p_user
  );
$$;

create or replace function can_see_card(p_card uuid, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pool, public, extensions as $$
  select exists (
    select 1 from cards c
    where c.id = p_card
      and (c.crew_id is null or is_crew_member(c.crew_id, p_user))
  );
$$;

create or replace function match_kickoff(p_match int) returns timestamptz
language sql stable as $$ select utc_date from matches where id = p_match $$;

create or replace function card_is_editable(p_card uuid) returns boolean
language sql stable as $$
  select c.status = 'open' and m.utc_date > now()
  from cards c join matches m on m.id = c.match_id where c.id = p_card
$$;

-- Random, readable invite code like "NB-4417" (letters exclude I/O to avoid confusion)
create or replace function gen_invite_code() returns text language plpgsql as $$
declare
  letters constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ';
  code text;
begin
  loop
    code := substr(letters, 1 + floor(random() * 24)::int, 1)
         || substr(letters, 1 + floor(random() * 24)::int, 1)
         || '-' || lpad((1000 + floor(random() * 9000))::int::text, 4, '0');
    exit when not exists (select 1 from crews where invite_code = code);
  end loop;
  return code;
end $$;

create or replace function require_user() returns uuid language plpgsql stable as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'not signed in' using errcode = '42501'; end if;
  return u;
end $$;

-- ---------------------------------------------------------------------------
-- Profile
-- ---------------------------------------------------------------------------
create or replace function rpc_set_display_name(p_name text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  if char_length(trim(p_name)) < 2 or char_length(trim(p_name)) > 30 then
    raise exception 'display name must be 2–30 characters';
  end if;
  update profiles set display_name = trim(p_name) where id = u;
end $$;

-- ---------------------------------------------------------------------------
-- Cards (§4 lifecycle: open → locked → live → settled → disputed)
-- ---------------------------------------------------------------------------
create or replace function rpc_open_card(p_match int, p_mode card_mode, p_crew uuid default null)
returns uuid language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user();
  m matches;
  existing uuid;
  new_id uuid;
begin
  select * into m from matches where id = p_match;
  if m is null then raise exception 'unknown match'; end if;
  if m.utc_date <= now() or m.status not in ('SCHEDULED', 'TIMED') then
    raise exception 'this fixture is no longer open for cards';
  end if;
  if p_crew is not null and not is_crew_member(p_crew, u) then
    raise exception 'you are not a member of this crew' using errcode = '42501';
  end if;

  select id into existing from cards
   where match_id = p_match and crew_id is not distinct from p_crew;
  if existing is not null then return existing; end if;

  insert into cards (match_id, mode, crew_id, created_by)
  values (p_match, p_mode, p_crew, u)
  returning id into new_id;
  return new_id;
end $$;

-- Mode can change until the first prediction is submitted (§2)
create or replace function rpc_set_card_mode(p_card uuid, p_mode card_mode) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); c cards;
begin
  select * into c from cards where id = p_card;
  if c is null then raise exception 'unknown card'; end if;
  if c.created_by <> u then raise exception 'only the person who opened the card can change its mode' using errcode = '42501'; end if;
  if exists (select 1 from entries where card_id = p_card) then
    raise exception 'the mode is fixed once the first card is in';
  end if;
  update cards set mode = p_mode where id = p_card;
end $$;

-- ---------------------------------------------------------------------------
-- Entries and calls (§5.4). p_calls is a JSON array of
--   {call_type, team_id?, yes?, player_id?, home_goals?, away_goals?}
-- The whole set is replaced: a call missing from the array is removed (skipping is allowed, §2).
-- ---------------------------------------------------------------------------
create or replace function rpc_save_calls(p_card uuid, p_calls jsonb) returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user();
  c cards; m matches;
  e_id uuid;
  item jsonb;
  ct call_type;
  mk markets;
  kept call_type[] := '{}';
  v_team int; v_player int; v_yes boolean; v_hg int; v_ag int;
begin
  select * into c from cards where id = p_card;
  if c is null then raise exception 'unknown card'; end if;
  if c.crew_id is not null and not is_crew_member(c.crew_id, u) then
    raise exception 'you are not a member of this crew' using errcode = '42501';
  end if;
  if not card_is_editable(p_card) then raise exception 'this card is locked'; end if;
  select * into m from matches where id = c.match_id;

  insert into entries (card_id, user_id, matchday)
  values (p_card, u, (m.utc_date at time zone 'utc')::date)
  on conflict (card_id, user_id) do update set updated_at = now()
  returning id into e_id;

  for item in select * from jsonb_array_elements(coalesce(p_calls, '[]'::jsonb)) loop
    ct := (item->>'call_type')::call_type;
    select * into mk from markets where call_type = ct;
    if mk is null or not mk.enabled then raise exception 'call % is not available', ct; end if;
    if c.mode = 'simple' and not mk.simple then raise exception 'call % is not on a simple card', ct; end if;
    if ct = any(kept) then raise exception 'duplicate call %', ct; end if;

    v_team := null; v_player := null; v_yes := null; v_hg := null; v_ag := null;
    case ct
      when 'winner' then
        v_team := (item->>'team_id')::int;
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
          raise exception 'winner must be one of the two teams';
        end if;
      when 'draw' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'draw call needs yes/no'; end if;
      when 'score' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        if v_hg is null or v_ag is null then raise exception 'scoreline needs both goals'; end if;
      else
        v_player := (item->>'player_id')::int;
        if v_player is null or not exists (
          select 1 from players p where p.id = v_player and p.team_id in (m.home_team_id, m.away_team_id)
        ) then
          raise exception 'player must be in one of the two squads';
        end if;
    end case;

    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag)
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals;
    kept := kept || ct;
  end loop;

  delete from calls where entry_id = e_id and not (call_type = any(kept));

  -- a boost on a call that no longer exists is released
  update entries set boost_call_type = null
   where id = e_id and boost_call_type is not null and not (boost_call_type = any(kept));

  return e_id;
end $$;

-- §2.2: one boost per matchday. Movable between cards of the same day while they are still open.
create or replace function rpc_set_boost(p_card uuid, p_call call_type) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  u uuid := require_user();
  e entries;
  other entries;
begin
  select * into e from entries where card_id = p_card and user_id = u;
  if e is null then raise exception 'fill the card before boosting'; end if;
  if not card_is_editable(p_card) then raise exception 'this card is locked'; end if;

  if p_call is null then
    update entries set boost_call_type = null where id = e.id;
    return;
  end if;
  if not exists (select 1 from calls where entry_id = e.id and call_type = p_call) then
    raise exception 'make the call first, then boost it';
  end if;

  -- is the boost already spent on another card today?
  select en.* into other from entries en
   where en.user_id = u and en.matchday = e.matchday and en.boost_call_type is not null and en.id <> e.id;
  if other is not null then
    if card_is_editable(other.card_id) then
      update entries set boost_call_type = null where id = other.id;   -- move it
    else
      raise exception 'your boost for this matchday is already locked on another card';
    end if;
  end if;

  update entries set boost_call_type = p_call where id = e.id;
end $$;

-- ---------------------------------------------------------------------------
-- Crews (§5.6)
-- ---------------------------------------------------------------------------
create or replace function rpc_create_crew(p_name text, p_description text, p_mode card_mode default 'complex')
returns uuid language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); new_id uuid;
begin
  insert into crews (name, description, mode, invite_code, owner_id)
  values (trim(p_name), nullif(trim(p_description), ''), p_mode, gen_invite_code(), u)
  returning id into new_id;
  insert into crew_members (crew_id, user_id, role) values (new_id, u, 'owner');
  return new_id;
end $$;

create or replace function rpc_join_crew(p_code text) returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); c crews;
begin
  select * into c from crews where invite_code = upper(trim(p_code));
  if c is null then raise exception 'no crew has that code'; end if;
  insert into crew_members (crew_id, user_id) values (c.id, u) on conflict do nothing;
  return c.id;
end $$;

create or replace function rpc_leave_crew(p_crew uuid) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  if exists (select 1 from crews where id = p_crew and owner_id = u) then
    raise exception 'the owner cannot leave the crew';
  end if;
  delete from crew_members where crew_id = p_crew and user_id = u;
end $$;

create or replace function rpc_challenge_crew(p_crew uuid, p_rival_code text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); rival uuid;
begin
  if not exists (select 1 from crews where id = p_crew and owner_id = u) then
    raise exception 'only the crew owner can set a rival' using errcode = '42501';
  end if;
  select id into rival from crews where invite_code = upper(trim(p_rival_code));
  if rival is null then raise exception 'no crew has that code'; end if;
  if rival = p_crew then raise exception 'a crew cannot rival itself'; end if;
  update crews set rival_crew_id = rival where id = p_crew;
end $$;

create or replace function rpc_post(p_crew uuid, p_body text) returns uuid
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user(); new_id uuid;
begin
  if not is_crew_member(p_crew, u) then raise exception 'not a member' using errcode = '42501'; end if;
  if char_length(trim(p_body)) = 0 then raise exception 'empty post'; end if;
  insert into crew_posts (crew_id, user_id, body) values (p_crew, u, trim(p_body)) returning id into new_id;
  return new_id;
end $$;

-- ---------------------------------------------------------------------------
-- Crowd split for a card (§1.2 "skill is legible"): aggregate only, never individual calls
-- ---------------------------------------------------------------------------
create or replace function card_crowd(p_card uuid)
returns table (call_type call_type, label text, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type,
      case c.call_type
        when 'winner' then t.name
        when 'draw'   then case when c.yes then 'Yes' else 'No' end
        when 'score'  then c.home_goals || '–' || c.away_goals
        else p.name end as label,
      case c.call_type
        when 'winner' then c.team_id::text
        when 'draw'   then c.yes::text
        when 'score'  then c.home_goals || '-' || c.away_goals
        else c.player_id::text end as key
    from calls c
    join e on e.id = c.entry_id
    left join teams t on t.id = c.team_id
    left join players p on p.id = c.player_id
  )
  select v.call_type, v.label, v.key, count(*) as n,
         round(100 * count(*) / greatest((select t from total), 1), 0) as pct
  from v
  where can_see_card(p_card)
  group by v.call_type, v.label, v.key
  order by v.call_type, n desc;
$$;

-- Who is already playing a card (§5.3), before lock: names and call counts only, never the calls
create or replace function card_players(p_card uuid)
returns table (user_id uuid, display_name text, n_calls bigint, created_at timestamptz)
language sql stable security definer set search_path = pool, public, extensions as $$
  select e.user_id, p.display_name, (select count(*) from calls c where c.entry_id = e.id), e.created_at
  from entries e join profiles p on p.id = e.user_id
  where e.card_id = p_card and can_see_card(p_card)
  order by e.created_at;
$$;

-- The invite code is for members only (a rival crew can see the crew, not its code)
create or replace function crew_invite_code(p_crew uuid) returns text
language sql stable security definer set search_path = pool, public, extensions as $$
  select invite_code from crews where id = p_crew and is_crew_member(p_crew);
$$;

-- ---------------------------------------------------------------------------
-- Lifecycle: lock at kickoff, follow the provider status (called by the sync job)
-- ---------------------------------------------------------------------------
create or replace function sync_card_status() returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare n int := 0;
begin
  -- open → locked when kickoff passes
  update cards c set status = 'locked', locked_at = now()
  from matches m where m.id = c.match_id and c.status = 'open' and m.utc_date <= now();
  get diagnostics n = row_count;

  -- postponed before it started: reopen
  update cards c set status = 'open', locked_at = null
  from matches m where m.id = c.match_id and c.status = 'locked'
    and m.utc_date > now() and m.status in ('SCHEDULED', 'TIMED', 'POSTPONED');

  -- locked → live while the provider reports play
  update cards c set status = 'live'
  from matches m where m.id = c.match_id and c.status in ('open', 'locked') and m.status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT');
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Settlement (§2, §2.1, §4). Idempotent: every run recomputes every call from the
-- current 90-minute state and the event feed, so provider corrections simply re-run it.
--   p_final = false  → progressive live settlement: only event calls can land
--   p_final = true   → full time: everything decides, points written, stickers, streaks, mail
-- ---------------------------------------------------------------------------
create or replace function score_call(c calls, m matches, boosted boolean)
returns table (result call_result, points int) language plpgsql stable as $$
declare
  mk markets; r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean;
begin
  select * into mk from markets where call_type = c.call_type;
  case c.call_type
    when 'scorer' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and not e.own_goal and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when final then 'miss' else 'pending' end;
    when 'assist' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and e.assist_player_id = c.player_id) into ev;
      r := case when ev then 'hit' when final then 'miss' else 'pending' end;
    when 'yellow' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('yellow', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when final then 'miss' else 'pending' end;
    when 'red' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('red', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when final then 'miss' else 'pending' end;
    when 'winner' then
      if not final then r := 'pending';
      elsif m.home_score = m.away_score then r := 'void';                 -- §2: void if drawn
      elsif (m.home_score > m.away_score and c.team_id = m.home_team_id)
         or (m.away_score > m.home_score and c.team_id = m.away_team_id) then r := 'hit';
      else r := 'miss'; end if;
    when 'draw' then
      if not final then r := 'pending';
      elsif c.yes = (m.home_score = m.away_score) then r := 'hit'; else r := 'miss'; end if;
    when 'score' then
      if not final then r := 'pending';
      elsif c.home_goals = m.home_score and c.away_goals = m.away_score then r := 'hit'; else r := 'miss'; end if;
    when 'motm' then
      if not final then r := 'pending';
      elsif m.motm_player_id is null then r := 'void';
      elsif m.motm_player_id = c.player_id then r := 'hit'; else r := 'miss'; end if;
  end case;
  result := r;
  points := case when r = 'hit' then mk.points * (case when boosted then 2 else 1 end) else 0 end;
  return next;
end $$;

create or replace function recompute_streak(p_user uuid) returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  d record; s int := 0; last_day date := null;
begin
  -- distinct settled matchdays, newest first; streak = run of days with ≥1 landed call
  for d in
    select e.matchday, bool_or(e.hits > 0) as landed
    from entries e join cards c on c.id = e.card_id
    where e.user_id = p_user and c.status in ('settled', 'disputed')
    group by e.matchday order by e.matchday desc
  loop
    exit when not d.landed;
    s := s + 1;
    if last_day is null then last_day := d.matchday; end if;
  end loop;
  update profiles set streak = s, streak_last_day = last_day where id = p_user;
  return s;
end $$;

create or replace function settle_match(p_match int, p_final boolean)
returns table (calls_changed int, entries_changed int)
language plpgsql security definer set search_path = pool, public, extensions as $$
declare
  m matches;
  rec record;
  sc record;
  n_calls int := 0; n_entries int := 0;
  rerun boolean;
  prev_points int;
begin
  select * into m from matches where id = p_match;
  if m is null then raise exception 'unknown match'; end if;
  if p_final and m.status not in ('FINISHED', 'AWARDED') then
    raise exception 'match % is not finished', p_match;
  end if;
  if not p_final then
    -- live pass must never mark result calls: force non-final view
    m.status := 'IN_PLAY';
  end if;
  rerun := p_final and m.settled_at is not null;

  -- 1. calls
  for rec in
    select c as call, (e.boost_call_type = c.call_type) as boosted
    from calls c join entries e on e.id = c.entry_id
    join cards cd on cd.id = e.card_id
    where cd.match_id = p_match
  loop
    select * into sc from score_call(rec.call, m, coalesce(rec.boosted, false));
    if sc.result is distinct from (rec.call).result or sc.points is distinct from (rec.call).points_awarded then
      update calls set result = sc.result, points_awarded = sc.points,
             settled_at = case when sc.result = 'pending' then null else now() end
       where id = (rec.call).id;
      n_calls := n_calls + 1;
    end if;
  end loop;

  -- 2. entries
  for rec in
    select e.id, e.user_id, e.points as old_points, e.hits as old_hits, e.card_id, cd.crew_id,
           coalesce(sum(c.points_awarded), 0)::int as pts,
           coalesce(count(*) filter (where c.result = 'hit'), 0)::int as hits
    from entries e join cards cd on cd.id = e.card_id
    left join calls c on c.entry_id = e.id
    where cd.match_id = p_match
    group by e.id, e.user_id, e.points, e.hits, e.card_id, cd.crew_id
  loop
    if rec.pts <> rec.old_points or rec.hits <> rec.old_hits then
      update entries set points = rec.pts, hits = rec.hits where id = rec.id;
      n_entries := n_entries + 1;
      if rerun then
        insert into notifications (user_id, type, dedupe_key, payload)
        values (rec.user_id, 'correction', p_match || ':' || (m.settlement_version + 1),
                jsonb_build_object('match_id', p_match, 'card_id', rec.card_id, 'from', rec.old_points, 'to', rec.pts))
        on conflict do nothing;
      end if;
    end if;
  end loop;

  if not p_final then
    return query select n_calls, n_entries; return;
  end if;

  -- 3. full time: card state, stickers, receipts, streaks, result mail
  update cards set status = 'settled', settled_at = coalesce(settled_at, now()), locked_at = coalesce(locked_at, now())
   where match_id = p_match;

  insert into stickers (user_id, competition_code, season, call_type, match_id)
  select e.user_id, m.competition_code, coalesce(m.season, 'unknown'), c.call_type, p_match
  from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
  where cd.match_id = p_match and c.result = 'hit'
  on conflict do nothing;

  -- receipts in the crew feed for every landed call on a crew card (§5.6)
  insert into crew_posts (crew_id, user_id, call_id)
  select cd.crew_id, e.user_id, c.id
  from calls c join entries e on e.id = c.entry_id join cards cd on cd.id = e.card_id
  where cd.match_id = p_match and cd.crew_id is not null and c.result = 'hit'
    and not exists (select 1 from crew_posts p where p.call_id = c.id);

  perform recompute_streak(e.user_id)
  from (select distinct e.user_id from entries e join cards cd on cd.id = e.card_id where cd.match_id = p_match) e;

  insert into notifications (user_id, type, dedupe_key, payload)
  select e.user_id, 'result', p_match::text || ':' || cd.id, jsonb_build_object('match_id', p_match, 'card_id', cd.id)
  from entries e join cards cd on cd.id = e.card_id
  join notification_settings ns on ns.user_id = e.user_id
  where cd.match_id = p_match and ns.result
  on conflict do nothing;

  -- settled_at always advances (and never trails the provider version it settled) so a correction is processed exactly once
  update matches set settled_at = greatest(clock_timestamp(), coalesce(provider_updated, clock_timestamp())),
                     settlement_version = settlement_version + 1
   where id = p_match;

  return query select n_calls, n_entries;
end $$;

-- Provider correction after settlement (§4 "Disputed"): mark, re-run, done.
create or replace function resettle_match(p_match int)
returns table (calls_changed int, entries_changed int)
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  update cards set status = 'disputed' where match_id = p_match and status = 'settled';
  return query select * from settle_match(p_match, true);
end $$;

-- Called by the live sync after every provider poll
create or replace function process_match_updates() returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare r record;
begin
  perform sync_card_status();
  for r in select id, status, settled_at, provider_updated from matches
            where utc_date > now() - interval '7 days'
              and ((status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT'))
               or (status in ('FINISHED', 'AWARDED') and (settled_at is null or provider_updated > settled_at)))
  loop
    if r.status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT') then
      perform settle_match(r.id, false);
    elsif r.settled_at is null then
      perform settle_match(r.id, true);
    else
      perform resettle_match(r.id);
    end if;
  end loop;
end $$;
