# Missing tickets at MMS — root cause and prevention

15 November 2026. Site: `mms` (Maloka Machaba Surfacing), two weighbridge PCs.

## Sources and limits

* Live Supabase data (`transactions`, `alerts`) — read only.
* Weighbridge app source: `premium` v10.0.0 and `promnatic-` v9.9.3 (the newest on GitHub).
* **The build running at MMS is newer than anything on GitHub.** At MMS a truck gets its ticket
  number at weigh-in; in every GitHub version the number is issued at weigh-out. The failure
  chain below is reconstructed from the data and matches the v10 code path for path, but the
  app-side fixes in section 5 must be made in the source that is actually deployed.
* The cloud kept no history before this change, so what a row looked like before it was
  overwritten is not recoverable from the cloud. It is only on the site PCs.

## 1. What the data shows

| Evidence in the cloud | Meaning |
|---|---|
| 19 MMS tickets carry a letter suffix (`WB171A`, `WB011A` …). 16 were inserted in one second at 11 Nov 12:48:59, 2 more at 13:05. | These are the tickets that had gone missing, put back by hand from a site PC. |
| `WB171/171A`, `172/172A`, `176/176A`, `177/177A`, `178/178A`, `182/182A`: same weigh-in time, two different weigh-outs a day apart (9 Nov ±10:00 and 10 Nov ±11:30). | One truck was weighed out twice — the second time from the other PC, whose "on site" list still showed it. |
| On 9 Nov 10:09–12:46 new trucks were given `WB011, 054, 065, 073, 076, 087, 094, 130, 166, 173`. Each is the number of an old **voided** weigh-in. | One PC's ticket counter had gone back to zero and it handed out every number it did not hold as a completed ticket. |
| `WB179`–`WB182` were issued on 9 Nov by one PC and again on 10–11 Nov by the other. | The two PCs' counters were out of step for more than a day. |
| Trucks on `WB145, 147, 157, 168` showed "on site" for 263–363 hours, though they weighed out the same day. All cleared at 10 Nov 12:15. | Finished tickets were not reaching the cloud as finished for two weeks. |
| `sync_silent` alerts: no uploads for 162 h (31 Oct–6 Nov) and 65 h (7–9 Nov). | The uploading PC was off or offline; the other PC cannot upload on its own. |
| `WB185, 188, 201, 216, 217, 226, 233` do not exist in the cloud (issued 10–14 Nov, **after** the repair). | Seven numbers are unaccounted for right now. Check Records on both MMS PCs. |

Hillside (two bridges, Cloud Sync) shows the same signature: 25 ticket numbers missing
(`979–984`, `1977–1979`, `2057–2059`, `2338–2340`, `2356–2358`, `3493–3497`, `3969`, `3971` …)
and 8 pairs of tickets with an identical truck and weigh-in time. `vjs` is missing 6 numbers.
`rietcoal` has 1 491 tickets and no gap at all, which is what a single counter looks like.
(Whether `vjs` runs one PC or two is not visible from the cloud; its gaps may be voided weigh-ins.)

## 2. How the tickets were lost

Two PCs share one site. Each keeps its own copy of everything and they exchange changes
through a shared folder, polled every 10 seconds. Four design decisions combine:

**A. The ticket number comes from a counter on each PC.** The counter is copied between PCs
through a file (`ticketcfg.json`) with no lock. Two PCs issue the same number when they weigh
inside the same 10-second window, when the folder is unreachable, or when one counter is
behind (new PC, reinstall, cleared storage). The duplicate check (`txId()`) only looks at
completed tickets held on that PC, so a PC whose counter restarts walks up from 1 and takes
every number that belongs to a voided or still-open ticket.

**B. Records are stored under the ticket number.** In the shared folder a ticket is the file
`txs/<ticket>.json`. Two tickets with one number are one file; the last PC to write wins.

**C. The "on site" list is not reliably cleared on the other PC.** A weigh-out removes the
truck by writing a tombstone file. That write is fire-and-forget (`catch(e){}`), never
retried. If the folder is down at that moment the other PC keeps the truck on site
indefinitely, and an operator can weigh it out a second time.

**D. The cloud upload treats a rejection as success.** Only the PC marked "host" uploads.
The upload is an upsert on `row_id`:

1. A ticket whose number is already in the cloud under another row is rejected by the
   `(site, ticket)` unique index. The app's handler logs *"already on cloud (skipped)"*,
   marks the ticket as sent, and never tries again. **This is the silent loss.**
2. A second weigh-out of the same truck carries the same `row_id` as the first, so it
   **replaces** the first ticket in the cloud.
3. A stale "on site" copy is re-sent every pass and can turn a finished ticket back to
   `open`, which removes it from every report.

Nothing compared tickets issued with tickets in the cloud, so none of this raised an alarm.
The existing `sync_silent` alert fired but is only visible inside the dashboard.

## 3. What has been built (this repository)

`migrations/06_ticket_integrity.sql` — tested against a local copy of the live schema with
the MMS and Hillside cases replayed. **Not yet applied to the live database.**

| Loss path | After migration 06 |
|---|---|
| Same number, different truck → upload rejected → app drops it | The upload is accepted and **held** in `ticket_conflicts`. No error reaches the app. |
| Second weigh-out replaces a finished ticket | The finished ticket is left as it is; the second one is held. |
| Finished ticket turned back to "on site" | Ignored, and counted so the stale PC can be found. |
| Hillside: two trucks under one `ext_id` overwrite each other | Same — first stays, second is held. |
| Any row changed or deleted | Written to `transactions_history` (append-only). |
| Finished ticket hard-deleted | Refused. Void instead. |
| Nobody notices | `ticket_conflict` (critical), `ticket_gap` and `stale_onsite` alerts every 5 minutes. |

A correction made at the bridge (weights, reg, customer) still goes through — it keeps the
original completion time. Void and un-void go through. An ISS engineer in the SQL editor is
not guarded.

Dashboard → Admin → **Ticket integrity** lists held uploads with *Keep both* (the held ticket
becomes `<number>A`), *Replace*, or *Discard*; missing numbers per site; PCs with a stale
on-site list; and a per-ticket trail of every change.

What this does **not** do: it cannot see a ticket that never left the PC. A ticket overwritten
inside the shared folder before the host uploaded it is gone before the cloud is involved. That
needs the app changes below. The gap alert will show the number as missing, which is the
prompt to go and look.

## 4. Rules for the two-bridge site (and every site after it)

With the app as it is today:

1. **One PC, two indicators, if the bridges are close enough to cable.** The app already
   supports two bridges on one PC. One PC has one counter and one database, and none of the
   failures above can happen. This is the safest option available now.
2. If two PCs are unavoidable: the shared folder must be a wired LAN share on one of the two
   PCs (or a NAS on a UPS) — not Wi-Fi, not Syncthing/OneDrive. Both PCs on a UPS.
3. Each PC gets its own cloud login, so the history shows which PC sent what.
4. Never set up, reinstall or restore a second PC while the first is weighing. After any
   reinstall, set the next ticket number by hand to above the highest number issued, before
   the first truck.
5. Apply migration 06 before go-live and have someone watch the alert bar daily. A held upload
   or a gap is dealt with the same day, while the paper ticket is still findable.
6. Keep the printed ticket book until month-end figures are reconciled against the cloud.

## 5. App changes needed (in the deployed source — not in this repository)

In priority order. The first three remove the cause; the rest remove single points of failure.

1. **Per-PC ticket series.** Each PC issues from its own range — a station letter in the
   number (`WB1-000123`, `WB2-000123`). Two PCs can then never issue the same number, online
   or not. The prefix must stop being synchronised between PCs.
2. **Key every record by `rowId`, never by ticket number or registration** — shared-folder
   file names, tombstones, the on-site list, and the Cloud Sync `ext_id`.
3. **Stop treating `23505 / duplicate key` as "already uploaded".** Mark a ticket as sent only
   when the server confirms that row. With migration 06 in place the server no longer returns
   this error; the code path should go.
4. `txId()` must check completed, voided **and** on-site tickets, and must refuse to issue
   when its counter is lower than the highest number it can see.
5. Retry failed shared-folder writes, tombstones included, until they succeed; show a red
   banner while the folder is unreachable instead of carrying on silently.
6. Weigh-out must re-read the shared folder first and refuse a truck another PC has already
   completed.
7. Every PC uploads its own tickets. No "host".
8. Each PC reports its local ticket count and highest number to the cloud every few minutes,
   so the cloud can compare *issued* against *received* per PC.
9. Check the size of the local ticket store. Tickets are kept as one JSON value in browser
   storage with a ceiling of roughly 5 MB; a failed save there is swallowed. Hillside is near
   4 000 tickets. A high-volume site needs a real local database (SQLite).

## 6. Longer term — more sites

The shared folder is a hand-built replicated database, and every fault above is a replication
fault. The durable fix is one authority per site: either the cloud issues ticket numbers
(with a per-PC offline block for when the line is down), or one small site server holds the
database and the bridge PCs are clients. Either removes sections 2A–2C entirely. Alert
delivery by e-mail or WhatsApp should come with it — an alert nobody sees is not an alert.
