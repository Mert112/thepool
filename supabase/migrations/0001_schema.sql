-- The Pool — core schema
-- Installed in its own schema so it never touches the other tables in this project.
create schema if not exists pool;
set search_path = pool, public, extensions;
-- Objects follow the design doc §3: competition, match, card, entry, call, crew, sticker.
-- All provider ids (competitions, teams, players, matches) are football-data.org ids.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type card_mode  as enum ('simple', 'complex');
create type card_status as enum ('open', 'locked', 'live', 'settled', 'disputed');
create type call_type  as enum ('winner', 'draw', 'motm', 'score', 'scorer', 'assist', 'yellow', 'red');
create type call_result as enum ('pending', 'hit', 'miss', 'void');
create type event_type as enum ('goal', 'yellow', 'red', 'yellow_red');
create type crew_role  as enum ('owner', 'member');
create type match_status as enum ('SCHEDULED', 'TIMED', 'IN_PLAY', 'PAUSED', 'EXTRA_TIME', 'PENALTY_SHOOTOUT',
                                  'FINISHED', 'POSTPONED', 'SUSPENDED', 'CANCELLED', 'AWARDED');

-- ---------------------------------------------------------------------------
-- Markets: the scoring table from §2, stored so it can be tuned without a deploy
-- ---------------------------------------------------------------------------
create table markets (
  call_type   call_type primary key,
  title       text not null,
  short       text not null,
  description text not null,
  points      int  not null check (points > 0),
  simple      boolean not null default false,   -- available on a simple card
  enabled     boolean not null default true,    -- motm is disabled in v1 (no provider data)
  sort_order  int not null,
  -- 'event' calls can settle progressively during play; 'result' calls wait for full time
  settles_on  text not null check (settles_on in ('event', 'result'))
);

insert into markets (call_type, title, short, description, points, simple, enabled, sort_order, settles_on) values
  ('winner', 'The winner',          'the winner',          'Which side takes it in 90 plus stoppage?',            1,  true,  true,  1, 'result'),
  ('draw',   'Draw?',               'the draw',            'Level at the whistle — the call most people skip.',   3,  true,  true,  2, 'result'),
  ('motm',   'Best on the pitch',   'best on the pitch',   'Official man of the match decides it.',               8,  true,  false, 3, 'result'),
  ('score',  'The exact scoreline', 'the exact scoreline', 'Exact only. No partial credit.',                      8,  false, true,  4, 'result'),
  ('scorer', 'A goalscorer',        'a goalscorer',        'One name. Any goal, any minute.',                     7,  false, true,  5, 'event'),
  ('assist', 'An assist',           'the assist',          'The hardest single call on the card.',                9,  false, true,  6, 'event'),
  ('yellow', 'A yellow card',       'the yellow card',     'First or any booking counts.',                        6,  false, true,  7, 'event'),
  ('red',    'A red card',          'the red card',        'Rarely called, and it wins tables.',                  10, false, true,  8, 'event');

-- ---------------------------------------------------------------------------
-- Football data
-- ---------------------------------------------------------------------------
create table competitions (
  code          text primary key,          -- PL, CL, PD, BL1, SA, FL1, DED, PPL, ELC, BSA, EC, WC
  fd_id         int unique,
  name          text not null,
  emblem_url    text,
  season        text,                      -- e.g. '2026' (start year), refreshed by sync
  season_start  date,
  season_end    date,
  active        boolean not null default true,
  sort_order    int not null default 100
);

insert into competitions (code, name, sort_order) values
  ('CL',  'Champions League', 1), ('PL',  'Premier League', 2), ('PD',  'La Liga', 3),
  ('BL1', 'Bundesliga', 4),       ('SA',  'Serie A', 5),        ('FL1', 'Ligue 1', 6),
  ('DED', 'Eredivisie', 7),       ('PPL', 'Primeira Liga', 8),  ('ELC', 'Championship', 9),
  ('BSA', 'Brasileirão', 10),     ('EC',  'Euro', 11),          ('WC',  'World Cup', 12);

create table teams (
  id         int primary key,              -- football-data team id
  name       text not null,
  short_name text,
  tla        text,
  crest_url  text,
  updated_at timestamptz not null default now()
);

create table players (
  id         int primary key,              -- football-data person id
  team_id    int references teams(id) on delete set null,
  name       text not null,
  position   text,
  shirt      int,
  updated_at timestamptz not null default now()
);
create index players_team_idx on players(team_id);

create table matches (
  id               int primary key,       -- football-data match id
  competition_code text not null references competitions(code),
  season           text,
  matchday         int,
  stage            text,
  utc_date         timestamptz not null,
  status           match_status not null default 'SCHEDULED',
  minute           int,                   -- live minute when in play
  home_team_id     int references teams(id),
  away_team_id     int references teams(id),
  -- 90-minute state (regular time). This is what every call settles on (§2.1).
  home_score       int,
  away_score       int,
  -- final state including extra time / penalties, display only
  ft_home          int,
  ft_away          int,
  duration         text,                  -- REGULAR | EXTRA_TIME | PENALTY_SHOOTOUT
  motm_player_id   int references players(id),  -- set manually; provider does not supply it
  provider_updated timestamptz,
  settled_at       timestamptz,
  settlement_version int not null default 0,
  updated_at       timestamptz not null default now()
);
create index matches_date_idx on matches(utc_date);
create index matches_status_idx on matches(status);
create index matches_comp_idx on matches(competition_code, utc_date);

-- Provider events. `counts` is the §2.1 rule: only events at minute <= 90 (+stoppage) settle calls.
create table match_events (
  id               bigserial primary key,
  match_id         int not null references matches(id) on delete cascade,
  type             event_type not null,
  minute           int not null,
  injury_time      int,
  team_id          int references teams(id),
  player_id        int references players(id),
  player_name      text,
  assist_player_id int references players(id),
  assist_name      text,
  own_goal         boolean not null default false,
  provider_key     text not null,          -- stable key from the provider payload; makes re-sync idempotent
  counts           boolean generated always as (minute <= 90) stored,
  created_at       timestamptz not null default now(),
  unique (match_id, provider_key)
);
create index match_events_match_idx on match_events(match_id);

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         citext not null unique,
  display_name  text,
  created_at    timestamptz not null default now(),
  -- streak: consecutive matchdays (calendar days with a settled entry) with at least one landed call
  streak        int not null default 0,
  streak_last_day date
);

-- Create the profile the moment auth creates the user (§5.1: first sign-in creates the account)
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = pool, public, extensions as $$
begin
  insert into profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  insert into notification_settings (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end $$;

create table notification_settings (
  user_id              uuid primary key references profiles(id) on delete cascade,
  new_card             boolean not null default true,
  deadline_reminder    boolean not null default true,
  crew_activity        boolean not null default true,
  result               boolean not null default true,
  weekly_digest        boolean not null default false,
  watched_competitions text[] not null default '{}'
);

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function pool.handle_new_user();

-- ---------------------------------------------------------------------------
-- Crews
-- ---------------------------------------------------------------------------
create table crews (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(name) between 2 and 40),
  description   text,
  mode          card_mode not null default 'complex',
  invite_code   text not null unique,
  owner_id      uuid not null references profiles(id),
  rival_crew_id uuid references crews(id),
  created_at    timestamptz not null default now()
);

create table crew_members (
  crew_id   uuid not null references crews(id) on delete cascade,
  user_id   uuid not null references profiles(id) on delete cascade,
  role      crew_role not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (crew_id, user_id)
);
create index crew_members_user_idx on crew_members(user_id);

-- ---------------------------------------------------------------------------
-- Cards, entries, calls
-- ---------------------------------------------------------------------------
create table cards (
  id         uuid primary key default gen_random_uuid(),
  match_id   int not null references matches(id) on delete cascade,
  mode       card_mode not null,
  crew_id    uuid references crews(id) on delete cascade,   -- null = public card
  created_by uuid references profiles(id),
  status     card_status not null default 'open',
  created_at timestamptz not null default now(),
  locked_at  timestamptz,
  settled_at timestamptz
);
-- one public card per match, one card per crew per match
create unique index cards_public_unique on cards(match_id) where crew_id is null;
create unique index cards_crew_unique   on cards(match_id, crew_id) where crew_id is not null;
create index cards_crew_idx on cards(crew_id);

create table entries (
  id              uuid primary key default gen_random_uuid(),
  card_id         uuid not null references cards(id) on delete cascade,
  user_id         uuid not null references profiles(id) on delete cascade,
  matchday        date not null,                  -- kickoff date (UTC); the boost budget is per matchday
  boost_call_type call_type,
  points          int not null default 0,
  hits            int not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (card_id, user_id)
);
create index entries_user_idx on entries(user_id);
-- §2.2: one boost per player per matchday across every card they play that day
create unique index entries_one_boost_per_matchday on entries(user_id, matchday) where boost_call_type is not null;

create table calls (
  id             uuid primary key default gen_random_uuid(),
  entry_id       uuid not null references entries(id) on delete cascade,
  call_type      call_type not null,
  team_id        int references teams(id),      -- winner
  yes            boolean,                       -- draw
  player_id      int references players(id),    -- motm / scorer / assist / yellow / red
  home_goals     int check (home_goals between 0 and 20),
  away_goals     int check (away_goals between 0 and 20),
  result         call_result not null default 'pending',
  points_awarded int not null default 0,
  settled_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (entry_id, call_type),
  constraint call_value_shape check (
    case call_type
      when 'winner' then team_id is not null
      when 'draw'   then yes is not null
      when 'score'  then home_goals is not null and away_goals is not null
      else player_id is not null
    end
  )
);
create index calls_entry_idx on calls(entry_id);

-- ---------------------------------------------------------------------------
-- Album (§5.7): one sticker per (competition, call type) per season
-- ---------------------------------------------------------------------------
create table stickers (
  user_id          uuid not null references profiles(id) on delete cascade,
  competition_code text not null references competitions(code),
  season           text not null,
  call_type        call_type not null,
  earned_at        timestamptz not null default now(),
  match_id         int references matches(id),
  primary key (user_id, competition_code, season, call_type)
);

-- ---------------------------------------------------------------------------
-- Crew room feed (§5.6): posts, and receipts for landed calls
-- ---------------------------------------------------------------------------
create table crew_posts (
  id         uuid primary key default gen_random_uuid(),
  crew_id    uuid not null references crews(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  body       text check (char_length(body) <= 500),
  call_id    uuid references calls(id) on delete set null,   -- receipt: "Called a goalscorer · +7"
  created_at timestamptz not null default now(),
  check (body is not null or call_id is not null)
);
create index crew_posts_crew_idx on crew_posts(crew_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Outbound email queue (§7). Edge function send-notifications drains it via Resend.
-- ---------------------------------------------------------------------------
create table notifications (
  id            bigserial primary key,
  user_id       uuid not null references profiles(id) on delete cascade,
  type          text not null check (type in ('new_card', 'deadline_reminder', 'crew_activity', 'result', 'weekly_digest', 'correction')),
  dedupe_key    text not null,               -- prevents duplicates (e.g. one crew digest per user per hour)
  payload       jsonb not null default '{}',
  scheduled_for timestamptz not null default now(),
  sent_at       timestamptz,
  error         text,
  created_at    timestamptz not null default now(),
  unique (user_id, type, dedupe_key)
);
create index notifications_pending_idx on notifications(scheduled_for) where sent_at is null;

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger entries_touch before update on entries for each row execute function touch_updated_at();
create trigger calls_touch   before update on calls   for each row execute function touch_updated_at();
create trigger matches_touch before update on matches for each row execute function touch_updated_at();
