-- 03 — Remote firmware + remote config for the ESP32 WeighBoxes.   DRAFT, NOT APPLIED
-- Devices (anon key) may only READ these tables. Writes need an admin login or the
-- service key (tools/publish_firmware.sh uses the service key, kept on YOUR machine).
-- Safe for Hillside Cloud Sync: touches no existing table or policy.

create table if not exists public.firmware_releases (
  id          bigint generated always as identity primary key,
  channel     text        not null default 'stable',
  version     text        not null check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  url         text        not null,                 -- public Storage URL of the .bin
  sha256      text        not null check (sha256 ~ '^[0-9a-f]{64}$'),
  sig         text        not null,                 -- base64 RSA-2048 signature over the SHA-256
  size        integer     not null,
  device      text,                                 -- null = every box; else one device key (canary)
  active      boolean     not null default true,    -- untick to stop a bad release spreading
  notes       text,
  created_at  timestamptz not null default now()
);
create unique index if not exists firmware_releases_uq on public.firmware_releases (channel, version, coalesce(device,''));

create table if not exists public.device_config (
  device      text primary key,                     -- e.g. 'Hillside-FM1-BeltScale'
  config      jsonb       not null default '{}'::jsonb,   -- cloud_ms, baud232, baud485, ota, reboot
  updated_at  timestamptz not null default now()
);

alter table public.firmware_releases enable row level security;
alter table public.device_config     enable row level security;

create policy fw_read   on public.firmware_releases for select to anon, authenticated using (active);
create policy fw_admin  on public.firmware_releases for all    to authenticated using (public.iss_is_admin()) with check (public.iss_is_admin());
create policy dc_read   on public.device_config     for select to anon, authenticated using (true);
create policy dc_admin  on public.device_config     for all    to authenticated using (public.iss_is_admin()) with check (public.iss_is_admin());

-- Public-read bucket for the .bin files (upload requires the service key).
insert into storage.buckets (id, name, public) values ('firmware','firmware', true)
on conflict (id) do nothing;
