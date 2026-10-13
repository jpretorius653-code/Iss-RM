-- 05 — Site-defined ticket fields (Stockpile Nr, Stockpile Grade, …)
-- Additive and nullable: a weighbridge that does not send `extra` is unaffected,
-- including Hillside's Cloud Sync (POST ... on_conflict=ext_id).
-- Shape: {"Stockpile Nr": "SP4", "Stockpile Grade": "RB3"}  (label -> value)
alter table public.transactions add column if not exists extra jsonb;
comment on column public.transactions.extra is
  'Site-defined custom ticket fields as {label: value}; shown as extra report columns';
-- PostgREST caches the schema; reload so the new column is accepted immediately.
notify pgrst, 'reload schema';
