#!/usr/bin/env bash
# Publish a signed ESP32 firmware to Supabase so boxes in the field pick it up.
#   tools/publish_firmware.sh keygen                      # once: makes ota_private.pem / ota_public.pem
#   tools/publish_firmware.sh publish fw.bin 1.2.0 [device-key] ["release notes"]
# Needs: openssl, curl, and SUPABASE_SERVICE_KEY in the environment (NEVER commit it).
# Keep ota_private.pem OFFLINE and backed up: whoever holds it can run code on every box.
set -euo pipefail
URL="https://cslrbpptdcehxbljgvvm.supabase.co"
cmd="${1:-}"

if [ "$cmd" = keygen ]; then
  [ -e ota_private.pem ] && { echo "ota_private.pem already exists — refusing to overwrite"; exit 1; }
  openssl genrsa -out ota_private.pem 2048
  openssl rsa -in ota_private.pem -pubout -out ota_public.pem
  echo; echo "Paste this into OTA_PUBKEY in the sketch (one quoted line per row):"; cat ota_public.pem
  exit 0
fi

if [ "$cmd" = publish ]; then
  bin="${2:?firmware .bin}"; ver="${3:?version x.y.z}"; dev="${4:-}"; notes="${5:-}"
  : "${SUPABASE_SERVICE_KEY:?set SUPABASE_SERVICE_KEY}"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be x.y.z"; exit 1; }
  sha=$(openssl dgst -sha256 -hex "$bin" | awk '{print $NF}')
  sig=$(openssl dgst -sha256 -sign ota_private.pem "$bin" | base64 | tr -d '\n')
  size=$(wc -c < "$bin" | tr -d ' ')
  path="iss_weighbox-$ver.bin"
  curl -fsS -X POST "$URL/storage/v1/object/firmware/$path" \
       -H "Authorization: Bearer $SUPABASE_SERVICE_KEY" -H "apikey: $SUPABASE_SERVICE_KEY" \
       -H "Content-Type: application/octet-stream" -H "x-upsert: true" --data-binary @"$bin" >/dev/null
  devjson=null; [ -n "$dev" ] && devjson="\"$dev\""
  curl -fsS -X POST "$URL/rest/v1/firmware_releases" \
       -H "Authorization: Bearer $SUPABASE_SERVICE_KEY" -H "apikey: $SUPABASE_SERVICE_KEY" \
       -H "Content-Type: application/json" -H "Prefer: return=minimal" \
       -d "{\"version\":\"$ver\",\"url\":\"$URL/storage/v1/object/public/firmware/$path\",\"sha256\":\"$sha\",\"sig\":\"$sig\",\"size\":$size,\"device\":$devjson,\"notes\":\"$notes\"}"
  echo "Published $ver ($size bytes, sha256 $sha) ${dev:+to $dev only}"
  exit 0
fi
echo "usage: $0 keygen | publish <fw.bin> <x.y.z> [device-key] [notes]"; exit 1
