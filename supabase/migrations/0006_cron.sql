-- The Pool — scheduled jobs (pg_cron + pg_net calling the edge functions).
--
-- Applied to production 2026-10-26. Three of the six jobs are live — lock-cards,
-- deadline-reminders and weekly-digest, all pure SQL needing no secret. The other three are
-- commented out below with the reason against each. `tests/run.sh` still skips this file:
-- pg_cron and pg_net are hosted-only.
-- Installed in its own schema so it never touches the other tables in this project.
create schema if not exists pool;
set search_path = pool, public, extensions;
-- Runs on Supabase only. Before applying, store two secrets in Vault:
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<service_role_key>',                'service_role_key');

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net  with schema extensions;

create or replace function call_edge_function(p_name text, p_body jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path = pool, public, extensions as $$
declare url text; key text; req bigint;
begin
  select decrypted_secret into url from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into key from vault.decrypted_secrets where name = 'service_role_key';
  select net.http_post(
    url := url || '/functions/v1/' || p_name,
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || key),
    body := p_body,
    timeout_milliseconds := 55000
  ) into req;
  return req;
end $$;

revoke execute on function call_edge_function(text, jsonb) from public, anon, authenticated;

-- RETIRED (2026-10-26, see 0024). These two scheduled the football-data.org edge functions,
-- which were replaced first by the ESPN sync and then by sync/api-football.mjs running on the
-- app server under thepool-sync.timer. Scheduling them now would point a second, retired
-- provider at the same `matches` rows every minute and fight the live sync over them, so they
-- are not applied. The edge functions themselves are still deployed but are never called.
--
-- select cron.schedule('sync-fixtures', '7,37 * * * *', $$ select pool.call_edge_function('sync-fixtures') $$);
-- select cron.schedule('sync-live',     '* * * * *',    $$ select pool.call_edge_function('sync-live') $$);

-- Lock cards at kickoff even if the provider is late
select cron.schedule('lock-cards', '* * * * *', $$ select pool.sync_card_status() $$);

-- Deadline reminders (60 min before kickoff, §7)
select cron.schedule('deadline-reminders', '*/5 * * * *', $$ select pool.enqueue_deadline_reminders() $$);

-- Friday crew card, 09:00 UTC
select cron.schedule('weekly-digest', '0 9 * * 5', $$ select pool.enqueue_weekly_digest() $$);

-- Drain the email queue.
--
-- NOT APPLIED either, and for a different reason: call_edge_function() needs the service-role
-- key in the database's vault, and the key is already on the sync host. sync/api-football.mjs
-- drains the queue at the end of each pass instead, which is the same once-a-minute cadence
-- without the key ever reaching the database. To hand it back to Supabase, store the two
-- secrets and uncomment this line — then drop drainMail() from the sync, or the queue is
-- drained twice a minute.
--
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<service_role_key>',                'service_role_key');
--
-- select cron.schedule('send-notifications', '* * * * *', $$ select pool.call_edge_function('send-notifications') $$);
