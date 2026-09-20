-- The Pool — scheduled jobs (pg_cron + pg_net calling the edge functions).
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

-- Fixtures and squads: twice an hour at :07 and :37 (sync-live stays quiet in those minutes so the
-- free tier's 10 req/min is never shared between two runs)
select cron.schedule('sync-fixtures', '7,37 * * * *', $$ select pool.call_edge_function('sync-fixtures') $$);

-- Live scores and events: every minute while anything is in play or about to be
select cron.schedule('sync-live', '* * * * *', $$ select pool.call_edge_function('sync-live') $$);

-- Lock cards at kickoff even if the provider is late
select cron.schedule('lock-cards', '* * * * *', $$ select pool.sync_card_status() $$);

-- Deadline reminders (60 min before kickoff, §7)
select cron.schedule('deadline-reminders', '*/5 * * * *', $$ select pool.enqueue_deadline_reminders() $$);

-- Friday crew card, 09:00 UTC
select cron.schedule('weekly-digest', '0 9 * * 5', $$ select pool.enqueue_weekly_digest() $$);

-- Drain the email queue
select cron.schedule('send-notifications', '* * * * *', $$ select pool.call_edge_function('send-notifications') $$);
