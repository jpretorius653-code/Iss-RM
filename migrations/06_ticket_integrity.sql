-- 06 — Ticket integrity: nothing a weighbridge uploads can be silently lost,
--      overwritten or deleted again.
--
-- WHY (MMS, 9–11 Nov 2026 — see docs/TICKET-LOSS-ANALYSIS.md)
--   Two PCs on one site issued the same ticket numbers. Three things then
--   destroyed data without anybody being told:
--     1. A second ticket with a number already in the cloud hit the
--        (site, ticket) unique index. The app treats that error as "already
--        uploaded", marks the ticket as sent and never tries again.
--     2. A truck completed on PC A was completed AGAIN from PC B's stale
--        "on site" list. Both carry the same row_id, so the second upload
--        replaced the first ticket in place.
--     3. A stale "on site" copy re-sent every 5 minutes flipped a completed
--        ticket back to 'open', taking it out of every report.
--   Hillside (Cloud Sync, ext_id = site:ticket) has the same exposure: two
--   different trucks under one ticket number overwrite each other.
--
-- WHAT THIS ADDS (additive — no existing column, row or policy is changed)
--   A. transactions_history  append-only log of every insert/update/delete.
--   B. ticket_conflicts      an upload that would have been lost or would
--                            have overwritten a completed ticket is PARKED
--                            here instead, and the original left untouched.
--   C. iss_resolve_conflict  admin decision: keep both / replace / discard.
--   D. Alerts                ticket_conflict (crit), ticket_gap (warn).
--   E. Completed tickets cannot be hard-deleted; anon loses DELETE/TRUNCATE.
--
-- SAFETY
--   * Every trigger body is wrapped so that a fault inside it falls back to
--     the old behaviour. A bug here can never stop a site uploading.
--   * Rollback: see the block at the bottom of this file.

-- ───────────────────────── A. history ─────────────────────────
create table if not exists public.transactions_history (
  id       bigint generated always as identity primary key,
  at       timestamptz not null default now(),
  op       text not null check (op in ('INSERT','UPDATE','DELETE')),
  tx_id    uuid,
  row_id   uuid,
  site     text,
  ticket   text,
  actor    text,
  old_row  jsonb,
  new_row  jsonb
);
create index if not exists transactions_history_site_ticket_ix on public.transactions_history (site, ticket);
create index if not exists transactions_history_row_ix         on public.transactions_history (row_id);
create index if not exists transactions_history_at_ix          on public.transactions_history (at desc);
alter table public.transactions_history enable row level security;
revoke all on public.transactions_history from anon, authenticated;
grant select on public.transactions_history to authenticated;
drop policy if exists tx_history_read on public.transactions_history;
create policy tx_history_read on public.transactions_history for select to authenticated
  using (public.iss_is_admin() or (public.iss_my_customer() is null and public.iss_may_use_site(site)));

create or replace function public.iss_actor() returns text
language plpgsql stable set search_path = public as $$
declare c jsonb;
begin
  begin c := nullif(current_setting('request.jwt.claims', true), '')::jsonb; exception when others then c := null; end;
  return coalesce(c->>'email', c->>'role', session_user::text);
end $$;

create or replace function public.iss_tx_history() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if tg_op = 'INSERT' then
      insert into public.transactions_history (op, tx_id, row_id, site, ticket, actor, new_row)
      values ('INSERT', new.id, new.row_id, new.site, new.ticket, public.iss_actor(), to_jsonb(new));
    elsif tg_op = 'UPDATE' then
      -- open rows are re-sent unchanged every few minutes: do not log a no-op
      if (to_jsonb(old) - 'updated_at') is distinct from (to_jsonb(new) - 'updated_at') then
        insert into public.transactions_history (op, tx_id, row_id, site, ticket, actor, old_row, new_row)
        values ('UPDATE', new.id, new.row_id, new.site, new.ticket, public.iss_actor(), to_jsonb(old), to_jsonb(new));
      end if;
    else
      insert into public.transactions_history (op, tx_id, row_id, site, ticket, actor, old_row)
      values ('DELETE', old.id, old.row_id, old.site, old.ticket, public.iss_actor(), to_jsonb(old));
    end if;
  exception when others then
    raise warning 'iss_tx_history: %', sqlerrm;      -- never block the write itself
  end;
  return null;
end $$;

drop trigger if exists iss_tx_history_trg on public.transactions;
create trigger iss_tx_history_trg after insert or update or delete on public.transactions
  for each row execute function public.iss_tx_history();

-- the log itself cannot be edited or emptied through the API or by accident
create or replace function public.iss_history_locked() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('iss.maintenance', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  raise exception 'transactions_history is append-only';
end $$;
drop trigger if exists iss_history_locked_trg on public.transactions_history;
create trigger iss_history_locked_trg before update or delete on public.transactions_history
  for each row execute function public.iss_history_locked();

-- ───────────────────────── B. conflicts ─────────────────────────
create table if not exists public.ticket_conflicts (
  id               bigint generated always as identity primary key,
  created_at       timestamptz not null default now(),
  last_seen_at     timestamptz not null default now(),
  seen_count       integer not null default 1,
  site             text not null,
  ticket           text,
  kind             text not null check (kind in ('number_clash','overwrite','stale_open')),
  dedupe_key       text not null unique,
  existing_row_id  uuid,
  incoming_row_id  uuid,
  existing_row     jsonb,
  incoming_row     jsonb not null,
  resolved_at      timestamptz,
  resolved_by      text,
  resolution       text check (resolution in ('keep_both','replace','discard','ignored')),
  result_ticket    text
);
create index if not exists ticket_conflicts_open_ix on public.ticket_conflicts (site) where resolved_at is null;
alter table public.ticket_conflicts enable row level security;
revoke all on public.ticket_conflicts from anon, authenticated;
grant select on public.ticket_conflicts to authenticated;
drop policy if exists ticket_conflicts_read on public.ticket_conflicts;
create policy ticket_conflicts_read on public.ticket_conflicts for select to authenticated
  using (public.iss_is_admin() or (public.iss_my_customer() is null and public.iss_may_use_site(site)));

-- Park one upload. Re-sends of the same thing only bump the counter.
create or replace function public.iss_tx_park(p_kind text, p_key text, p_existing public.transactions,
                                              p_incoming public.transactions)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.ticket_conflicts (site, ticket, kind, dedupe_key, existing_row_id, incoming_row_id,
                                       existing_row, incoming_row, resolved_at, resolution)
  values (p_incoming.site, p_incoming.ticket, p_kind, p_key, p_existing.row_id, p_incoming.row_id,
          to_jsonb(p_existing), to_jsonb(p_incoming),
          case when p_kind = 'stale_open' then now() end,
          case when p_kind = 'stale_open' then 'ignored' end)
  on conflict (dedupe_key) do update
     set last_seen_at = now(),
         seen_count   = public.ticket_conflicts.seen_count + 1,
         -- an unresolved clash keeps the newest copy the bridge sent (open -> complete)
         incoming_row = case when public.ticket_conflicts.resolved_at is null
                             then excluded.incoming_row else public.ticket_conflicts.incoming_row end;
end $$;

-- True when two rows describe the same physical weighing.
create or replace function public.iss_tx_same_weighing(a public.transactions, b public.transactions)
returns boolean language sql immutable as $$
  select upper(btrim(coalesce(a.reg,''))) = upper(btrim(coalesce(b.reg,'')))
     and a.time_in is not distinct from b.time_in;
$$;

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

-- "zz_" so it runs after the existing BEFORE triggers (row_id fill, site lower-casing)
drop trigger if exists zz_iss_tx_guard on public.transactions;
create trigger zz_iss_tx_guard before insert or update on public.transactions
  for each row execute function public.iss_tx_guard();

-- ───────────────────────── C. resolve ─────────────────────────
-- keep_both : the parked upload becomes its own ticket, numbered <ticket>A, B, …
-- replace   : (overwrite only) the parked upload replaces the ticket; the old one stays in history
-- discard   : the parked upload is dropped; it stays readable in ticket_conflicts
create or replace function public.iss_resolve_conflict(p_id bigint, p_action text)
returns text language plpgsql security definer set search_path = public as $$
declare
  c    public.ticket_conflicts;
  r    public.transactions;
  base text;
  nt   text;
  i    int := 0;
begin
  if not public.iss_is_admin() then raise exception 'ISS admin only'; end if;
  select * into c from public.ticket_conflicts where id = p_id for update;
  if not found then raise exception 'No such conflict'; end if;
  if c.resolved_at is not null then raise exception 'Already resolved (%)', c.resolution; end if;
  if p_action not in ('keep_both','replace','discard') then raise exception 'Unknown action %', p_action; end if;

  r := jsonb_populate_record(null::public.transactions, c.incoming_row);
  perform set_config('iss.guard_off', 'on', true);

  if p_action = 'keep_both' then
    base := coalesce(c.ticket, r.ticket, 'TICKET');
    loop
      nt := base || case when i < 26 then chr(65 + i) else '-' || (i - 24)::text end;
      exit when not exists (select 1 from public.transactions t where t.site = c.site and t.ticket = nt);
      i := i + 1;
      if i > 500 then raise exception 'No free suffix for %', base; end if;
    end loop;
    r.id     := gen_random_uuid();
    r.ticket := nt;
    r.site   := c.site;
    if exists (select 1 from public.transactions t where t.row_id = r.row_id) then r.row_id := gen_random_uuid(); end if;
    if r.ext_id is not null and exists (select 1 from public.transactions t where t.ext_id = r.ext_id) then
      r.ext_id := r.ext_id || ':' || nt;
    end if;
    insert into public.transactions values (r.*);
  elsif p_action = 'replace' then
    if c.kind <> 'overwrite' then raise exception 'Replace applies to an overwrite only — use keep_both or discard'; end if;
    update public.transactions t set
      customer = r.customer, product = r.product, action = r.action, reg = r.reg,
      empty_weight = r.empty_weight, full_weight = r.full_weight, net = r.net,
      time_in = r.time_in, time_out = r.time_out, batch_no = r.batch_no,
      dispatch_ticket = r.dispatch_ticket, destination = r.destination, transporter = r.transporter,
      operator = r.operator, bridge = r.bridge, status = r.status, supplier = r.supplier,
      driver = r.driver, order_no = r.order_no, trailer1 = r.trailer1, trailer2 = r.trailer2,
      seal_no = r.seal_no, extra = r.extra
    where t.row_id = c.existing_row_id;
    nt := c.ticket;
  end if;

  perform set_config('iss.guard_off', '', true);
  update public.ticket_conflicts
     set resolved_at = now(), resolved_by = public.iss_actor(), resolution = p_action, result_ticket = nt
   where id = p_id;
  return coalesce(nt, p_action);
end $$;
revoke all on function public.iss_resolve_conflict(bigint, text) from public, anon;
grant execute on function public.iss_resolve_conflict(bigint, text) to authenticated;
revoke all on function public.iss_tx_park(text, text, public.transactions, public.transactions) from public, anon, authenticated;

-- Missing ticket numbers per site/prefix among tickets active in the window.
-- A number counts as missing only once a HIGHER number has been in the cloud
-- for two hours (uploads can arrive out of order).
create or replace function public.iss_ticket_gaps(p_days integer default 14)
returns table(site text, prefix text, n bigint, ticket text)
language sql stable security definer set search_path = public as $$
  with t as (
    select lower(x.site) as site,
           substring(x.ticket from '^([^0-9]*)') as pre,
           substring(x.ticket from '^[^0-9]*([0-9]{1,12})')::bigint as n,
           length(substring(x.ticket from '^[^0-9]*([0-9]{1,12})')) as pad,
           x.updated_at as up,
           coalesce(x.time_out, x.time_in, x.updated_at) as ts
      from public.transactions x
     where x.ticket ~ '^[^0-9]*[0-9]{1,12}'
       and (public.iss_is_admin() or session_user in ('postgres','supabase_admin')
            or (public.iss_my_customer() is null and public.iss_may_use_site(x.site)))
  ), w as (
    select t.site, t.pre, min(t.n) lo, max(t.n) hi, max(t.pad) pad
      from t where t.ts > now() - make_interval(days => greatest(p_days,1))
     group by 1,2 having max(t.n) - min(t.n) < 20000
  )
  select w.site, w.pre, g, w.pre || lpad(g::text, w.pad, '0')
    from w cross join lateral generate_series(w.lo, w.hi) g
   where not exists (select 1 from t where t.site = w.site and t.pre = w.pre and t.n = g)
     and exists (select 1 from t where t.site = w.site and t.pre = w.pre and t.n > g
                                   and t.up < now() - interval '2 hours');
$$;
revoke all on function public.iss_ticket_gaps(integer) from public, anon;
grant execute on function public.iss_ticket_gaps(integer) to authenticated;

-- ───────────────────────── D. alerts ─────────────────────────
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
  having max(t.updated_at) < now() - interval '18 hours' and max(t.updated_at) > now() - interval '7 days'
  union all
  -- an upload was parked instead of being lost: somebody has to decide
  select 'ticket_conflict', lower(c.site) || ':' || max(c.id)::text, lower(c.site), 'crit',
         format('%s: %s ticket upload(s) clashed with an existing ticket and are HELD (%s) — open Admin → Ticket integrity',
                lower(c.site), count(*), string_agg(coalesce(c.ticket,'?'), ', ' order by c.id))
    from public.ticket_conflicts c
   where c.resolved_at is null and c.kind in ('number_clash','overwrite')
   group by lower(c.site)
  union all
  -- a bridge keeps re-sending a truck as "on site" after its ticket completed
  select 'stale_onsite', lower(c.site), lower(c.site), 'warn',
         format('%s: a weighbridge PC still lists %s finished truck(s) as on site (%s) — its on-site list is out of step with the other PC',
                lower(c.site), count(*), string_agg(coalesce(c.ticket, c.incoming_row->>'reg', '?'), ', ' order by c.id))
    from public.ticket_conflicts c
   where c.kind = 'stale_open' and c.last_seen_at > now() - interval '30 minutes' and c.seen_count >= 3
   group by lower(c.site)
  union all
  select 'ticket_gap', g.site || ':' || g.prefix || ':' || max(g.n)::text, g.site, 'warn',
         format('%s: %s ticket number(s) issued at the bridge never reached the cloud — %s',
                g.site, count(*), string_agg(g.ticket, ', ' order by g.n))
    from public.iss_ticket_gaps(14) g
   group by g.site, g.prefix
  having count(*) <= 200;
$$;

-- ───────────────────────── E. no hard deletes ─────────────────────────
create or replace function public.iss_tx_no_delete() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.status in ('complete','void')
     and coalesce(current_setting('iss.allow_ticket_delete', true), '') <> 'on' then
    raise exception 'Ticket % (%) is a finished ticket and cannot be deleted — void it instead', old.ticket, old.site
      using errcode = 'P0001',
            hint = 'ISS engineer, deliberate removal: run  set local iss.allow_ticket_delete = ''on'';  in the same transaction. The row stays in transactions_history.';
  end if;
  return old;
end $$;
drop trigger if exists iss_tx_no_delete_trg on public.transactions;
create trigger iss_tx_no_delete_trg before delete on public.transactions
  for each row execute function public.iss_tx_no_delete();

-- the public key never needed these; RLS does not cover TRUNCATE at all
revoke truncate, delete on public.transactions from anon;
revoke truncate on public.transactions from authenticated;

-- ───────────────────────── ROLLBACK ─────────────────────────
-- drop trigger zz_iss_tx_guard on public.transactions;          -- parking off
-- drop trigger iss_tx_no_delete_trg on public.transactions;     -- delete guard off
-- drop trigger iss_tx_history_trg on public.transactions;       -- history off
-- (re-run 04_alerts.sql to restore the previous alert list)
-- The tables can stay; they are only written by the triggers above.
