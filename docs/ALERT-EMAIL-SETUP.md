# Alert e-mails — one-time setup

The database and the `alert-notify` function are live. Nothing is sent until a mail
provider key is added. This takes about five minutes.

1. Create a free account at resend.com and create an **API key**.
2. Supabase dashboard → project *ISS scalelink* → **Edge Functions → Secrets** → add
   `RESEND_API_KEY` with that key. Do not paste the key into chat, e-mail or GitHub.
3. ISS dashboard → **Admin → Alert e-mails**: type an address, press
   **Send test e-mail to this address**, then **Add recipient**.

Until a sending domain is verified in Resend, it only delivers to the address the Resend
account was opened with. To mail clients, verify a domain there (it gives three DNS
records to add) and set the secret `ALERT_FROM`, e.g. `ISS Monitor <alerts@yourdomain.co.za>`.
Optional secret `DASHBOARD_URL` adds a link to the dashboard at the foot of each mail.

## What gets sent

| Recipient setting | Receives |
|---|---|
| critical only (default) | scale or gateway silent, held ticket uploads |
| critical + warnings | also missing ticket numbers, stale on-site list, trucks on site > 24 h, site not uploading, totaliser reset |

* An alert is mailed once, after it has been open 10 minutes. A held ticket upload is mailed at once.
* One message per person per 5-minute run, listing every new alert.
* A send that fails is retried each run for 24 hours; the reason is stored in `alerts.notify_error`.

WhatsApp is not included. It needs a WhatsApp Business account with Meta-approved message
templates; the same function can post to it once that exists.
