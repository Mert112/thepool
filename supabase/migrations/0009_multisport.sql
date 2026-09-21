-- The Pool — every sport on the board. Fixtures, live state and player stats come from ESPN's
-- public scoreboard/summary feeds (sync/espn-sync.mjs on the server); football-data.org is retired.
-- Football keeps its card and its 90-minute rule. Other sports get their own markets, all settled
-- from the final score, the line posted before the start, or box-score stats.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- Sports
-- ---------------------------------------------------------------------------
create table sports (
  code       text primary key,
  name       text not null,
  sort_order int  not null
);
insert into sports (code, name, sort_order) values
  ('soccer', 'Football', 1), ('basketball', 'Basketball', 2), ('american_football', 'American football', 3),
  ('baseball', 'Baseball', 4), ('hockey', 'Ice hockey', 5), ('tennis', 'Tennis', 6), ('mma', 'MMA', 7);

-- ---------------------------------------------------------------------------
-- Competitions ↔ ESPN leagues. team_ns groups leagues whose ESPN team ids are shared
-- (every football league uses one id space; NBA and WNBA ids overlap, so each has its own).
-- ---------------------------------------------------------------------------
alter table competitions
  add column sport       text not null default 'soccer' references sports(code),
  add column espn_path   text unique,
  add column espn_params text,
  add column team_ns     text;

update competitions c set espn_path = v.path, team_ns = 'soccer' from (values
  ('CL', 'soccer/uefa.champions'), ('PL', 'soccer/eng.1'), ('PD', 'soccer/esp.1'), ('BL1', 'soccer/ger.1'),
  ('SA', 'soccer/ita.1'), ('FL1', 'soccer/fra.1'), ('DED', 'soccer/ned.1'), ('PPL', 'soccer/por.1'),
  ('ELC', 'soccer/eng.2'), ('BSA', 'soccer/bra.1'), ('EC', 'soccer/uefa.euro'), ('WC', 'soccer/fifa.world')
) as v(code, path) where c.code = v.code;

insert into competitions (code, name, sport, espn_path, espn_params, team_ns, sort_order) values
  ('UEL',   'Europa League',              'soccer',            'soccer/uefa.europa',                    null,        'soccer', 13),
  ('MLS',   'MLS',                        'soccer',            'soccer/usa.1',                          null,        'soccer', 14),
  ('UNL',   'Nations League',             'soccer',            'soccer/uefa.nations',                   null,        'soccer', 15),
  ('FRI',   'International friendlies',   'soccer',            'soccer/fifa.friendly',                  null,        'soccer', 16),
  ('NBA',   'NBA',                        'basketball',        'basketball/nba',                        null,        'NBA',    20),
  ('WNBA',  'WNBA',                       'basketball',        'basketball/wnba',                       null,        'WNBA',   21),
  ('NCAAM', 'College basketball',         'basketball',        'basketball/mens-college-basketball',    'groups=50', 'NCAAM',  22),
  ('NFL',   'NFL',                        'american_football', 'football/nfl',                          null,        'NFL',    30),
  ('NCAAF', 'College football',           'american_football', 'football/college-football',             'groups=80', 'NCAAF',  31),
  ('MLB',   'MLB',                        'baseball',          'baseball/mlb',                          null,        'MLB',    40),
  ('NHL',   'NHL',                        'hockey',            'hockey/nhl',                            null,        'NHL',    50),
  ('ATP',   'ATP',                        'tennis',            'tennis/atp',                            null,        'tennis', 60),
  ('WTA',   'WTA',                        'tennis',            'tennis/wta',                            null,        'tennis', 61),
  ('UFC',   'UFC',                        'mma',               'mma/ufc',                               null,        'mma',    70);

-- ---------------------------------------------------------------------------
-- Teams and players. A tennis player or a fighter is a one-person "team" so a card always
-- has two sides. New rows get surrogate ids; espn_key is the provider identity.
-- ---------------------------------------------------------------------------
create sequence teams_id_seq start 1000000;
alter table teams
  alter column id set default nextval('teams_id_seq'),
  add column sport    text references sports(code),
  add column espn_key text unique;           -- '<team_ns>:<espn id>'
alter sequence teams_id_seq owned by teams.id;

-- players.id is ESPN's athlete id (one id space across every sport)
alter table players add column sport text references sports(code);

-- ---------------------------------------------------------------------------
-- Matches: one row per game, tennis match or fight
-- ---------------------------------------------------------------------------
create sequence matches_id_seq start 1000000;
alter table matches
  alter column id set default nextval('matches_id_seq'),
  add column sport         text not null default 'soccer' references sports(code),
  add column espn_key      text unique,       -- '<espn path>:<competition id>'
  add column clock         text,              -- live status as shown: 67' · Q3 4:12 · Top 7th · Set 2 · R2 3:10
  add column event_name    text,              -- tournament or fight night, and the round
  add column home_periods  int[],             -- quarters / innings / periods / games per set
  add column away_periods  int[],
  add column total_line    numeric,           -- posted over/under line, frozen at the start
  add column best_of       int,               -- tennis sets or scheduled MMA rounds
  add column result_detail jsonb not null default '{}';  -- winner / method / round / retired
alter sequence matches_id_seq owned by matches.id;
create index matches_sport_idx on matches(sport, utc_date);

-- Box-score numbers that settle player calls outside football: pts · td · hr · g
create table player_stats (
  match_id  int  not null references matches(id) on delete cascade,
  player_id int  not null references players(id) on delete cascade,
  stat      text not null,
  value     numeric not null,
  primary key (match_id, player_id, stat)
);

-- ---------------------------------------------------------------------------
-- Markets per sport
-- ---------------------------------------------------------------------------
alter table markets drop constraint markets_pkey;
alter table markets
  add column sport   text not null default 'soccer' references sports(code),
  add column options jsonb;                  -- allowed picks where the call is a choice (bands, methods)
alter table markets add primary key (sport, call_type);
alter table markets alter column sport drop default;

insert into markets (sport, call_type, title, short, description, points, simple, enabled, sort_order, settles_on, options) values
  ('basketball', 'winner',     'The winner',         'the winner',         'Who wins it, overtime included.',                       1, true,  true, 1, 'result', null),
  ('basketball', 'total',      'Over or under',      'the total',          'Combined points against the posted line.',              2, true,  true, 2, 'result', null),
  ('basketball', 'margin',     'Winning margin',     'the margin',         'Pick the side and how much they win by.',               5, false, true, 3, 'result', '["1-5","6-10","11-15","16+"]'),
  ('basketball', 'top_scorer', 'Top scorer',         'the top scorer',     'Most points in the game. A tie at the top still lands.', 7, false, true, 4, 'result', null),

  ('american_football', 'winner', 'The winner',         'the winner',         'Who wins it, overtime included. A tie voids it.',   1, true,  true, 1, 'result', null),
  ('american_football', 'total',  'Over or under',      'the total',          'Combined points against the posted line.',          2, true,  true, 2, 'result', null),
  ('american_football', 'margin', 'Winning margin',     'the margin',         'Pick the side and how much they win by.',           5, false, true, 3, 'result', '["1-7","8-14","15-21","22+"]'),
  ('american_football', 'scorer', 'A touchdown scorer', 'a touchdown scorer', 'One name. Any rushing or receiving touchdown.',     6, false, true, 4, 'event',  null),

  ('baseball', 'winner', 'The winner',    'the winner',    'Who wins it, extra innings included.',        1, true,  true, 1, 'result', null),
  ('baseball', 'total',  'Over or under', 'the total',     'Combined runs against the posted line.',      2, true,  true, 2, 'result', null),
  ('baseball', 'margin', 'Run margin',    'the margin',    'Pick the side and how many runs they win by.', 4, false, true, 3, 'result', '["1","2","3-4","5+"]'),
  ('baseball', 'scorer', 'A home run',    'a home run',    'One name to go deep, any inning.',            6, false, true, 4, 'event',  null),

  ('hockey', 'winner', 'The winner',      'the winner',      'Who wins it, overtime and shootout included.',       1, true,  true, 1, 'result', null),
  ('hockey', 'total',  'Over or under',   'the total',       'Combined goals against the posted line.',            2, true,  true, 2, 'result', null),
  ('hockey', 'score',  'The exact score', 'the exact score', 'The final score, after overtime or a shootout.',     8, false, true, 3, 'result', null),
  ('hockey', 'scorer', 'A goalscorer',    'a goalscorer',    'One name. Any goal, overtime included.',             5, false, true, 4, 'event',  null),

  ('tennis', 'winner',   'The winner',        'the winner',        'Who comes through. A retirement still counts.',      1, true,  true, 1, 'result', null),
  ('tennis', 'distance', 'Goes the distance', 'goes the distance', 'Does it need a deciding set?',                       3, true,  true, 2, 'result', null),
  ('tennis', 'sets',     'The set score',     'the set score',     'Exact sets, like 2–1. Void on a retirement.',        5, false, true, 3, 'result', null),

  ('mma', 'winner',   'The winner',        'the winner',          'Whose hand gets raised. A draw or no contest voids it.', 1, true,  true, 1, 'result', null),
  ('mma', 'distance', 'Goes the distance', 'goes the distance',   'Does it go to the judges?',                              2, true,  true, 2, 'result', null),
  ('mma', 'method',   'How it ends',       'the method',          'Knockout, submission or the scorecards.',                4, false, true, 3, 'result', '["KO/TKO","Submission","Decision"]'),
  ('mma', 'round',    'The round',         'the finishing round', 'The round the finish comes in. A decision misses.',      7, false, true, 4, 'result', null);

-- ---------------------------------------------------------------------------
-- Calls: a band or method pick, and the line an over/under was called against
-- ---------------------------------------------------------------------------
alter table calls
  add column pick text,
  add column line numeric;
alter table calls drop constraint call_value_shape;
alter table calls add constraint call_value_shape check (
  case call_type
    when 'winner'   then team_id is not null
    when 'draw'     then yes is not null
    when 'distance' then yes is not null
    when 'total'    then yes is not null and line is not null
    when 'score'    then home_goals is not null and away_goals is not null
    when 'sets'     then home_goals is not null and away_goals is not null
    when 'margin'   then team_id is not null and pick is not null
    when 'method'   then pick is not null
    when 'round'    then pick is not null
    else player_id is not null
  end
);

-- ---------------------------------------------------------------------------
-- Saving a card: validation per sport and market
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
  need int;
  v_team int; v_player int; v_yes boolean; v_hg int; v_ag int; v_pick text; v_line numeric;
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
    select * into mk from markets where sport = m.sport and call_type = ct;
    if mk is null or not mk.enabled then raise exception 'call % is not available', ct; end if;
    if c.mode = 'simple' and not mk.simple then raise exception 'call % is not on a simple card', ct; end if;
    if ct = any(kept) then raise exception 'duplicate call %', ct; end if;

    v_team := null; v_player := null; v_yes := null; v_hg := null; v_ag := null; v_pick := null; v_line := null;
    case ct
      when 'winner' then
        v_team := (item->>'team_id')::int;
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
          raise exception 'winner must be one of the two teams';
        end if;
      when 'draw', 'distance' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception '% call needs yes/no', ct; end if;
      when 'total' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'over/under call needs a side'; end if;
        if m.total_line is null then raise exception 'no line has been posted for this game yet'; end if;
        v_line := m.total_line;                -- always the line on the board, never the client's
      when 'score' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        if v_hg is null or v_ag is null then raise exception 'score needs both sides'; end if;
      when 'sets' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        need := (coalesce(m.best_of, 3) + 1) / 2;
        if v_hg is null or v_ag is null or greatest(v_hg, v_ag) <> need or least(v_hg, v_ag) >= need or least(v_hg, v_ag) < 0 then
          raise exception 'that is not a possible set score for a best of %', coalesce(m.best_of, 3);
        end if;
      when 'margin' then
        v_team := (item->>'team_id')::int; v_pick := item->>'pick';
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
          raise exception 'margin must name one of the two sides';
        end if;
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown margin band %', v_pick; end if;
      when 'method' then
        v_pick := item->>'pick';
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown method %', v_pick; end if;
      when 'round' then
        v_pick := item->>'pick';
        if v_pick is null or v_pick !~ '^\d$' or v_pick::int not between 1 and coalesce(m.best_of, 3) then
          raise exception 'pick a round between 1 and %', coalesce(m.best_of, 3);
        end if;
      else
        v_player := (item->>'player_id')::int;
        if v_player is null or not exists (
          select 1 from players p where p.id = v_player and p.team_id in (m.home_team_id, m.away_team_id)
        ) then
          raise exception 'player must be in one of the two squads';
        end if;
    end case;

    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals, pick, line)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag, v_pick, v_line)
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals,
          pick = excluded.pick, line = excluded.line;
    kept := kept || ct;
  end loop;

  delete from calls where entry_id = e_id and not (call_type = any(kept));

  -- a boost on a call that no longer exists is released
  update entries set boost_call_type = null
   where id = e_id and boost_call_type is not null and not (boost_call_type = any(kept));

  return e_id;
end $$;

-- ---------------------------------------------------------------------------
-- Scoring one call. Football is unchanged (90-minute state + event feed). Elsewhere:
-- final score for result calls, box-score stats for player calls. A call the data cannot
-- decide (no line, no stats, a retirement, a no contest) is void rather than a miss.
-- ---------------------------------------------------------------------------
create or replace function band_contains(p_band text, p_n int) returns boolean
language sql immutable as $$
  select case
    when p_band ~ '^\d+\+$'    then p_n >= rtrim(p_band, '+')::int
    when p_band ~ '^\d+-\d+$'  then p_n between split_part(p_band, '-', 1)::int and split_part(p_band, '-', 2)::int
    when p_band ~ '^\d+$'      then p_n = p_band::int
    else false end
$$;

create or replace function score_call(c calls, m matches, boosted boolean)
returns table (result call_result, points int) language plpgsql stable as $$
declare
  mk markets; r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; top numeric; mine numeric;
  win_team int; total int; diff int;
  method text := m.result_detail->>'method';
  retired boolean := coalesce((m.result_detail->>'retired')::boolean, false);
  v_stat text := case m.sport when 'hockey' then 'g' when 'american_football' then 'td' when 'baseball' then 'hr' end;
begin
  select * into mk from markets where sport = m.sport and call_type = c.call_type;
  -- who won: the provider's flag where the score cannot say (tennis retirement, MMA), else the score
  win_team := case m.result_detail->>'winner'
                when 'home' then m.home_team_id when 'away' then m.away_team_id when 'none' then null
                else case when m.home_score > m.away_score then m.home_team_id
                          when m.away_score > m.home_score then m.away_team_id end end;
  total := m.home_score + m.away_score;
  diff  := abs(m.home_score - m.away_score);

  case c.call_type
    when 'scorer' then
      if m.sport = 'soccer' then
        select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                         and not e.own_goal and e.player_id = c.player_id) into ev;
        r := case when ev then 'hit' when final then 'miss' else 'pending' end;
      else
        select coalesce(sum(s.value), 0) > 0 into ev from player_stats s
         where s.match_id = m.id and s.player_id = c.player_id and s.stat = v_stat;
        select exists (select 1 from player_stats s where s.match_id = m.id) into has_stats;
        r := case when ev then 'hit' when final and has_stats then 'miss' when final then 'void' else 'pending' end;
      end if;
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
    when 'top_scorer' then
      if not final then r := 'pending';
      else
        select max(s.value) into top from player_stats s where s.match_id = m.id and s.stat = 'pts';
        select s.value into mine from player_stats s where s.match_id = m.id and s.stat = 'pts' and s.player_id = c.player_id;
        r := case when top is null then 'void' when mine = top then 'hit' else 'miss' end;
      end if;
    when 'winner' then
      if not final then r := 'pending';
      elsif win_team is null then r := 'void';                              -- §2: void if drawn
      elsif c.team_id = win_team then r := 'hit'; else r := 'miss'; end if;
    when 'draw' then
      if not final then r := 'pending';
      elsif c.yes = (m.home_score = m.away_score) then r := 'hit'; else r := 'miss'; end if;
    when 'score' then
      if not final then r := 'pending';
      elsif c.home_goals = m.home_score and c.away_goals = m.away_score then r := 'hit'; else r := 'miss'; end if;
    when 'total' then
      if not final then r := 'pending';
      elsif total is null or c.line is null or total = c.line then r := 'void';   -- a push
      elsif (total > c.line) = c.yes then r := 'hit'; else r := 'miss'; end if;
    when 'margin' then
      if not final then r := 'pending';
      elsif win_team is null then r := 'void';
      elsif c.team_id = win_team and band_contains(c.pick, diff) then r := 'hit'; else r := 'miss'; end if;
    when 'sets' then
      if not final then r := 'pending';
      elsif retired or m.home_score is null then r := 'void';
      elsif c.home_goals = m.home_score and c.away_goals = m.away_score then r := 'hit'; else r := 'miss'; end if;
    when 'distance' then
      if not final then r := 'pending';
      elsif m.sport = 'tennis' then
        if retired or total is null then r := 'void';
        elsif c.yes = (total = coalesce(m.best_of, 3)) then r := 'hit'; else r := 'miss'; end if;
      else
        if method is null then r := 'void';
        elsif c.yes = (method = 'Decision') then r := 'hit'; else r := 'miss'; end if;
      end if;
    when 'method' then
      if not final then r := 'pending';
      elsif method is null or not (mk.options ? method) then r := 'void';
      elsif c.pick = method then r := 'hit'; else r := 'miss'; end if;
    when 'round' then
      if not final then r := 'pending';
      elsif method is null then r := 'void';
      elsif method = 'Decision' then r := 'miss';
      elsif c.pick = m.result_detail->>'round' then r := 'hit'; else r := 'miss'; end if;
    when 'motm' then
      if not final then r := 'pending';
      elsif m.motm_player_id is null then r := 'void';
      elsif m.motm_player_id = c.player_id then r := 'hit'; else r := 'miss'; end if;
  end case;
  result := r;
  points := case when r = 'hit' then mk.points * (case when boosted then 2 else 1 end) else 0 end;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- Crowd split labels for the new calls
-- ---------------------------------------------------------------------------
create or replace function card_crowd(p_card uuid)
returns table (call_type call_type, label text, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type,
      case c.call_type
        when 'winner'   then t.name
        when 'draw'     then case when c.yes then 'Yes' else 'No' end
        when 'distance' then case when c.yes then 'Yes' else 'No' end
        when 'total'    then case when c.yes then 'Over ' else 'Under ' end || trim_scale(c.line)::text
        when 'score'    then c.home_goals || '–' || c.away_goals
        when 'sets'     then c.home_goals || '–' || c.away_goals
        when 'margin'   then t.name || ' by ' || c.pick
        when 'method'   then c.pick
        when 'round'    then 'Round ' || c.pick
        else p.name end as label,
      case c.call_type
        when 'winner'   then c.team_id::text
        when 'draw'     then c.yes::text
        when 'distance' then c.yes::text
        when 'total'    then c.yes::text
        when 'score'    then c.home_goals || '-' || c.away_goals
        when 'sets'     then c.home_goals || '-' || c.away_goals
        when 'margin'   then c.team_id || ':' || c.pick
        when 'method'   then c.pick
        when 'round'    then c.pick
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

-- ---------------------------------------------------------------------------
-- Deadline reminders count the markets of the match's own sport
-- ---------------------------------------------------------------------------
create or replace function enqueue_deadline_reminders() returns int
language plpgsql security definer set search_path = pool, public, extensions as $$
declare n int;
begin
  with soon as (
    select m.id as match_id, m.utc_date, m.sport from matches m
    where m.utc_date between now() + interval '45 minutes' and now() + interval '65 minutes'
      and m.status in ('SCHEDULED', 'TIMED')
  ),
  -- people with an entry that is missing calls
  incomplete as (
    select e.user_id, c.id as card_id, s.match_id
    from soon s join cards c on c.match_id = s.match_id join entries e on e.card_id = c.id
    where (select count(*) from calls x where x.entry_id = e.id)
        < (select count(*) from markets k where k.enabled and k.sport = s.sport and (c.mode = 'complex' or k.simple))
  ),
  -- crew members who have not started a crew card at all
  absent as (
    select cm.user_id, c.id as card_id, s.match_id
    from soon s join cards c on c.match_id = s.match_id and c.crew_id is not null
    join crew_members cm on cm.crew_id = c.crew_id
    where not exists (select 1 from entries e where e.card_id = c.id and e.user_id = cm.user_id)
  ),
  targets as (select * from incomplete union select * from absent),
  ins as (
    insert into notifications (user_id, type, dedupe_key, payload)
    select t.user_id, 'deadline_reminder', t.match_id::text,
           jsonb_build_object('match_id', t.match_id, 'card_ids', jsonb_agg(t.card_id))
    from targets t join notification_settings ns on ns.user_id = t.user_id
    where ns.deadline_reminder
    group by t.user_id, t.match_id
    on conflict do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Tables: a per-sport scope next to overall / competition / crew / week
-- ---------------------------------------------------------------------------
create or replace function leaderboard(p_scope text, p_key text default null, p_season text default null)
returns table (
  user_id uuid, display_name text, points bigint, points_prev bigint, cards bigint,
  hits bigint, calls bigint, hit_rate numeric, best_call call_type, best_points int
)
language plpgsql stable security definer set search_path = pool, public, extensions as $$
begin
  if p_scope = 'crew' and not is_crew_member(p_key::uuid) then
    raise exception 'not a member of this crew' using errcode = '42501';
  end if;
  return query
  with ent as (
    select e.id, e.user_id, e.points, e.hits, e.matchday, m.utc_date, m.competition_code, m.season, c.crew_id
    from entries e join cards c on c.id = e.card_id join matches m on m.id = c.match_id
    where c.status in ('settled', 'disputed')
      and (p_season is null or m.season = p_season)
      and (p_scope <> 'competition' or m.competition_code = p_key)
      and (p_scope <> 'sport' or m.sport = p_key)
      and (p_scope <> 'crew' or c.crew_id = p_key::uuid)
      and (p_scope <> 'week' or m.utc_date > now() - interval '7 days')
  ),
  agg as (
    select ent.user_id,
      sum(ent.points) as points,
      sum(ent.points) filter (where ent.utc_date < now() - interval '7 days') as points_prev,
      count(*) as cards, sum(ent.hits) as hits
    from ent group by ent.user_id
  ),
  ncalls as (
    select ent.user_id, count(*) as calls from ent join calls k on k.entry_id = ent.id group by ent.user_id
  ),
  best as (
    select distinct on (ent.user_id) ent.user_id, k.call_type, k.points_awarded
    from ent join calls k on k.entry_id = ent.id where k.result = 'hit'
    order by ent.user_id, k.points_awarded desc
  )
  select a.user_id, p.display_name, a.points, coalesce(a.points_prev, 0), a.cards, a.hits,
         coalesce(n.calls, 0),
         case when coalesce(n.calls, 0) = 0 then 0 else round(100.0 * a.hits / n.calls, 0) end,
         b.call_type, b.points_awarded
  from agg a
  join profiles p on p.id = a.user_id
  left join ncalls n on n.user_id = a.user_id
  left join best b on b.user_id = a.user_id
  order by a.points desc, a.hits desc, p.display_name;
end $$;

-- ---------------------------------------------------------------------------
-- The board, with sport and the live/pre-game fields every sport needs
-- ---------------------------------------------------------------------------
drop view v_board;
create view v_board with (security_invoker = true) as
select
  m.id as match_id, m.competition_code, cp.name as competition_name, m.season, m.matchday, m.stage,
  m.utc_date, m.status, m.minute, m.home_score, m.away_score, m.ft_home, m.ft_away, m.duration,
  m.home_team_id, ht.name as home_team, ht.short_name as home_short, ht.tla as home_tla, ht.crest_url as home_crest,
  m.away_team_id, at.name as away_team, at.short_name as away_short, at.tla as away_tla, at.crest_url as away_crest,
  pc.id  as public_card_id, pc.mode as public_card_mode, pc.status as public_card_status,
  match_card_count(m.id) as card_count,
  match_playing(m.id) as playing,
  case when m.status in ('IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT') then 'live'
       when m.status in ('FINISHED', 'AWARDED') then 'settled'
       else 'upcoming' end as phase,
  m.sport, sp.name as sport_name, m.clock, m.event_name, m.home_periods, m.away_periods,
  m.total_line, m.best_of, m.result_detail
from matches m
join competitions cp on cp.code = m.competition_code
join sports sp on sp.code = m.sport
left join teams ht on ht.id = m.home_team_id
left join teams at on at.id = m.away_team_id
left join cards pc on pc.match_id = m.id and pc.crew_id is null
where m.status not in ('CANCELLED');

-- ---------------------------------------------------------------------------
-- The football-data.org sample fixtures are replaced by the ESPN feed
-- ---------------------------------------------------------------------------
delete from matches m where m.espn_key is null and not exists (select 1 from cards c where c.match_id = m.id);
delete from players p where not exists (select 1 from calls c where c.player_id = p.id)
                        and not exists (select 1 from match_events e where e.player_id = p.id or e.assist_player_id = p.id);
delete from teams t where t.espn_key is null
  and not exists (select 1 from matches m where t.id in (m.home_team_id, m.away_team_id));

-- ---------------------------------------------------------------------------
-- Sync bookkeeping (sync/espn-sync.mjs, service role only)
-- provider_hash fingerprints everything settlement reads, so provider_updated only moves —
-- and a settled match only re-settles — when the data really changed.
-- ---------------------------------------------------------------------------
alter table matches add column provider_hash text;
alter table teams   add column roster_checked_at timestamptz;

-- matches someone is playing: these get box scores / events while live and before they go final
create or replace function sync_tracked_matches()
returns table (id int, espn_key text, competition_code text, sport text, status match_status, utc_date timestamptz)
language sql stable security definer set search_path = pool, public, extensions as $$
  select m.id, m.espn_key, m.competition_code, m.sport, m.status, m.utc_date
  from matches m
  where m.espn_key is not null
    and m.utc_date between now() - interval '2 days' and now() + interval '1 day'
    and exists (select 1 from cards c join entries e on e.card_id = c.id where c.match_id = m.id)
$$;

-- team-sport squads for fixtures in the next 36 hours: carded games first, then by kickoff; refreshed daily
create or replace function sync_roster_needs(p_limit int default 25)
returns table (team_id int, espn_key text, espn_path text)
language sql stable security definer set search_path = pool, public, extensions as $$
  with upcoming as (
    select m.competition_code, m.utc_date, x.team_id,
           exists (select 1 from cards c where c.match_id = m.id) as carded
    from matches m
    cross join lateral (values (m.home_team_id), (m.away_team_id)) as x(team_id)
    where m.sport in ('soccer', 'basketball', 'american_football', 'baseball', 'hockey')
      and m.status in ('SCHEDULED', 'TIMED')
      and m.utc_date between now() and now() + interval '36 hours'
  ),
  need as (
    select u.team_id, bool_or(u.carded) as carded, min(u.utc_date) as first_game, min(u.competition_code) as comp
    from upcoming u group by u.team_id
  )
  select n.team_id, t.espn_key, cp.espn_path
  from need n join teams t on t.id = n.team_id join competitions cp on cp.code = n.comp
  where t.espn_key is not null
    and (t.roster_checked_at is null or t.roster_checked_at < now() - interval '24 hours')
  order by n.carded desc, n.first_game
  limit p_limit
$$;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table sports       enable row level security;
alter table player_stats enable row level security;
create policy "public read" on sports       for select using (true);
create policy "public read" on player_stats for select using (true);
grant select on sports, player_stats to anon, authenticated;
grant all on sports, player_stats to service_role;
grant usage, select on sequence teams_id_seq, matches_id_seq to service_role;
grant select on v_board to anon, authenticated;

revoke execute on function band_contains(text, int) from public, anon, authenticated;
grant execute on function band_contains(text, int), score_call(calls, matches, boolean) to service_role;
revoke execute on function enqueue_deadline_reminders() from public, anon, authenticated;
revoke execute on function sync_tracked_matches(), sync_roster_needs(int) from public, anon, authenticated;
grant execute on function sync_tracked_matches(), sync_roster_needs(int), process_match_updates() to service_role;

-- make the new tables and columns visible to the API straight away
notify pgrst, 'reload schema';
