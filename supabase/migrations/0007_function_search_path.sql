-- Pin search_path on the plain helper functions too (Supabase security linter)
alter function pool.touch_updated_at() set search_path = pool, public, extensions;
alter function pool.require_user() set search_path = pool, public, extensions;
alter function pool.card_is_editable(uuid) set search_path = pool, public, extensions;
alter function pool.gen_invite_code() set search_path = pool, public, extensions;
alter function pool.match_kickoff(int) set search_path = pool, public, extensions;
alter function pool.score_call(pool.calls, pool.matches, boolean) set search_path = pool, public, extensions;
