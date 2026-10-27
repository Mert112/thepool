-- The Pool — a card is open to others once its first bet is saved, not when it is created.
--
-- Until now `rpc_open_card()` put a card on the board, in the match page, in the crew room and
-- in everyone's "a new card opens" mail the moment its creator pressed "Open it" — before they
-- had made a single call. Now a card has `opened_at`, stamped by the first call saved on it:
--
--   · until then only its creator sees it in a listing (the board, the match page and the crew
--     room filter on `opened_at`); `rpc_open_card()` still hands the same card back to anyone who
--     asks for one on that match, so two people can never open two public cards for one game
--   · the new-card mail goes out when the card opens, not when the row is inserted
--   · withdrawing every call does not close a card again: others may already have joined
set search_path = pool, public, extensions;

alter table cards add column opened_at timestamptz;
comment on column cards.opened_at is
  'When the first call was saved on this card. Null: created but nobody has bet yet, so it is listed for its creator only.';

-- every card that already has a player is open, as of when it was created
update cards c set opened_at = c.created_at
 where exists (select 1 from entries e where e.card_id = c.id);

-- The first call opens the card. A trigger on calls (not entries) because rpc_save_calls inserts
-- the entry before it knows whether any calls survive, and an all-withdrawn save leaves none.
-- A refused save raises, which rolls this back with it.
create or replace function card_opened() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  update cards set opened_at = now()
   where id = (select card_id from entries where id = new.entry_id) and opened_at is null;
  return null;
end $$;
revoke execute on function card_opened() from public, anon, authenticated;
create trigger calls_open_card after insert on calls for each row execute function card_opened();

-- the mail waits for the card to open
drop trigger cards_notify_new on cards;
create trigger cards_notify_new after update of opened_at on cards
  for each row when (old.opened_at is null and new.opened_at is not null) execute function notify_new_card();

-- the board counts and shows open cards only
create or replace function match_card_count(p_match int) returns bigint
language sql stable security definer set search_path = pool, public, extensions as $$
  select count(*) from cards where match_id = p_match and opened_at is not null $$;

create or replace view v_board with (security_invoker = true) as
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
  m.clock, m.event_name, m.total_line, m.result_detail, m.odds
from matches m
join competitions cp on cp.code = m.competition_code
left join teams ht on ht.id = m.home_team_id
left join teams at on at.id = m.away_team_id
left join cards pc on pc.match_id = m.id and pc.crew_id is null and pc.opened_at is not null
where m.sport = 'soccer' and m.status <> 'CANCELLED';

notify pgrst, 'reload schema';
