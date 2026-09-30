-- 02 — One chaining rule for the hourly ledger.
-- Problem: snapshot_hourly only chained rows from the last 12 h, so after a longer
-- outage the first hour back opened at its own first reading and the tonnage
-- moved during the gap vanished. repair_hourly_chain did the opposite (whole gap
-- into one hour). greatest(0, ...) also hid totalizer resets.
-- Rule now (both functions): opening = previous logged hour's closing for that
-- device, however long ago. The gap's tonnage lands in the first hour back and is
-- flagged 'gap'. A closing below the previous closing is a totalizer reset: tons
-- = 0 and flagged 'reset' so it can be reviewed rather than hidden.
-- BACK UP public.hourly BEFORE running repair_hourly_chain().

alter table public.hourly add column if not exists flag text;

create or replace function public.iss_chain_hourly(p_since timestamptz default null)
returns void language sql security definer set search_path = public as $$
  with chained as (
    select id, hour, closing, opening as raw_open,
           lag(closing) over w as prev_close,
           lag(hour)    over w as prev_hour
    from public.hourly
    window w as (partition by device order by hour)
  )
  update public.hourly h
     set opening = coalesce(c.prev_close, c.raw_open),
         tons    = case when c.prev_close is not null and h.closing < c.prev_close then 0
                        else h.closing - coalesce(c.prev_close, c.raw_open) end,
         flag    = case when c.prev_close is not null and h.closing < c.prev_close then 'reset'
                        when c.prev_hour is not null and c.hour - c.prev_hour > interval '1 hour' then 'gap'
                        else null end
    from chained c
   where h.id = c.id
     and (p_since is null or c.hour >= p_since);
$$;
revoke execute on function public.iss_chain_hourly(timestamptz) from public, anon, authenticated;

create or replace function public.snapshot_hourly() returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.hourly (device, site, scale_name, hour, opening, closing, tons)
  select r.device, max(r.site), max(r.scale_name), date_trunc('hour', r.ts),
         (array_agg(r.total order by r.ts))[1],
         (array_agg(r.total order by r.ts desc))[1], 0
    from public.readings r
   where r.total is not null and coalesce(r.scale_name,'') <> 'gateway'
     and r.ts >= now() - interval '3 hours'
   group by r.device, date_trunc('hour', r.ts)
  on conflict (device, hour) do update
    set closing    = excluded.closing,
        site       = coalesce(excluded.site, public.hourly.site),
        scale_name = coalesce(excluded.scale_name, public.hourly.scale_name);

  perform public.iss_chain_hourly(now() - interval '12 hours');
end $$;
revoke execute on function public.snapshot_hourly() from public, anon, authenticated;

create or replace function public.repair_hourly_chain() returns void
language sql security definer set search_path = public as $$
  select public.iss_chain_hourly(null);
$$;
revoke execute on function public.repair_hourly_chain() from public, anon, authenticated;
