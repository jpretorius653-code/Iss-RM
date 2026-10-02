# Migrations — DRAFTS, NOT APPLIED

Written from the live-database audit. Nothing here has been run. Apply one at a
time, in order, and check the dashboard after each.

| File | Fixes | Risk |
|------|-------|------|
| 01_lock_down_functions.sql | Maintenance + admin functions callable by anyone with the public key | Low. pg_cron runs as `postgres` and is unaffected. |
| 02_hourly_ledger_chain.sql (applied, incl. 02b `gap_tons`) | Tonnage lost across outages; `snapshot_hourly` and `repair_hourly_chain` disagreeing; silent totalizer resets | Medium. Rewrites `tons` on existing rows when `repair_hourly_chain()` is run — back up `hourly` first. |
| 03_remote_firmware.sql | Remote firmware + config tables for the ESP32 boxes | Low (additive). DRAFT — apply after the signing key exists. |
| 04_alerts.sql | Server-side alerts every 5 min (silent scale/gateway, totalizer reset, stale open truck, silent site) | Low (additive). APPLIED. |

## Deliberately NOT drafted yet

* **Closing anon INSERT on `transactions`/`readings` (audit #5).** Hillside's
  Cloud Sync (`iss-cloud-sync`, `electron/uploader.js`) still posts with the
  public key. Dropping the policy today would stop Hillside uploading. It needs
  an ingest endpoint with a per-site secret and a Cloud Sync update first.
* **Gateway rows in `scales` (#2)** and **site-name normalisation (#13)** —
  need a decision on the canonical site codes (`hillside` vs `Hillside`, `vjs`
  vs `Jvs`).
* **`sites` config table (#5 structure)** — needs the shift times per site.

## Hillside Cloud Sync must keep working

Hillside's Cloud Sync posts with the public (anon) key: `POST transactions?on_conflict=ext_id`
(merge-duplicates). Nothing in this folder touches that path:

* No migration changes the anon INSERT policy or any table grant on `transactions`/`readings`.
* 01 revokes EXECUTE on maintenance/admin functions only. Trigger functions
  (`register_scale`, `iss_tx_*`) keep firing — Postgres does not check EXECUTE when a trigger fires.
* **Do not drop the anon policies** until a replacement ingest path is live *and* the
  Hillside PC has been updated and confirmed uploading.

Verify after applying 01: a Hillside ticket completed afterwards still appears in
`transactions` (latest `ext_id` like `hillside:%`).
