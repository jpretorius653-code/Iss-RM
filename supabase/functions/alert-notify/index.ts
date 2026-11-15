// ════════════════════════════════════════════════════════════════════════
// ISS · alert-notify
//
// E-mails new alerts to the people in public.alert_recipients.
// Called every 5 minutes by pg_cron (migration 08), and by the dashboard's
// "Send test e-mail" button.
//
// Secrets (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY   required to send anything (resend.com)
//   ALERT_FROM       optional, e.g. "ISS Monitor <alerts@yourdomain.co.za>"
//   DASHBOARD_URL    optional, linked at the foot of each mail
//
// The scheduled call carries no credentials and needs none: all it can do is
// send alerts that were due anyway, each exactly once. A test mail requires
// an ISS admin's session.
// ════════════════════════════════════════════════════════════════════════
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const URL_     = Deno.env.get("SUPABASE_URL")!;
const ANON     = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND   = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM     = Deno.env.get("ALERT_FROM") ?? "ISS Monitor <onboarding@resend.dev>";
const DASH     = Deno.env.get("DASHBOARD_URL") ?? "";

const SETTLE_MIN = 10;                       // an alert must stay open this long before it is mailed
const IMMEDIATE  = new Set(["ticket_conflict"]);
const MAX_AGE_H  = 24;                       // stop retrying a failed send after this

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

type Alert = { id: number; site: string | null; kind: string; severity: string; message: string; created_at: string };
type Recipient = { email: string; site: string | null; min_severity: string };

async function send(to: string, subject: string, html: string, text: string): Promise<string | null> {
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: "Bearer " + RESEND, "Content-Type": "application/json" },
      body: JSON.stringify({ from: FROM, to: [to], subject, html, text }),
    });
    if (r.ok) return null;
    return ("HTTP " + r.status + " " + (await r.text())).slice(0, 300);
  } catch (e) {
    return String((e as Error)?.message ?? e).slice(0, 300);
  }
}

function compose(alerts: Alert[]) {
  const crit = alerts.filter((a) => a.severity === "crit").length;
  const sites = [...new Set(alerts.map((a) => a.site).filter(Boolean))];
  const subject = (crit ? "CRITICAL — " : "") + `ISS Monitor: ${alerts.length} new alert${alerts.length > 1 ? "s" : ""}` +
    (sites.length === 1 ? ` (${sites[0]})` : "");
  const rows = alerts.map((a) =>
    `<tr><td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;white-space:nowrap;color:${a.severity === "crit" ? "#b91c1c" : "#92400e"};font-weight:700">${a.severity === "crit" ? "CRITICAL" : "Warning"}</td>` +
    `<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb">${esc(a.message)}</td>` +
    `<td style="padding:6px 10px;border-bottom:1px solid #e5e7eb;white-space:nowrap;color:#6b7280">${esc(a.site ?? "")}</td></tr>`).join("");
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#111827">
    <p><b>ISS Remote Monitor</b> raised ${alerts.length} new alert${alerts.length > 1 ? "s" : ""}.</p>
    <table style="border-collapse:collapse;width:100%">${rows}</table>
    <p style="color:#6b7280;font-size:12px;margin-top:16px">Each alert is mailed once. It clears by itself when the condition ends; acknowledge it in the dashboard to mark it as seen.${DASH ? ` <a href="${esc(DASH)}">Open the dashboard</a>.` : ""}</p></div>`;
  const text = alerts.map((a) => `[${a.severity === "crit" ? "CRITICAL" : "warning"}] ${a.message}${a.site ? " (" + a.site + ")" : ""}`).join("\n") +
    (DASH ? "\n\n" + DASH : "");
  return { subject, html, text };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body is fine */ }
  const db = createClient(URL_, SERVICE, { auth: { persistSession: false } });

  // ── test mail: ISS admin only ────────────────────────────────────────
  if (body.test) {
    const auth = req.headers.get("Authorization") ?? "";
    if (!auth.startsWith("Bearer ")) return json({ error: "not signed in" }, 401);
    const asCaller = createClient(URL_, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: me, error: meErr } = await asCaller.rpc("iss_my_access");
    if (meErr) return json({ error: "could not check access: " + meErr.message }, 500);
    if (!me?.[0]?.is_admin) return json({ error: "admin only" }, 403);
    const to = String(body.to ?? "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(to)) return json({ error: "a valid e-mail address is required" }, 400);
    if (!RESEND) return json({ error: "RESEND_API_KEY is not set — add it under Edge Functions → Secrets" }, 400);
    const m = compose([{ id: 0, site: "test", kind: "test", severity: "warn", message: "Test message — alert e-mails are working.", created_at: new Date().toISOString() }]);
    const err = await send(to, "ISS Monitor: test e-mail", m.html, m.text);
    return err ? json({ error: err }, 502) : json({ ok: true, to });
  }

  // ── scheduled run ────────────────────────────────────────────────────
  if (!RESEND) return json({ configured: false, sent: 0 });

  const { data: pending, error: pErr } = await db.from("alerts")
    .select("id,site,kind,severity,message,created_at")
    .is("notified_at", null).is("resolved_at", null)
    .gte("created_at", new Date(Date.now() - MAX_AGE_H * 3600_000).toISOString())
    .order("created_at", { ascending: true }).limit(200);
  if (pErr) return json({ error: pErr.message }, 500);

  const cutoff = Date.now() - SETTLE_MIN * 60_000;
  const due = (pending as Alert[]).filter((a) => IMMEDIATE.has(a.kind) || new Date(a.created_at).getTime() <= cutoff);
  if (!due.length) return json({ configured: true, sent: 0, due: 0 });

  const { data: recips, error: rErr } = await db.from("alert_recipients").select("email,site,min_severity").eq("active", true);
  if (rErr) return json({ error: rErr.message }, 500);

  const wants = (r: Recipient, a: Alert) =>
    (!r.site || r.site === String(a.site ?? "").toLowerCase()) && (r.min_severity === "warn" || a.severity === "crit");

  // one mail per address, however many rows that address has
  const byEmail = new Map<string, Map<number, Alert>>();
  for (const r of recips as Recipient[]) {
    for (const a of due) {
      if (!wants(r, a)) continue;
      if (!byEmail.has(r.email)) byEmail.set(r.email, new Map());
      byEmail.get(r.email)!.set(a.id, a);
    }
  }

  const failed = new Map<number, string>();
  let sent = 0;
  for (const [email, set] of byEmail) {
    const list = [...set.values()];
    const m = compose(list);
    const err = await send(email, m.subject, m.html, m.text);
    if (err) list.forEach((a) => failed.set(a.id, email + ": " + err)); else sent++;
  }

  const okIds = due.filter((a) => !failed.has(a.id)).map((a) => a.id);
  const covered = new Set<number>(); byEmail.forEach((s) => s.forEach((_, id) => covered.add(id)));
  const now = new Date().toISOString();
  const withRecipient = okIds.filter((id) => covered.has(id));
  const noRecipient = okIds.filter((id) => !covered.has(id));
  if (withRecipient.length) await db.from("alerts").update({ notified_at: now, notify_error: null }).in("id", withRecipient);
  if (noRecipient.length) await db.from("alerts").update({ notified_at: now, notify_error: "no recipient" }).in("id", noRecipient);
  for (const [id, err] of failed) await db.from("alerts").update({ notify_error: err }).eq("id", id);

  return json({ configured: true, due: due.length, sent, failed: failed.size, no_recipient: noRecipient.length });
});
