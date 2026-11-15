-- 08 — Alerts by e-mail. APPLIED 2026-11-15.
--
-- Until now an alert existed only inside the dashboard. Every 5 minutes the
-- database now calls the alert-notify Edge Function, which e-mails each new
-- alert once to the people listed in alert_recipients.
--
--   * A recipient gets all sites (site null) or one site, and either critical
--     alerts only or warnings too.
--   * One e-mail per recipient per run, listing every new alert — a site
--     going down produces one message, not twenty.
--   * An alert is mailed only after it has been open 10 minutes (a belt scale
--     that blips for a minute stays quiet). Held ticket uploads go at once.
--   * Sending needs a Resend API key stored as the Edge Function secret
--     RESEND_API_KEY. Without it nothing is sent and nothing is marked sent.

create extension if not exists pg_net;

alter table public.alerts add column if not exists notified_at  timestamptz;
alter table public.alerts add column if not exists notify_error text;
-- what is already open was seen in the dashboard; do not mail the backlog
update public.alerts set notified_at = now() where notified_at is null;
create index if not exists alerts_unnotified_ix on public.alerts (created_at) where notified_at is null and resolved_at is null;

create table if not exists public.alert_recipients (
  id            bigint generated always as identity primary key,
  email         text not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  site          text,                               -- null = every site
  min_severity  text not null default 'crit' check (min_severity in ('crit','warn')),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    text default public.iss_actor()
);
create unique index if not exists alert_recipients_uq on public.alert_recipients (lower(email), coalesce(lower(site), ''));
alter table public.alert_recipients enable row level security;
revoke all on public.alert_recipients from anon;
grant select, insert, update, delete on public.alert_recipients to authenticated;
drop policy if exists alert_recipients_admin on public.alert_recipients;
create policy alert_recipients_admin on public.alert_recipients for all to authenticated
  using (public.iss_is_admin()) with check (public.iss_is_admin());

create or replace function public.iss_recipient_clean() returns trigger
language plpgsql set search_path = public as $$
begin
  new.email := lower(btrim(new.email));
  new.site  := nullif(lower(btrim(coalesce(new.site, ''))), '');
  return new;
end $$;
drop trigger if exists iss_recipient_clean_trg on public.alert_recipients;
create trigger iss_recipient_clean_trg before insert or update on public.alert_recipients
  for each row execute function public.iss_recipient_clean();

-- one minute after each alert evaluation (which runs on the 5s)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'iss_alert_notify';
    perform cron.schedule('iss_alert_notify', '1-59/5 * * * *',
      $job$select net.http_post(
             url := 'https://cslrbpptdcehxbljgvvm.supabase.co/functions/v1/alert-notify',
             headers := '{"Content-Type":"application/json"}'::jsonb,
             body := '{}'::jsonb)$job$);
  end if;
end $$;
