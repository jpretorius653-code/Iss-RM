-- 07 — Housekeeping and tighter access. APPLIED 2026-11-15.
--
-- A. Uploads that change nothing no longer rewrite the row.
--    Hillside's Cloud Sync re-sends every ticket it has ever made every 30
--    seconds (≈26 000 requests and ≈11 million row rewrites a day for ~4 000
--    tickets). Each rewrite only moved updated_at. An identical upload is now
--    skipped unless the row has not been touched for 10 minutes, which keeps
--    updated_at fresh enough for the sync_silent alert (18 h threshold).
-- B. Duplicate indexes and a duplicate read policy dropped.
-- C. Backup tables moved out of the API-exposed schema (kept, not dropped).
-- D. The public key can only insert tickets for the one site that still uses
--    Cloud Sync (hillside). Every other site uploads with its own login.
-- E. scale_data (legacy, last written 2 Aug 2026) is no longer world-readable
--    and world-writable.
-- F. Alerts are evaluated once per run instead of twice.
-- G. Order tonnage is summed in the database (iss_order_tons).
--
-- NOT changed, on purpose:
--   * anon INSERT on readings — the ESP32 boxes in the field post with the
--     public key and have no update path yet. Closing it stops belt scales.
--   * Hillside's Cloud Sync holding the service key — needs a Cloud Sync
--     release and a visit/remote session to the Hillside PC.

-- ───────────── A. skip no-op uploads (guard gets one more early exit) ─────────────
create or replace function public.iss_tx_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  e   public.transactions;
  k   text;
begin
  -- Only uploads arriving through the API are guarded. An ISS engineer working
  -- in the SQL editor (session user postgres) is trusted to mean what he types.
  if coalesce(current_setting('iss.guard_off', true), '') = 'on'
     or session_user in ('postgres', 'supabase_admin') then
    return new;
  end if;
  begin
    if tg_op = 'INSERT' then
      if new.ticket is null or btrim(new.ticket) = '' then return new; end if;
      -- same row arriving again -> the ON CONFLICT ... DO UPDATE path handles it
      if exists (select 1 from public.transactions t where t.row_id = new.row_id) then return new; end if;
      if new.ext_id is not null and exists (select 1 from public.transactions t where t.ext_id = new.ext_id) then return new; end if;

      select * into e from public.transactions t where t.site = new.site and t.ticket = new.ticket limit 1;
      if not found then return new; end if;

      -- (site, ticket) is taken by ANOTHER row. A plain insert would fail with
      -- 23505, which the app reads as "already uploaded" and never retries.
      if public.iss_tx_same_weighing(e, new) then
        -- the same truck under a new row id: refresh the row we have, unless
        -- that would drag a finished ticket back to 'open'
        if not (e.status in ('complete','void') and coalesce(new.status,'open') = 'open') then
          update public.transactions t set
            customer = new.customer, product = new.product, action = new.action, reg = new.reg,
            empty_weight = new.empty_weight, full_weight = new.full_weight, net = new.net,
            time_in = new.time_in, time_out = new.time_out, batch_no = new.batch_no,
            dispatch_ticket = new.dispatch_ticket, destination = new.destination,
            transporter = new.transporter, operator = new.operator, bridge = new.bridge,
            status = new.status, supplier = new.supplier, driver = new.driver, order_no = new.order_no,
            trailer1 = new.trailer1, trailer2 = new.trailer2, seal_no = new.seal_no,
            extra = coalesce(new.extra, t.extra)
          where t.id = e.id;
        end if;
        return null;
      end if;

      -- a different truck under the same number: keep it, do not lose it
      perform public.iss_tx_park('number_clash', 'clash:' || new.row_id::text, e, new);
      return null;
    end if;

    -- ── UPDATE ──
    -- a ticket the cloud re-numbered (keep both) keeps its cloud number
    if new.ticket is distinct from old.ticket and new.ticket is not null
       and exists (select 1 from public.transactions t
                    where t.site = new.site and t.ticket = new.ticket and t.id <> old.id) then
      new.ticket := old.ticket;
    end if;

    -- an upload identical to what is stored: do not rewrite the row. Let one
    -- through every 10 minutes so updated_at still shows the site is alive.
    if old.updated_at > now() - interval '10 minutes'
       and (to_jsonb(old) - 'updated_at') = (to_jsonb(new) - 'updated_at') then
      return null;
    end if;

    -- a finished ticket never goes back to "truck on site"
    if old.status = 'complete' and coalesce(new.status,'open') = 'open' then
      perform public.iss_tx_park('stale_open', 'stale:' || old.row_id::text, old, new);
      return null;
    end if;

    -- a finished ticket is never replaced by a DIFFERENT weighing.
    -- A correction keeps the completion time; a second weigh-out does not.
    if old.status = 'complete' and new.status = 'complete'
       and old.time_out is not null and new.time_out is not null
       and abs(extract(epoch from (new.time_out - old.time_out))) > 2
       and (not public.iss_tx_same_weighing(old, new) or new.net is distinct from old.net) then
      k := 'over:' || old.row_id::text || ':' ||
           md5(concat_ws('|', upper(btrim(coalesce(new.reg,''))), new.time_in::text, new.time_out::text, new.net::text));
      -- an admin already chose "replace" for exactly this upload: let it through
      if exists (select 1 from public.ticket_conflicts c where c.dedupe_key = k and c.resolution = 'replace') then
        return new;
      end if;
      perform public.iss_tx_park('overwrite', k, old, new);
      return null;
    end if;

    return new;
  exception when others then
    raise warning 'iss_tx_guard: %', sqlerrm;        -- fail open: old behaviour
    return new;
  end;
end $$;

-- ───────────── B. duplicates ─────────────
drop index if exists public.transactions_site_time_ix;   -- identical to transactions_site_timein_ix
drop index if exists public.transactions_ticket_idx;     -- same columns as the unique transactions_site_ticket_key
-- tx_site_select already grants everything this one did (admin, or own site —
-- and it matches the site code case-insensitively)
drop policy if exists transactions_auth_select on public.transactions;
-- evaluate auth.uid() once per query, not once per row
alter policy user_sites_self on public.user_sites using (user_id = (select auth.uid()));
alter policy hourly_audit_admin_read on public.hourly_audit
  using (exists (select 1 from public.user_sites us where us.user_id = (select auth.uid()) and us.is_admin));

-- ───────────── C. backups out of the API schema ─────────────
create schema if not exists archive;
revoke all on schema archive from public, anon, authenticated;
alter table if exists public.hourly_backup_20261001   set schema archive;
alter table if exists public.transactions_rietcoal_bak set schema archive;

-- ───────────── D. public-key ticket inserts: Cloud Sync sites only ─────────────
-- Add a site here ONLY if it uploads through Cloud Sync with the public key.
drop policy if exists "anon insert" on public.transactions;
drop policy if exists anon_insert_cloudsync on public.transactions;
create policy anon_insert_cloudsync on public.transactions for insert to anon
  with check (site = 'hillside' and lower(ext_id) like 'hillside:%');

-- ───────────── E. legacy scale_data ─────────────
drop policy if exists "Allow public insert access" on public.scale_data;
drop policy if exists "Allow public read access"   on public.scale_data;
drop policy if exists "anon insert" on public.scale_data;
drop policy if exists "anon read"   on public.scale_data;
drop policy if exists scale_data_admin_read on public.scale_data;
create policy scale_data_admin_read on public.scale_data for select to authenticated using (public.iss_is_admin());

-- ───────────── F. alerts: one evaluation per run ─────────────
create or replace function public.iss_run_alerts() returns void
language plpgsql security definer set search_path = public as $$
begin
  with c as materialized (select * from public.iss_alert_candidates()),
  ins as (
    insert into public.alerts (site, kind, subject, severity, message)
    select c.site, c.kind, c.subject, c.severity, c.message from c
    on conflict (kind, subject) where resolved_at is null
    do update set message = excluded.message, severity = excluded.severity
    returning 1
  )
  update public.alerts a set resolved_at = now()
   where a.resolved_at is null
     and not exists (select 1 from c where c.kind = a.kind and c.subject = a.subject)
     and (select count(*) from ins) >= 0;      -- forces the insert to run in this statement
end $$;

-- ───────────── G. order tonnage summed in the database ─────────────
-- The dashboard used to download every completed ticket that carries an order
-- number, for all time, to add them up in the browser. RLS still applies
-- (security invoker), so a site or customer login only sums what it may see.
create or replace function public.iss_order_tons(p_site text default null)
returns table(order_no text, action text, kg numeric, tickets bigint)
language sql stable security invoker set search_path = public as $$
  select btrim(t.order_no), t.action, sum(coalesce(t.net, 0)), count(*)
    from public.transactions t
   where t.status = 'complete' and t.order_no is not null and btrim(t.order_no) <> ''
     and (p_site is null or btrim(p_site) = '' or t.site = lower(btrim(p_site)))
   group by 1, 2;
$$;
revoke all on function public.iss_order_tons(text) from public, anon;
grant execute on function public.iss_order_tons(text) to authenticated;

-- ───────────── function hygiene ─────────────
alter function public.iss_tx_same_weighing(public.transactions, public.transactions) set search_path = public;
-- trigger functions are never called directly; firing a trigger needs no EXECUTE
revoke all on function public.iss_tx_guard()       from public, anon, authenticated;
revoke all on function public.iss_tx_history()     from public, anon, authenticated;
revoke all on function public.iss_tx_no_delete()   from public, anon, authenticated;
revoke all on function public.iss_history_locked() from public, anon, authenticated;
