-- 01 — Stop the public key calling internal functions.
-- Before: snapshot_hourly / trim_readings / repair_hourly_chain (and the
-- iss_admin_* functions) were EXECUTE-able by anon and PUBLIC.
-- repair_hourly_chain() rewrites the whole ledger; trim_readings() deletes rows.
-- iss_admin_* already check is_admin internally; this is defence in depth.
-- Rollback: grant execute on the same functions to anon, public.

revoke execute on function public.snapshot_hourly()       from public, anon, authenticated;
revoke execute on function public.trim_readings()         from public, anon, authenticated;
revoke execute on function public.repair_hourly_chain()   from public, anon, authenticated;
revoke execute on function public.register_scale()        from public, anon, authenticated;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname like 'iss\_admin\_%'
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant  execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- Pin search_path on the functions the advisor flagged as mutable.
alter function public.iss_fleet_since(text, timestamptz)   set search_path = public;
alter function public.iss_orders_since(text, timestamptz)  set search_path = public;
alter function public.iss_live_touch()                     set search_path = public;
alter function public.iss_lower_site()                     set search_path = public;
alter function public.iss_norm(text)                       set search_path = public;
alter function public.iss_orders_soft_delete_guard()       set search_path = public;
alter function public.iss_touch_updated_at()               set search_path = public;
alter function public.iss_tx_clear_open()                  set search_path = public;
alter function public.iss_tx_rowid()                       set search_path = public;
alter function public.iss_tx_touch()                       set search_path = public;
alter function public.source_log_open()                    set search_path = public;
