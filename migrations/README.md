# Migrations — DRAFTS, NOT APPLIED

Written from the live-database audit. Nothing here has been run. Apply one at a
time, in order, and check the dashboard after each.

| File | Fixes | Risk |
|------|-------|------|
| 01_lock_down_functions.sql | Maintenance + admin functions callable by anyone with the public key | Low. pg_cron runs as `postgres` and is unaffected. |
| 02_hourly_ledger_chain.sql | Tonnage lost across outages; `snapshot_hourly` and `repair_hourly_chain` disagreeing; silent totalizer resets | Medium. Rewrites `tons` on existing rows when `repair_hourly_chain()` is run — back up `hourly` first. |

## Deliberately NOT drafted yet

* **Closing anon INSERT on `transactions`/`readings` (audit #5).** Hillside's
  Cloud Sync (`iss-cloud-sync`, `electron/uploader.js`) still posts with the
  public key. Dropping the policy today would stop Hillside uploading. It needs
  an ingest endpoint with a per-site secret and a Cloud Sync update first.
* **Gateway rows in `scales` (#2)** and **site-name normalisation (#13)** —
  need a decision on the canonical site codes (`hillside` vs `Hillside`, `vjs`
  vs `Jvs`).
* **`sites` config table (#5 structure)** — needs the shift times per site.
