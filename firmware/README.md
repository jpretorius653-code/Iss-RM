# ISS WeighBox firmware — remote updates

**Status: written but NOT compiled or tested on hardware** (no Arduino toolchain in the
authoring environment). Compile it, and trial it on ONE spare/bench box before any site.

## The one-time site visit
The firmware currently in the field has no update path, so nothing can be pushed to it.
Each box needs **one** final USB flash of `iss_weighbox.ino` (v1.1.0 or later). After that,
all changes are remote.

Before that visit:
1. `tools/publish_firmware.sh keygen` → paste `ota_public.pem` into `OTA_PUBKEY` in the sketch.
   Keep `ota_private.pem` offline + backed up. (While the key says `REPLACE_ME`, remote OTA stays off.)
2. Apply `migrations/03_remote_firmware.sql` (tables + public bucket).
3. Change the AP password on each box in `/config` (default `weighforward` keeps `/update` locked).
4. Arduino IDE: ESP32 core 3.x, board "ESP32 Dev Module", **Partition Scheme with two OTA slots**
   (e.g. "Default 4MB with spiffs"). Without two app slots OTA cannot work.

## Publishing an update
1. Bump `FW_VERSION` in the sketch. Sketch → Export Compiled Binary.
2. `SUPABASE_SERVICE_KEY=… tools/publish_firmware.sh publish iss_weighbox.ino.bin 1.2.0`
3. **Canary first:** add the device key (e.g. `Hillside-FM1-BeltScale`) as 3rd argument; only that box updates. Re-publish without it to roll out to all.
4. Boxes check every ~10 min, verify SHA-256 + RSA signature, flash and reboot.

## Safety
* Unsigned/tampered images are rejected. Downgrades are never applied — **roll back by publishing the old code with a HIGHER version**, or set `active=false` on a bad release to stop it spreading.
* A new image is only kept once it has run 90 s **and** posted to the cloud successfully; otherwise the bootloader reverts (needs rollback support in the core build — verify on the bench by flashing a deliberately broken image).
* `/update` (LAN upload) is a fallback and is only as strong as the AP password.

## Remote settings (`device_config` table, one row per device key)
`{"cloud_ms":5000,"baud232":9600,"baud485":9600,"ota":true,"reboot":1}`
Changing `reboot` to a new number restarts the box once. Site name, scale name and WiFi are
deliberately **not** remotely changeable.

## Other fixes in 1.1.0
* The belt totalizer is no longer posted as `0.0` before it has been read (it was read as a reset by the hourly ledger).
* The duplicate 30 s heartbeat post was removed (every post already carries `heartbeat:true`).

## Not covered here
Device health (RSSI, uptime, firmware version in the dashboard) needs a write path; today the
only write the boxes have is the anon insert into `readings`. It belongs with the secure-ingest work.
