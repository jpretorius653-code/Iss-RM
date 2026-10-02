-- 04 — Server-side alerts. Evaluated every 5 minutes by pg_cron, shown in the dashboard.
-- Additive: new table + functions only. Touches no existing table.
-- Alerts (auto-resolve when the condition clears):
--   scale_silent   belt scale board sent nothing for >15 min          (crit)
--   gateway_silent gateway heartbeat missing >15 min                  (crit)
--   totalizer_reset a belt totalizer went backwards in the last 3 h   (warn)
--   truck_long     ticket open on site >24 h                          (warn)
--   sync_silent    a site with tickets in the last 7 days has none in 18 h (warn)
-- Delivery (email / WhatsApp) is NOT here yet — needs recipients; this table is what it will read.

create table if not exists public.alerts (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  site        text,
  kind        text not null,
  subject     text not null,
  severity    text not null default 'warn',
  message     text not null,
  resolved_at timestamptz,
  acked_at    timestamptz,
  acked_by    text
);
create unique index if not exists alerts_open_uq on public.alerts (kind, subject) where resolved_at is null;
alter table public.alerts enable row level security;

create policy alerts_read on public.alerts for select to authenticated
  using (public.iss_is_admin() or (public.iss_my_customer() is null and lower(site) = lower(public.user_site())));

create or replace function public.iss_alert_candidates()
returns table(kind text, subject text, site text, severity text, message text)
language sql security definer set search_path = public as $$
  select 'scale_silent', s.device, lower(s.site), 'crit',
         format('%s: no data for %s', s.display_name,
           case when now()-s.last_seen > interval '2 hours'
                then round(extract(epoch from now()-s.last_seen)/3600)::int || ' h'
                else round(extract(epoch from now()-s.last_seen)/60)::int || ' min' end)
    from public.scales s
   where s.board_type = 'belt' and not coalesce(s.retired,false) and not coalesce(s.removed,false)
     and s.last_seen < now() - interval '15 minutes'
  union all
  select 'gateway_silent', r.device, lower(max(r.site)), 'crit',
         format('Gateway %s: no heartbeat for %s min', r.device, round(extract(epoch from now()-max(r.ts))/60)::int)
    from public.readings r where r.scale_name = 'gateway'
   group by r.device having max(r.ts) < now() - interval '15 minutes'
  union all
  select 'totalizer_reset', h.device || '@' || h.hour::text, lower(h.site), 'warn',
         format('%s: totalizer went backwards at %s UTC (hour counted as 0 t)', coalesce(h.scale_name,h.device), to_char(h.hour,'DD Mon HH24:MI'))
    from public.hourly h where h.flag = 'reset' and h.hour > now() - interval '3 hours'
  union all
  select 'truck_long', t.id::text, lower(t.site), 'warn',
         format('Truck %s on site for %s h (ticket %s)', coalesce(t.reg,'?'),
                round(extract(epoch from now()-t.time_in)/3600)::int, coalesce(t.ticket,'not issued'))
    from public.transactions t where t.status = 'open' and t.time_in < now() - interval '24 hours'
  union all
  select 'sync_silent', lower(t.site), lower(t.site), 'warn',
         format('%s: no tickets uploaded for %s h — check the weighbridge / Cloud Sync', t.site,
                round(extract(epoch from now()-max(t.updated_at))/3600)::int)
    from public.transactions t where t.site is not null
   group by t.site
  having max(t.updated_at) < now() - interval '18 hours' and max(t.updated_at) > now() - interval '7 days';
$$;

create or replace function public.iss_run_alerts() returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.alerts (site, kind, subject, severity, message)
  select c.site, c.kind, c.subject, c.severity, c.message from public.iss_alert_candidates() c
  on conflict (kind, subject) where resolved_at is null
  do update set message = excluded.message, severity = excluded.severity;

  update public.alerts a set resolved_at = now()
   where a.resolved_at is null
     and not exists (select 1 from public.iss_alert_candidates() c where c.kind = a.kind and c.subject = a.subject);
end $$;

create or replace function public.iss_ack_alert(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.alerts a set acked_at = now(), acked_by = coalesce(auth.jwt()->>'email','?')
   where a.id = p_id and a.acked_at is null
     and (public.iss_is_admin() or (public.iss_my_customer() is null and lower(a.site) = lower(public.user_site())));
end $$;

revoke execute on function public.iss_alert_candidates() from public, anon, authenticated;
revoke execute on function public.iss_run_alerts()       from public, anon, authenticated;
revoke execute on function public.iss_ack_alert(bigint)  from public, anon;
grant  execute on function public.iss_ack_alert(bigint)  to authenticated;

select cron.schedule('iss_alerts', '*/5 * * * *', 'select public.iss_run_alerts()');
