# ISS Cloud Sync

Standalone uploader that reads the weighbridge **shared folder** and pushes
completed tickets to the ISS Remote Monitor (Supabase) so clients can pull
reports remotely.

**Read-only.** It never writes, renames, or deletes anything in the shared
folder. It is completely independent of the weighbridge software and of the
dashboard — they only meet at the Supabase `transactions` table.

## Build the installer via GitHub

1. Create a GitHub repo (e.g. `ISS-CloudSync`) and upload these files.
2. The included Action (`.github/workflows/build.yml`) builds the Windows
   installer automatically on every push to `main`.
3. Download the installer:
   - Any push → **Actions → latest run → Artifacts → ISS-CloudSync-Setup**.
   - Or push a tag `v1.0.0` → it's attached to a **GitHub Release**.
4. Run `ISS Cloud Sync Setup.exe` once on the PC that has the shared folder.

## First run

- Open the app (it also lives in the system tray).
- **Shared folder:** `C:\weighbridgeshare` (default).
- **Site name:** e.g. `Hillside` — must exactly match the site in the dashboard.
- It auto-syncs every 30 seconds and starts automatically on Windows login,
  hidden in the tray.

## One app per shared folder

Each site's shared folder gets its own copy of this app with its own site name
(Hillside → `Hillside`, Primecoal → `Primecoal`).

## Requirements in Supabase

Run `iss_transactions_extid.sql` once (adds the `ext_id` key for de-duplication)
and keep the `transactions` table's anon-insert policy in place.
