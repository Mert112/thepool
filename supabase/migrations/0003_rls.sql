-- The Pool — row-level security.
-- Installed in its own schema so it never touches the other tables in this project.
create schema if not exists pool;
set search_path = pool, public, extensions;
-- Reads are policy-driven; every write from the app goes through rpc_* (security definer),
-- so tables carry no insert/update/delete policies except the two self-service ones.

-- API roles need explicit access to a non-public schema
grant usage on schema pool to anon, authenticated, service_role;
grant select on all tables in schema pool to anon, authenticated;
grant all on all tables in schema pool to service_role;
grant usage, select on all sequences in schema pool to authenticated, service_role;
grant execute on all functions in schema pool to service_role;
alter default privileges in schema pool grant select on tables to anon, authenticated;
alter default privileges in schema pool grant all on tables to service_role;
alter default privileges in schema pool grant execute on functions to service_role;

alter table markets               enable row level security;
alter table competitions          enable row level security;
alter table teams                 enable row level security;
alter table players               enable row level security;
alter table matches               enable row level security;
alter table match_events          enable row level security;
alter table profiles              enable row level security;
alter table notification_settings enable row level security;
alter table crews                 enable row level security;
alter table crew_members          enable row level security;
alter table cards                 enable row level security;
alter table entries               enable row level security;
alter table calls                 enable row level security;
alter table stickers              enable row level security;
alter table crew_posts            enable row level security;
alter table notifications         enable row level security;

-- Football data and public cards are readable by everyone, signed in or not (the sign-in page teaser)
create policy "public read" on markets      for select using (true);
create policy "public read" on competitions for select using (true);
create policy "public read" on teams        for select using (true);
create policy "public read" on players      for select using (true);
create policy "public read" on matches      for select using (true);
create policy "public read" on match_events for select using (true);

-- Profiles: names are visible to signed-in users (tables, crew rooms); emails are not; only you edit yours
create policy "members read profiles" on profiles for select to authenticated using (true);
revoke select on profiles from authenticated, anon;
grant select (id, display_name, streak, created_at) on profiles to authenticated;
create policy "own profile update"    on profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
grant update (display_name) on profiles to authenticated;

create policy "own settings read"   on notification_settings for select to authenticated using (user_id = auth.uid());
create policy "own settings update" on notification_settings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant update (new_card, deadline_reminder, crew_activity, result, weekly_digest, watched_competitions) on notification_settings to authenticated;

-- Crews: visible to members and to the members of a crew that rivals them (for crew-v-crew)
create policy "crew read" on crews for select to authenticated using (is_crew_member(id) or is_rival_member(id));
revoke select on crews from authenticated, anon;
grant select (id, name, description, mode, owner_id, rival_crew_id, created_at) on crews to authenticated;
create policy "crew members read" on crew_members for select to authenticated using (is_crew_member(crew_id));

-- Cards: public ones to everyone, crew ones to the crew
create policy "cards read" on cards for select using (crew_id is null or is_crew_member(crew_id));

-- Entries: yours always; everyone else's once the card locks (the boost placement is a call too).
-- Before lock, "who is playing" comes from card_players() — names and counts only.
create policy "entries read" on entries for select to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from cards c where c.id = entries.card_id and c.status <> 'open' and can_see_card(c.id))
);

-- Calls: yours always; everyone else's once the card locks (§4)
create policy "calls read" on calls for select to authenticated using (
  exists (
    select 1 from entries e join cards c on c.id = e.card_id
    where e.id = calls.entry_id
      and (e.user_id = auth.uid() or (c.status <> 'open' and can_see_card(c.id)))
  )
);

create policy "own stickers" on stickers for select to authenticated using (user_id = auth.uid());
create policy "crew posts read" on crew_posts for select to authenticated using (is_crew_member(crew_id));

-- notifications: service role only (no policies)

-- Function grants: nothing is callable by default; each migration grants what the app needs
alter default privileges in schema pool revoke execute on functions from public;
revoke execute on all functions in schema pool from public, anon, authenticated;
grant execute on all functions in schema pool to service_role;
grant execute on function card_crowd(uuid) to authenticated;
grant execute on function is_crew_member(uuid, uuid) to authenticated, anon;
grant execute on function can_see_card(uuid, uuid) to authenticated, anon;
grant execute on function is_rival_member(uuid, uuid) to authenticated;
grant execute on function card_players(uuid) to authenticated;
grant execute on function crew_invite_code(uuid) to authenticated;
grant execute on function rpc_set_display_name(text) to authenticated;
grant execute on function rpc_open_card(int, card_mode, uuid) to authenticated;
grant execute on function rpc_set_card_mode(uuid, card_mode) to authenticated;
grant execute on function rpc_save_calls(uuid, jsonb) to authenticated;
grant execute on function rpc_set_boost(uuid, call_type) to authenticated;
grant execute on function rpc_create_crew(text, text, card_mode) to authenticated;
grant execute on function rpc_join_crew(text) to authenticated;
grant execute on function rpc_leave_crew(uuid) to authenticated;
grant execute on function rpc_challenge_crew(uuid, text) to authenticated;
grant execute on function rpc_post(uuid, text) to authenticated;
