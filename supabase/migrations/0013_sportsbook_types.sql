-- The Pool — call types for sportsbook-style markets (0014 uses them).
set search_path = pool, public, extensions;

alter type call_type add value if not exists 'spread';       -- point spread / handicap / run line / puck line
alter type call_type add value if not exists 'player_line';  -- a player over/under (points, yards, receptions…)
