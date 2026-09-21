-- The Pool — sportsbook logic.
--   · Points follow the odds: a landed call pays 10 × its decimal price, locked in when the call is saved
--     (like a bet slip). With no stake to lose, that gives every pick the same expected value, so the skill is
--     beating the price. Where the feed has no price, the market's standard price (default_price) applies.
--   · Sportsbook markets: football's result is a 3-way moneyline (home / draw / away); the point spread
--     replaces margin bands; player over/unders (points, yards, receptions…); MMA method names the fighter.
set search_path = pool, public, extensions;

-- ---------------------------------------------------------------------------
-- Prices and lines. matches.odds holds decimal prices from the feed, frozen at the start by the sync:
--   {"provider":"DraftKings","home":2.1,"away":3.4,"draw":3.3,
--    "spread":{"home_line":-3.5,"home":1.91,"away":1.91},"total":{"line":47.5,"over":1.91,"under":1.91}}
-- ---------------------------------------------------------------------------
alter table matches add column odds jsonb not null default '{}';

-- player over/under lines posted for a game (the feed gives lines, not prices: they pay the standard -110)
create table match_props (
  match_id   int  not null references matches(id) on delete cascade,
  player_id  int  not null references players(id) on delete cascade,
  stat       text not null,          -- pts · reb · ast · pass_yds · rush_yds · rec_yds · rec
  line       numeric not null,
  updated_at timestamptz not null default now(),
  primary key (match_id, player_id, stat)
);

alter table calls   add column price numeric;          -- decimal odds locked in when the call was saved
alter table markets add column default_price numeric;  -- the price when the feed has none

alter table calls drop constraint call_value_shape;
alter table calls add constraint call_value_shape check (
  case call_type
    when 'winner'      then team_id is not null or pick = 'draw'
    when 'draw'        then yes is not null
    when 'distance'    then yes is not null
    when 'total'       then yes is not null and line is not null
    when 'score'       then home_goals is not null and away_goals is not null
    when 'sets'        then home_goals is not null and away_goals is not null
    when 'margin'      then team_id is not null and pick is not null
    when 'spread'      then team_id is not null and line is not null
    when 'method'      then pick is not null
    when 'round'       then pick is not null
    when 'player_line' then player_id is not null and pick is not null and line is not null and yes is not null
    else player_id is not null
  end
);

-- ---------------------------------------------------------------------------
-- Markets
-- ---------------------------------------------------------------------------
update markets set enabled = false where call_type = 'margin';                       -- the spread replaces the bands
update markets set enabled = false where sport = 'soccer' and call_type = 'draw';    -- folded into the 3-way result
update markets set title = 'The result', short = 'the result', description = 'Home, draw or away — after 90 minutes plus stoppage.'
 where sport = 'soccer' and call_type = 'winner';
update markets set title = 'How they win', short = 'the method', description = 'The fighter and the finish: KO/TKO, submission or decision.'
 where sport = 'mma' and call_type = 'method';

insert into markets (sport, call_type, title, short, description, points, simple, enabled, sort_order, settles_on) values
  ('soccer',            'total',       'Over or under', 'the total',    'Total goals after 90 minutes against the posted line.',    19, true,  true, 2, 'result'),
  ('soccer',            'spread',      'The handicap',  'the handicap', 'Back a side with the goal handicap on the board.',         19, false, true, 3, 'result'),
  ('basketball',        'spread',      'The spread',    'the spread',   'Back a side with the points handicap on the board.',       19, false, true, 3, 'result'),
  ('american_football', 'spread',      'The spread',    'the spread',   'Back a side with the points handicap on the board.',       19, false, true, 3, 'result'),
  ('baseball',          'spread',      'The run line',  'the run line', 'Back a side with the run handicap on the board.',          19, false, true, 3, 'result'),
  ('hockey',            'spread',      'The puck line', 'the puck line','Back a side with the goal handicap on the board.',         19, false, true, 3, 'result'),
  ('basketball',        'player_line', 'A player line', 'a player line','Over or under a player''s points, rebounds or assists.',  19, false, true, 4, 'result'),
  ('american_football', 'player_line', 'A player line', 'a player line','Over or under a player''s yards or receptions.',           19, false, true, 4, 'result');

-- standard prices where the feed has none; points = 10 × price
update markets k set default_price = v.price, points = round(10 * v.price)::int from (values
  ('soccer','winner',2.8), ('soccer','total',1.91), ('soccer','spread',1.91), ('soccer','score',8.0),
  ('soccer','scorer',3.5), ('soccer','assist',5.0), ('soccer','yellow',3.5), ('soccer','red',12.0), ('soccer','motm',8.0), ('soccer','draw',3.3),
  ('basketball','winner',1.91), ('basketball','total',1.91), ('basketball','spread',1.91), ('basketball','player_line',1.91), ('basketball','top_scorer',5.0), ('basketball','margin',4.0),
  ('american_football','winner',1.91), ('american_football','total',1.91), ('american_football','spread',1.91), ('american_football','player_line',1.91), ('american_football','scorer',2.8), ('american_football','margin',4.0),
  ('baseball','winner',1.91), ('baseball','total',1.91), ('baseball','spread',1.91), ('baseball','scorer',5.0), ('baseball','margin',3.5),
  ('hockey','winner',1.91), ('hockey','total',1.91), ('hockey','spread',1.91), ('hockey','score',9.0), ('hockey','scorer',3.0),
  ('tennis','winner',1.91), ('tennis','distance',2.6), ('tennis','sets',3.5),
  ('mma','winner',1.91), ('mma','method',4.0), ('mma','round',6.0), ('mma','distance',2.2)
) as v(sport, ct, price) where k.sport = v.sport and k.call_type = v.ct::call_type;

-- simple card: the winner and the total everywhere (MMA: the winner and how they win)
update markets set simple = (call_type in ('winner', 'total')) where sport not in ('mma', 'tennis');
update markets set sort_order = case call_type when 'winner' then 1 when 'total' then 2 when 'spread' then 3 when 'player_line' then 4
                                  when 'score' then 5 when 'top_scorer' then 5 else sort_order + 5 end
 where sport not in ('mma', 'tennis');

-- ---------------------------------------------------------------------------
-- The price a call is locked in at
-- ---------------------------------------------------------------------------
create or replace function call_price(m matches, mk markets, p_team int, p_pick text, p_yes boolean)
returns numeric language sql stable as $$
  select coalesce(
    case mk.call_type
      when 'winner' then (case when p_pick = 'draw' then m.odds->>'draw'
                               when p_team = m.home_team_id then m.odds->>'home'
                               when p_team = m.away_team_id then m.odds->>'away' end)::numeric
      when 'total'  then (m.odds->'total'->>(case when p_yes then 'over' else 'under' end))::numeric
      when 'spread' then (m.odds->'spread'->>(case when p_team = m.home_team_id then 'home' else 'away' end))::numeric
    end,
    mk.default_price, mk.points / 10.0)
$$;

-- ---------------------------------------------------------------------------
-- Saving a card
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
  conflict text;
  hl numeric;
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
        if item->>'pick' = 'draw' then
          if m.sport <> 'soccer' then raise exception 'there is no draw in this sport'; end if;
          v_pick := 'draw';
        else
          v_team := (item->>'team_id')::int;
          if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then
            raise exception 'winner must be one of the two teams';
          end if;
        end if;
      when 'draw', 'distance' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception '% call needs yes/no', ct; end if;
      when 'total' then
        v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'over/under call needs a side'; end if;
        v_line := coalesce((m.odds->'total'->>'line')::numeric, m.total_line);
        if v_line is null then raise exception 'no line has been posted for this game yet'; end if;
      when 'spread' then
        v_team := (item->>'team_id')::int;
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'the spread must name one of the two sides'; end if;
        hl := (m.odds->'spread'->>'home_line')::numeric;
        if hl is null then raise exception 'no spread has been posted for this game yet'; end if;
        v_line := case when v_team = m.home_team_id then hl else -hl end;   -- the handicap on the side you back
      when 'score' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        if v_hg is null or v_ag is null then raise exception 'score needs both sides'; end if;
        if m.sport <> 'soccer' and v_hg = v_ag then raise exception 'this game always has a winner — the score cannot be level'; end if;
      when 'sets' then
        v_hg := (item->>'home_goals')::int; v_ag := (item->>'away_goals')::int;
        need := (coalesce(m.best_of, 3) + 1) / 2;
        if v_hg is null or v_ag is null or greatest(v_hg, v_ag) <> need or least(v_hg, v_ag) >= need or least(v_hg, v_ag) < 0 then
          raise exception 'that is not a possible set score for a best of %', coalesce(m.best_of, 3);
        end if;
      when 'margin' then
        v_team := (item->>'team_id')::int; v_pick := item->>'pick';
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'margin must name one of the two sides'; end if;
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown margin band %', v_pick; end if;
      when 'method' then
        v_team := (item->>'team_id')::int; v_pick := item->>'pick';
        if v_team is null or v_team not in (m.home_team_id, m.away_team_id) then raise exception 'pick the fighter who wins it'; end if;
        if v_pick is null or not (mk.options ? v_pick) then raise exception 'unknown method %', v_pick; end if;
      when 'round' then
        v_pick := item->>'pick';
        if v_pick is null or v_pick !~ '^\d$' or v_pick::int not between 1 and coalesce(m.best_of, 3) then
          raise exception 'pick a round between 1 and %', coalesce(m.best_of, 3);
        end if;
      when 'player_line' then
        v_player := (item->>'player_id')::int; v_pick := item->>'pick'; v_yes := (item->>'yes')::boolean;
        if v_yes is null then raise exception 'a player line needs over or under'; end if;
        select p.line into v_line from match_props p where p.match_id = m.id and p.player_id = v_player and p.stat = v_pick;
        if v_line is null then raise exception 'that player line is not on the board for this game'; end if;
      else
        v_player := (item->>'player_id')::int;
        if v_player is null or not exists (
          select 1 from players p where p.id = v_player and p.team_id in (m.home_team_id, m.away_team_id)
        ) then
          raise exception 'player must be in one of the two squads';
        end if;
    end case;

    insert into calls (entry_id, call_type, team_id, yes, player_id, home_goals, away_goals, pick, line, price)
    values (e_id, ct, v_team, v_yes, v_player, v_hg, v_ag, v_pick, v_line, call_price(m, mk, v_team, v_pick, v_yes))
    on conflict (entry_id, call_type) do update
      set team_id = excluded.team_id, yes = excluded.yes, player_id = excluded.player_id,
          home_goals = excluded.home_goals, away_goals = excluded.away_goals,
          pick = excluded.pick, line = excluded.line,
          -- an unchanged pick keeps the price it was taken at; a changed one takes today's
          price = case when (calls.team_id, calls.yes, calls.player_id, calls.home_goals, calls.away_goals, calls.pick, calls.line)
                            is not distinct from (excluded.team_id, excluded.yes, excluded.player_id, excluded.home_goals, excluded.away_goals, excluded.pick, excluded.line)
                       then calls.price else excluded.price end;
    kept := kept || ct;
  end loop;

  delete from calls where entry_id = e_id and not (call_type = any(kept));

  -- every call removed: the entry goes too (and with it any boost)
  if cardinality(kept) = 0 then
    delete from entries where id = e_id;
    return null;
  end if;

  -- one card, one story: calls that cannot all land would be a hedge
  conflict := call_conflict(m, e_id);
  if conflict is not null then raise exception '%', conflict; end if;

  -- a boost on a call that no longer exists is released
  update entries set boost_call_type = null
   where id = e_id and boost_call_type is not null and not (boost_call_type = any(kept));

  return e_id;
end $$;

-- ---------------------------------------------------------------------------
-- No hedging (0011) for the sportsbook markets
-- ---------------------------------------------------------------------------
create or replace function call_conflict(m matches, p_entry uuid) returns text
language plpgsql stable security definer set search_path = pool, public, extensions as $$
declare
  w calls; d calls; s calls; t calls; mg calls; st calls; di calls; me calls; ro calls; sp calls;
  side int; w_draw boolean; w_team int; other int;
begin
  select * into w  from calls where entry_id = p_entry and call_type = 'winner';
  select * into d  from calls where entry_id = p_entry and call_type = 'draw';
  select * into s  from calls where entry_id = p_entry and call_type = 'score';
  select * into t  from calls where entry_id = p_entry and call_type = 'total';
  select * into mg from calls where entry_id = p_entry and call_type = 'margin';
  select * into st from calls where entry_id = p_entry and call_type = 'sets';
  select * into di from calls where entry_id = p_entry and call_type = 'distance';
  select * into me from calls where entry_id = p_entry and call_type = 'method';
  select * into ro from calls where entry_id = p_entry and call_type = 'round';
  select * into sp from calls where entry_id = p_entry and call_type = 'spread';
  w_draw := w.id is not null and coalesce(w.pick = 'draw', false);   -- pick is null for a team pick: null is not false
  w_team := case when w.id is not null and not w_draw then w.team_id end;

  if w_team is not null and d.yes then return 'You called a winner and a draw — only one can happen. Drop one of them.'; end if;
  if s.id is not null then
    if s.home_goals = s.away_goals then
      if w_team is not null then return 'A level scoreline means nobody wins — it contradicts your winner.'; end if;
      if d.id is not null and not d.yes then return 'A level scoreline is a draw — it contradicts "Draw: no".'; end if;
    else
      side := case when s.home_goals > s.away_goals then m.home_team_id else m.away_team_id end;
      if w_team is not null and w_team <> side then return 'Your score has the other side winning.'; end if;
      if w_draw then return 'Your score has a winner — it contradicts your draw.'; end if;
      if d.yes then return 'Your score has a winner — it contradicts "Draw: yes".'; end if;
    end if;
    -- a score exactly on a whole-number line is a push, not a contradiction
    if t.id is not null and ((t.yes and s.home_goals + s.away_goals < t.line) or (not t.yes and s.home_goals + s.away_goals > t.line)) then
      return 'Your exact score and your over/under disagree.';
    end if;
    if sp.id is not null and
       (case when sp.team_id = m.home_team_id then s.home_goals - s.away_goals else s.away_goals - s.home_goals end) + sp.line < 0 then
      return 'Your exact score loses your spread.';
    end if;
  end if;
  -- backing a side giving points means that side has to win
  if sp.id is not null and sp.line < 0 and w.id is not null and (w_draw or w_team <> sp.team_id) then
    return 'Your spread needs the other side to win.';
  end if;
  if mg.id is not null and w_team is not null and mg.team_id <> w_team then return 'Your winning margin backs the other side.'; end if;
  if st.id is not null then
    side := case when st.home_goals > st.away_goals then m.home_team_id else m.away_team_id end;
    if w_team is not null and w_team <> side then return 'Your set score has the other player winning.'; end if;
    if di.id is not null and di.yes <> (st.home_goals + st.away_goals = coalesce(m.best_of, 3)) then
      return 'Your set score and "goes the distance" disagree.';
    end if;
  end if;
  if m.sport = 'mma' then
    if me.team_id is not null and w_team is not null and me.team_id <> w_team then return 'Your method has the other fighter winning.'; end if;
    if di.id is not null and me.id is not null and di.yes <> (me.pick = 'Decision') then return 'How it ends and "goes the distance" disagree.'; end if;
    if ro.id is not null and di.yes then return 'A finishing round means it does not go the distance.'; end if;
    if ro.id is not null and me.pick = 'Decision' then return 'A decision has no finishing round.'; end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Scoring: a hit pays 10 × the locked price (×2 boosted)
-- ---------------------------------------------------------------------------
create or replace function score_call(c calls, m matches, boosted boolean)
returns table (result call_result, points int) language plpgsql stable as $$
declare
  mk markets; r call_result := 'pending'; final boolean := m.status in ('FINISHED', 'AWARDED');
  ev boolean; has_stats boolean; played boolean; top numeric; mine numeric; v numeric;
  win_team int; total int; diff int; cover numeric;
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
  -- did the called player take part? With no lineup or box score for the game we cannot tell,
  -- so they count as played and the call is judged as before
  select exists (select 1 from player_stats s where s.match_id = m.id) into has_stats;
  played := c.player_id is null or not has_stats
            or exists (select 1 from player_stats s where s.match_id = m.id and s.player_id = c.player_id);
  total := m.home_score + m.away_score;
  diff  := abs(m.home_score - m.away_score);

  case c.call_type
    when 'scorer' then
      if m.sport = 'soccer' then
        select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                         and not e.own_goal and e.player_id = c.player_id) into ev;
      else
        select coalesce(sum(s.value), 0) > 0 into ev from player_stats s
         where s.match_id = m.id and s.player_id = c.player_id and s.stat = v_stat;
      end if;
      r := case when ev then 'hit' when not final then 'pending'
                when m.sport <> 'soccer' and not has_stats then 'void'      -- no box score to judge by
                when not played then 'void' else 'miss' end;
    when 'assist' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts and e.type = 'goal'
                       and e.assist_player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'yellow' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('yellow', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'red' then
      select exists (select 1 from match_events e where e.match_id = m.id and e.counts
                       and e.type in ('red', 'yellow_red') and e.player_id = c.player_id) into ev;
      r := case when ev then 'hit' when not final then 'pending' when not played then 'void' else 'miss' end;
    when 'top_scorer' then
      if not final then r := 'pending';
      else
        select max(s.value) into top from player_stats s where s.match_id = m.id and s.stat = 'pts';
        select s.value into mine from player_stats s where s.match_id = m.id and s.stat = 'pts' and s.player_id = c.player_id;
        r := case when top is null or not played then 'void' when mine = top then 'hit' else 'miss' end;
      end if;
    when 'player_line' then
      if not final then r := 'pending';
      elsif not has_stats or not played then r := 'void';                      -- no box score, or never took part
      else
        select coalesce(sum(s.value), 0) into v from player_stats s
         where s.match_id = m.id and s.player_id = c.player_id and s.stat = c.pick;
        r := case when v = c.line then 'void' when (v > c.line) = c.yes then 'hit' else 'miss' end;
      end if;
    when 'winner' then
      if not final then r := 'pending';
      elsif c.pick = 'draw' then
        r := case when m.home_score is null then 'void' when m.home_score = m.away_score then 'hit' else 'miss' end;
      elsif win_team is null then
        -- football's result is 3-way: a draw beats both sides. Elsewhere a tie or no contest is a push.
        r := case when m.sport = 'soccer' and m.home_score is not null and m.home_score = m.away_score then 'miss' else 'void' end;
      elsif c.team_id = win_team then r := 'hit'; else r := 'miss'; end if;
    when 'spread' then
      if not final then r := 'pending';
      elsif m.home_score is null then r := 'void';
      else
        cover := (case when c.team_id = m.home_team_id then m.home_score - m.away_score else m.away_score - m.home_score end) + c.line;
        r := case when cover = 0 then 'void' when cover > 0 then 'hit' else 'miss' end;
      end if;
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
      elsif c.pick = method and (c.team_id is null or c.team_id = win_team) then r := 'hit'; else r := 'miss'; end if;
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
  points := case when r = 'hit'
                 then round(10 * coalesce(c.price, mk.default_price, mk.points / 10.0))::int * (case when boosted then 2 else 1 end)
                 else 0 end;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- Crowd labels
-- ---------------------------------------------------------------------------
create or replace function stat_label(p_stat text) returns text language sql immutable as $$
  select case p_stat when 'pts' then 'points' when 'reb' then 'rebounds' when 'ast' then 'assists'
    when 'pass_yds' then 'passing yards' when 'rush_yds' then 'rushing yards' when 'rec_yds' then 'receiving yards'
    when 'rec' then 'receptions' else p_stat end
$$;

create or replace function card_crowd(p_card uuid)
returns table (call_type call_type, label text, key text, n bigint, pct numeric)
language sql stable security definer set search_path = pool, public, extensions as $$
  with e as (select id from entries where card_id = p_card),
  total as (select count(*)::numeric as t from e),
  v as (
    select c.call_type,
      case c.call_type
        when 'winner'      then case when c.pick = 'draw' then 'Draw' else t.name end
        when 'draw'        then case when c.yes then 'Yes' else 'No' end
        when 'distance'    then case when c.yes then 'Yes' else 'No' end
        when 'total'       then case when c.yes then 'Over ' else 'Under ' end || trim_scale(c.line)::text
        when 'spread'      then t.name || ' ' || case when c.line > 0 then '+' else '' end || trim_scale(c.line)::text
        when 'score'       then c.home_goals || '–' || c.away_goals
        when 'sets'        then c.home_goals || '–' || c.away_goals
        when 'margin'      then t.name || ' by ' || c.pick
        when 'method'      then coalesce(t.name || ' by ', '') || c.pick
        when 'round'       then 'Round ' || c.pick
        when 'player_line' then p.name || ' ' || case when c.yes then 'over ' else 'under ' end || trim_scale(c.line)::text || ' ' || stat_label(c.pick)
        else p.name end as label,
      case c.call_type
        when 'winner'      then coalesce(c.team_id::text, 'draw')
        when 'draw'        then c.yes::text
        when 'distance'    then c.yes::text
        when 'total'       then c.yes::text
        when 'spread'      then c.team_id::text
        when 'score'       then c.home_goals || '-' || c.away_goals
        when 'sets'        then c.home_goals || '-' || c.away_goals
        when 'margin'      then c.team_id || ':' || c.pick
        when 'method'      then coalesce(c.team_id::text, '') || ':' || c.pick
        when 'round'       then c.pick
        when 'player_line' then c.player_id || ':' || c.pick || ':' || c.yes
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
-- The board carries the prices
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
  m.total_line, m.best_of, m.result_detail, m.odds
from matches m
join competitions cp on cp.code = m.competition_code
join sports sp on sp.code = m.sport
left join teams ht on ht.id = m.home_team_id
left join teams at on at.id = m.away_team_id
left join cards pc on pc.match_id = m.id and pc.crew_id is null
where m.status not in ('CANCELLED');

-- calls saved before prices existed take the standard price, so every open card pays on one scale
update calls k set price = coalesce(mk.default_price, mk.points / 10.0)
from entries e, cards cd, matches m, markets mk
where k.entry_id = e.id and e.card_id = cd.id and cd.match_id = m.id and mk.sport = m.sport and mk.call_type = k.call_type
  and k.price is null;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table match_props enable row level security;
create policy "public read" on match_props for select using (true);
grant select on match_props to anon, authenticated;
grant all on match_props to service_role;
grant select on v_board to anon, authenticated;
revoke execute on function call_price(matches, markets, int, text, boolean), stat_label(text) from public, anon, authenticated;
grant execute on function call_price(matches, markets, int, text, boolean), stat_label(text) to service_role;

notify pgrst, 'reload schema';
