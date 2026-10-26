-- The Pool — one provider: API-Football (api-sports.io).
--
-- ESPN's feeds were public, unofficial and free, and they showed it: no squad for half the
-- fixtures, no bookings until after full time, and a scoreboard that had to be read a day at a
-- time per competition. API-Football is a paid contract with a documented shape, a fixture
-- detail that carries events and line-ups in the same response, and — the part that changes the
-- design — a `?ids=` form that returns twenty of those details in one request.
--
-- What that buys, and what this migration therefore has to hold:
--
--   · A request budget. The Pro plan allows 7,500 calls a day; we spend at most 7,000, read from
--     `config` and counted in `api_usage` so the counter is the database's, not the script's. A
--     pass that would bust the budget does not make the call.
--   · A league catalogue. All ~1,250 leagues land in `competitions` with their country and type,
--     but only the ones somebody follows are `active`, and only active leagues cost requests.
--   · Following. Twelve competitions plus Türkiye's and Bulgaria's national-team matches are on
--     for a new account; everything else is there to be added under "More leagues".
--   · Provider ids beside the old ones. `teams.espn_key`, `players.id` and `matches.espn_key`
--     are ESPN's, and 640 settled matches, 105 calls and every ledger row hang off them. Nothing
--     is re-keyed: `af_id` / `af_fixture_id` are added alongside, and the sync maps the two by
--     name within a competition. Settled history is not touched.
--   · Coverage, recorded. `matches.detail_at` says when the provider last handed over this
--     fixture's events and line-ups. Without it, a player call cannot be judged — so at full
--     time those calls are voided and the stake handed back, rather than counted as misses.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- 1. config: settings that are operational rather than structural
-- ---------------------------------------------------------------------------
-- Things an operator changes without a migration. `public` rows are readable by the app; the
-- rest (budgets, keys to behaviour) are the server's business.
create table config (
  key        text primary key,
  value      jsonb not null,
  public     boolean not null default false,
  note       text,
  updated_at timestamptz not null default now()
);

alter table config enable row level security;
create policy "public config" on config for select to anon, authenticated using (public);
revoke all on config from anon, authenticated;
grant select on config to anon, authenticated;

insert into config (key, value, public, note) values
  ('football_api', jsonb_build_object(
      'base', 'https://v3.football.api-sports.io',
      'daily_budget', 7000,          -- the Pro plan allows 7,500; this leaves room to be wrong
      'fixture_batch', 20,           -- how many fixture ids one ?ids= request may carry
      'live_every_seconds', 60,
      'catalogue_every_days', 7,
      'squads_every_days', 1,
      'window_days_back', 2,
      'window_days_forward', 8),
    false,
    'API-Football. The key itself is never here — it lives in FOOTBALL_API_KEY on the sync host.');

-- ---------------------------------------------------------------------------
-- 2. The request budget, counted by the database
-- ---------------------------------------------------------------------------
-- A counter in the script would reset every time systemd started it. This one is a row per UTC
-- day, and the sync has to ask for its requests before it spends them.
create table api_usage (
  day      date primary key,
  requests int  not null default 0,
  budget   int  not null,
  detail   jsonb not null default '{}'::jsonb,   -- requests by kind, for reading afterwards
  updated_at timestamptz not null default now()
);

comment on table api_usage is 'One row per UTC day: how many provider requests have been spent against the budget.';

-- The spend counter is operational, not public. The schema's default privileges hand select on a
-- new table to anon and authenticated (0003), so every new table has to take them back — the
-- same gap that let the icons tables out in `0022`.
alter table api_usage enable row level security;
revoke all on api_usage from anon, authenticated;

-- Reserve n requests. Returns false — and spends nothing — when they would not fit.
create or replace function api_take(p_n int, p_kind text default 'other') returns boolean
language plpgsql security definer set search_path = pool, public, extensions as $$
declare d date := (now() at time zone 'utc')::date; b int; got boolean;
begin
  if p_n is null or p_n <= 0 then return true; end if;
  b := coalesce((select (value->>'daily_budget')::int from config where key = 'football_api'), 7000);
  insert into api_usage (day, requests, budget) values (d, 0, b)
    on conflict (day) do update set budget = excluded.budget;
  update api_usage
     set requests = requests + p_n,
         detail = jsonb_set(detail, array[p_kind], to_jsonb(coalesce((detail->>p_kind)::int, 0) + p_n)),
         updated_at = now()
   where day = d and requests + p_n <= budget
  returning true into got;
  return coalesce(got, false);
end $$;

-- What is left today, for the log line and for a health check.
create or replace function api_left() returns int
language sql stable security definer set search_path = pool, public, extensions as $$
  select coalesce(
    (select u.budget - u.requests from api_usage u where u.day = (now() at time zone 'utc')::date),
    (select (value->>'daily_budget')::int from config where key = 'football_api'),
    7000)
$$;

revoke execute on function api_take(int, text), api_left() from public, anon, authenticated;
grant execute on function api_take(int, text), api_left() to service_role;

-- ---------------------------------------------------------------------------
-- 3. Competitions: the provider's whole catalogue, and which of it we follow
-- ---------------------------------------------------------------------------
alter table competitions
  add column af_league_id  int unique,
  add column country       text,
  add column country_code  text,
  add column flag_url      text,
  add column type          text check (type in ('league', 'cup')),
  add column tier          smallint,
  add column season_year   int,
  add column has_events    boolean,
  add column has_odds      boolean,
  add column default_follow boolean not null default false,
  -- a competition we only care about for particular sides: the national-team ones, where the
  -- board should carry Türkiye and Bulgaria and not the other fifty qualifiers
  add column team_filter   int[],
  add column catalogued_at timestamptz;

comment on column competitions.tier is
  'Where it sits in its country''s pyramid. The provider does not publish this, so it is set by hand for the leagues we follow and left null for the rest.';
comment on column competitions.team_filter is
  'API-Football team ids. When set, only fixtures involving one of them are synced or shown.';
comment on column competitions.active is
  'Whether the sync spends requests on it: true for a default, or for anything somebody follows.';

-- The sixteen already in the table keep their code, so every settled match keeps its competition.
update competitions set af_league_id = v.af, country = v.country, type = v.type, tier = v.tier from (values
  ('CL',  2,   'World',       'cup',    null::smallint),
  ('UEL', 3,   'World',       'cup',    null),
  ('PL',  39,  'England',     'league', 1::smallint),
  ('PD',  140, 'Spain',       'league', 1),
  ('SA',  135, 'Italy',       'league', 1),
  ('BL1', 78,  'Germany',     'league', 1),
  ('FL1', 61,  'France',      'league', 1),
  ('DED', 88,  'Netherlands', 'league', 1),
  ('PPL', 94,  'Portugal',    'league', 1),
  ('ELC', 40,  'England',     'league', 2),
  ('BSA', 71,  'Brazil',      'league', 1),
  ('MLS', 253, 'USA',         'league', 1),
  ('EC',  4,   'World',       'cup',    null),
  ('WC',  1,   'World',       'cup',    null),
  ('UNL', 5,   'World',       'cup',    null),
  ('FRI', 10,  'World',       'cup',    null)
) as v(code, af, country, type, tier) where competitions.code = v.code;

-- The ones the product wants that were never on the board.
insert into competitions (code, name, af_league_id, country, type, tier, active, sort_order) values
  ('TR1',  'Süper Lig',              203, 'Turkey',   'league', 1, true, 1),
  ('TR2',  '1. Lig',                 204, 'Turkey',   'league', 2, true, 2),
  ('TRC',  'Türkiye Kupası',         206, 'Turkey',   'cup',    null, true, 3),
  ('BG1',  'First League',           172, 'Bulgaria', 'league', 1, true, 4),
  ('UECL', 'Conference League',      848, 'World',    'cup',    null, true, 9),
  ('WCQE', 'World Cup qualifiers',    32, 'World',    'cup',    null, true, 20),
  ('ECQ',  'Euro qualifiers',        960, 'World',    'cup',    null, true, 21)
on conflict (code) do nothing;

-- Turkish and Bulgarian football first, then the rest of Europe, then everything else.
update competitions set sort_order = v.n from (values
  ('TR1', 1), ('TR2', 2), ('TRC', 3), ('BG1', 4),
  ('CL', 7), ('UEL', 8), ('UECL', 9),
  ('PL', 11), ('PD', 12), ('SA', 13), ('BL1', 14), ('FL1', 15),
  ('WCQE', 20), ('ECQ', 21), ('UNL', 22), ('WC', 23), ('EC', 24),
  ('DED', 40), ('PPL', 41), ('ELC', 42), ('BSA', 43), ('MLS', 44), ('FRI', 45)
) as v(code, n) where competitions.code = v.code;

-- §default competitions for a new account
update competitions set default_follow = true
 where code in ('TR1', 'TR2', 'TRC', 'CL', 'UEL', 'UECL', 'PL', 'PD', 'SA', 'BL1', 'FL1', 'BG1',
                'WCQE', 'ECQ', 'UNL', 'WC', 'EC');

-- The national-team competitions are followed for two sides only: Türkiye (777) and Bulgaria
-- (1103). Everything else in a World Cup qualifying group is somebody else's business, and
-- fetching it would cost requests for fixtures nobody here will play.
update competitions set team_filter = array[777, 1103]
 where code in ('WCQE', 'ECQ', 'UNL', 'WC', 'EC');

-- Only what is followed is synced. Everything else in the catalogue sits there to be found.
update competitions set active = default_follow;

-- Upsert one league from the provider's catalogue. Codes for leagues we did not already carry
-- are `AF<id>`, which cannot collide with the hand-written ones.
create or replace function upsert_league(
  p_id int, p_name text, p_type text, p_logo text,
  p_country text, p_code text, p_flag text,
  p_season int, p_events boolean, p_odds boolean) returns text
language plpgsql security definer set search_path = pool, public, extensions as $$
declare c text;
begin
  select code into c from competitions where af_league_id = p_id;
  if c is null then
    c := 'AF' || p_id;
    insert into competitions (code, name, af_league_id, active, sort_order)
    values (c, p_name, p_id, false, 500)
    on conflict (code) do nothing;
  end if;
  update competitions set
    name = case when code like 'AF%' then p_name else name end,   -- a hand-written name stays
    country = p_country, country_code = p_code, flag_url = p_flag,
    emblem_url = coalesce(p_logo, emblem_url),
    type = lower(p_type), season_year = p_season, season = p_season::text,
    has_events = p_events, has_odds = p_odds, catalogued_at = now()
   where code = c;
  return c;
end $$;

revoke execute on function upsert_league(int, text, text, text, text, text, text, int, boolean, boolean)
  from public, anon, authenticated;
grant execute on function upsert_league(int, text, text, text, text, text, text, int, boolean, boolean)
  to service_role;

-- ---------------------------------------------------------------------------
-- 4. Provider ids beside the old ones
-- ---------------------------------------------------------------------------
alter table teams
  add column af_id    int unique,
  add column country  text,
  add column national boolean not null default false;

alter table matches add column af_fixture_id int unique;
comment on column matches.af_fixture_id is 'API-Football fixture id. The sync upserts on this.';

alter table matches add column odds_checked_at timestamptz;
comment on column matches.odds_checked_at is
  'When the odds endpoint was last asked about this fixture — whether or not it had any. Without it the same unpriced fixtures are asked for again every minute.';

alter table matches add column detail_at timestamptz;
comment on column matches.detail_at is
  'When the provider last handed over this fixture''s events and line-ups. Null at full time means the player calls cannot be judged, so they are voided.';

-- players.id has always been the provider''s own id, which stops working the moment the provider
-- changes. Existing rows keep theirs; new ones take a sequence that starts clear of them.
alter table players add column af_id int unique;
create sequence if not exists players_id_seq as int;
select setval('players_id_seq', greatest(coalesce((select max(id) from players), 0), 1000000));
alter table players alter column id set default nextval('players_id_seq');
alter sequence players_id_seq owned by players.id;
-- the other two sequences carry exactly this: the sync writes as the service role and nobody else
grant select, usage on sequence players_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- 5. Following a competition
-- ---------------------------------------------------------------------------
create table competition_follows (
  user_id          uuid not null references profiles(id) on delete cascade,
  competition_code text not null references competitions(code) on delete cascade,
  created_at       timestamptz not null default now(),
  primary key (user_id, competition_code)
);

alter table competition_follows enable row level security;
create policy "own follows" on competition_follows for select to authenticated using (user_id = auth.uid());
revoke all on competition_follows from anon, authenticated;
grant select on competition_follows to authenticated;

create index on competition_follows (competition_code);

-- Everyone who already has an account starts from the same defaults.
insert into competition_follows (user_id, competition_code)
select p.id, c.code from profiles p cross join competitions c where c.default_follow
on conflict do nothing;

-- A league nobody follows costs nothing; one somebody follows is synced from the next pass.
create or replace function refresh_active_competitions() returns void
language sql security definer set search_path = pool, public, extensions as $$
  update competitions c set active = (c.default_follow or exists
    (select 1 from competition_follows f where f.competition_code = c.code))
   where c.active is distinct from (c.default_follow or exists
    (select 1 from competition_follows f where f.competition_code = c.code));
$$;

create or replace function rpc_follow_competition(p_code text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  if not exists (select 1 from competitions where code = p_code) then
    raise exception 'no competition %', p_code;
  end if;
  insert into competition_follows (user_id, competition_code) values (u, p_code) on conflict do nothing;
  perform refresh_active_competitions();
end $$;

create or replace function rpc_unfollow_competition(p_code text) returns void
language plpgsql security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  delete from competition_follows where user_id = u and competition_code = p_code;
  perform refresh_active_competitions();
end $$;

-- What this account follows, and what else there is. One call, because the board needs the
-- first and "More leagues" needs the second.
create or replace function my_competitions() returns jsonb
language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  return jsonb_build_object(
    'following', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', c.code, 'name', c.name, 'country', c.country, 'type', c.type,
               'tier', c.tier, 'flag_url', c.flag_url, 'emblem_url', c.emblem_url,
               'default', c.default_follow, 'sort_order', c.sort_order)
             order by c.sort_order, c.name)
      from competition_follows f join competitions c on c.code = f.competition_code
      where f.user_id = u), '[]'::jsonb),
    'countries', coalesce((
      select jsonb_agg(jsonb_build_object('country', x.country, 'flag_url', x.flag_url, 'n', x.n)
             order by x.country)
      from (select c.country, min(c.flag_url) as flag_url, count(*) as n
              from competitions c where c.country is not null
             group by c.country) x), '[]'::jsonb));
end $$;

-- The catalogue, a country at a time: "More leagues" asks for one country and gets its leagues.
create or replace function competitions_in(p_country text) returns jsonb
language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare u uuid := require_user();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'code', c.code, 'name', c.name, 'country', c.country, 'type', c.type,
             'tier', c.tier, 'flag_url', c.flag_url, 'emblem_url', c.emblem_url,
             'following', exists (select 1 from competition_follows f where f.user_id = u and f.competition_code = c.code))
           order by c.tier nulls last, c.name)
    from competitions c where c.country = p_country), '[]'::jsonb);
end $$;

-- the schema's default privileges hand execute to public, so every one of these is taken back
-- before it is given to the role that should have it (0003 set that default; 0022 was caught by it)
revoke execute on function rpc_follow_competition(text), rpc_unfollow_competition(text),
                           my_competitions(), competitions_in(text) from public, anon;
grant execute on function rpc_follow_competition(text), rpc_unfollow_competition(text),
                          my_competitions(), competitions_in(text) to authenticated;
revoke execute on function refresh_active_competitions() from public, anon, authenticated;

-- A new account starts on the defaults. (The live function, with the follows added.)
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  insert into profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  insert into notification_settings (user_id) values (new.id) on conflict (user_id) do nothing;
  insert into ledger (user_id, amount, reason, reference) values (new.id, 100, 'signup', new.id::text);
  insert into user_icons (user_id, code) values (new.id, 'rookie') on conflict do nothing;
  insert into competition_follows (user_id, competition_code)
    select new.id, code from competitions where default_follow on conflict do nothing;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 6. What the sync should ask for
-- ---------------------------------------------------------------------------
-- The leagues worth spending a fixtures request on, with the season to ask for.
create or replace function sync_leagues() returns table (code text, league_id int, season int, team_filter int[])
language sql stable security definer set search_path = pool, public, extensions as $$
  select c.code, c.af_league_id, coalesce(c.season_year, extract(year from now())::int), c.team_filter
    from competitions c
   where c.active and c.af_league_id is not null
   order by c.sort_order, c.code;
$$;

-- In play, and somebody is playing it: these are the only fixtures worth a minute-by-minute look.
create or replace function sync_live_fixtures() returns table (match_id int, fixture_id int)
language sql stable security definer set search_path = pool, public, extensions as $$
  select m.id, m.af_fixture_id
    from matches m
   where m.af_fixture_id is not null
     and m.status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT')
     and exists (select 1 from cards cd where cd.match_id = m.id)
   order by m.utc_date;
$$;

-- Everything else that has kicked off and not been settled: one look each, after the whistle.
-- A match nobody is playing never needs a live pass — only its result.
create or replace function sync_result_checks(p_limit int default 40)
returns table (match_id int, fixture_id int)
language sql stable security definer set search_path = pool, public, extensions as $$
  select m.id, m.af_fixture_id
    from matches m
   where m.af_fixture_id is not null
     and m.utc_date < now() - interval '105 minutes'
     and m.utc_date > now() - interval '7 days'
     and (m.status not in ('FINISHED', 'AWARDED', 'CANCELLED', 'POSTPONED')
          or (m.status in ('FINISHED', 'AWARDED') and m.settled_at is null))
   order by m.utc_date
   limit greatest(1, p_limit);
$$;

-- Squads for the teams with a fixture on the board, oldest check first.
create or replace function sync_squads(p_limit int default 40)
returns table (team_id int, af_id int, name text)
language sql stable security definer set search_path = pool, public, extensions as $$
  select t.id, t.af_id, t.name
    from teams t
   where t.af_id is not null
     and exists (
       select 1 from matches m join competitions c on c.code = m.competition_code
        where (m.home_team_id = t.id or m.away_team_id = t.id)
          and c.active
          and m.utc_date between now() - interval '1 day' and now() + interval '8 days')
     and (t.roster_checked_at is null or t.roster_checked_at < now() - interval '1 day')
   order by t.roster_checked_at nulls first
   limit greatest(1, p_limit);
$$;

-- A fixture whose odds we have not frozen yet, and which is close enough to be worth asking for.
-- Ask once, then leave it alone for six hours. A fixture with no odds posted yet is the normal
-- case the day before, and asking again a minute later costs a request and learns nothing — at
-- eight a minute that is 11,500 requests a day against a budget of 7,000.
create or replace function sync_odds_needs(p_limit int default 25)
returns table (match_id int, fixture_id int)
language sql stable security definer set search_path = pool, public, extensions as $$
  select m.id, m.af_fixture_id
    from matches m join competitions c on c.code = m.competition_code
   where m.af_fixture_id is not null and c.active
     and m.status in ('SCHEDULED', 'TIMED')
     and m.utc_date between now() and now() + interval '36 hours'
     and (m.odds = '{}'::jsonb or m.odds is null)
     and (m.odds_checked_at is null or m.odds_checked_at < now() - interval '6 hours')
   order by m.utc_date
   limit greatest(1, p_limit);
$$;

revoke execute on function sync_leagues(), sync_live_fixtures(), sync_result_checks(int),
                           sync_squads(int), sync_odds_needs(int) from public, anon, authenticated;
grant execute on function sync_leagues(), sync_live_fixtures(), sync_result_checks(int),
                          sync_squads(int), sync_odds_needs(int) to service_role;

-- ---------------------------------------------------------------------------
-- 7. A player call cannot be judged without the events
-- ---------------------------------------------------------------------------
-- The provider covers events for most leagues and not for all, and a feed can simply fail. A
-- goalscorer call on a match whose events never arrived is not a miss — nobody can say whether
-- it was right. At full time those calls are voided and the stake handed back, which is what
-- `void` already means everywhere else in the economy.
--
-- This is the live `score_call` with one rule added. Before, a match with no `player_stats` set
-- `played` to true, so an unlanded player call was scored a **miss**: the stake was lost on a
-- call nobody could judge. Now `matches.detail_at` says whether the provider ever handed the
-- fixture's events and line-ups over, and without it the call is void. The older rule — you
-- named someone who did not take part, so your stake comes back — is unchanged and still runs
-- underneath it.
-- A rule change must not re-judge a match that has already been settled and paid. Everything
-- settled under ESPN keeps the verdict it was given; the void-on-no-coverage rule applies from
-- here on. Matches we hold events or line-ups for are marked the same way, since we plainly had
-- the coverage. (On a fresh database there is nothing to mark.)
update matches set detail_at = coalesce(settled_at, provider_updated, updated_at, now())
 where detail_at is null
   and (settled_at is not null
        or exists (select 1 from player_stats s where s.match_id = matches.id)
        or exists (select 1 from match_events e where e.match_id = matches.id));

-- `detail_at` is stamped by the writes themselves rather than by the caller. Line-ups and events
-- arrive together in one fixture detail, and either one landing is proof the provider answered;
-- a sync that forgot to set the column would quietly turn judgeable calls into voids.
create or replace function touch_detail() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  update matches set detail_at = now()
   where id = new.match_id and (detail_at is null or detail_at < now() - interval '1 minute');
  return new;
end $$;

revoke execute on function touch_detail() from public, anon, authenticated;

create trigger match_events_detail after insert on match_events
  for each row execute function touch_detail();
create trigger player_stats_detail after insert on player_stats
  for each row execute function touch_detail();

create or replace function score_call(c calls, m matches) returns call_result
language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare
  r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; played boolean; detail boolean;
  total int; cover numeric;
begin
  if not c.staked and c.created_at >= economy_start() and m.utc_date <= now() then
    return 'void';
  end if;
  -- did the provider ever give us this fixture's events and line-ups?
  detail := m.detail_at is not null;
  select exists (select 1 from player_stats s where s.match_id = m.id) into has_stats;
  played := c.player_id is null or not has_stats
            or exists (select 1 from player_stats s where s.match_id = m.id and s.player_id = c.player_id);
  total := m.home_score + m.away_score;
  case c.call_type
    when 'scorer' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and not e.own_goal and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not detail or not played then 'void' else 'miss' end;
    when 'assist' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and e.assist_player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not detail or not played then 'void' else 'miss' end;
    when 'yellow' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('yellow', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not detail or not played then 'void' else 'miss' end;
    when 'red' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('red', 'yellow_red') and e.player_id = c.player_id
                       and (c.pick is null or band_contains(c.pick, e.minute))) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not detail or not played then 'void' else 'miss' end;
    when 'winner' then
      if not final or m.home_score is null then r := case when final then 'void' else 'pending' end;
      elsif c.pick = 'draw' then r := case when m.home_score = m.away_score then 'hit' else 'miss' end;
      elsif m.home_score = m.away_score then r := 'miss';
      elsif (m.home_score > m.away_score and c.team_id = m.home_team_id)
         or (m.away_score > m.home_score and c.team_id = m.away_team_id) then r := 'hit';
      else r := 'miss'; end if;
    when 'spread' then
      if not final then r := 'pending';
      elsif m.home_score is null then r := 'void';
      else
        cover := (case when c.team_id = m.home_team_id then m.home_score - m.away_score else m.away_score - m.home_score end) + c.line;
        r := case when cover = 0 then 'void' when cover > 0 then 'hit' else 'miss' end;
      end if;
    when 'total' then
      if not final then r := 'pending';
      elsif total is null or c.line is null or total = c.line then r := 'void';
      elsif (total > c.line) = c.yes then r := 'hit'; else r := 'miss'; end if;
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
    else r := 'pending';
  end case;
  return r;
end $$;

revoke execute on function score_call(calls, matches) from public, anon, authenticated;
grant execute on function score_call(calls, matches) to service_role;

notify pgrst, 'reload schema';
