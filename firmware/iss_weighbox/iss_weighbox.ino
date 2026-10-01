/* =====================================================================
   ISS WeighBox  —  SINGLE FILE  (ESP32 Arduino core 3.x)
   Industrial Scale Solutions  ·  "Weigh Forward"
   ONE FILE ONLY in the sketch folder.

   RS232 GPIO26/27  →  weighbridge  (WeighBox WS + Supabase)
   RS485 GPIO16/17  →  BST100 belt scale (Modbus ASCII → Supabase)
   WS    port 81    →  ISS app WeighBox protocol
   HTTP  port 80    →  /info  /sniff  /config  /update

   v1.1.0 — adds REMOTE UPDATES (no site visit needed after this one is flashed):
     * Pull-OTA: every OTA_CHECK_MS the box asks Supabase for a newer signed
       firmware, downloads it, checks SHA-256 + RSA signature, flashes, reboots.
       A bad image that never reaches the cloud is rolled back by the bootloader.
     * Remote config: cloud_ms, baud rates, reboot, ota on/off from device_config.
     * LAN upload page /update (only if the AP password is no longer the default).
     * Fix: belt totalizer is no longer posted as 0.0 before it has been read.
   See firmware/README.md for keys, publishing and rollback.
   ===================================================================== */

#include <Arduino.h>
#include <WiFi.h>
#include <NetworkClient.h>
#include <NetworkServer.h>
#include <WiFiClientSecure.h>
#include <WebServer.h>
#include <Preferences.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <Update.h>
#include <esp_ota_ops.h>
#include <mbedtls/sha1.h>
#include <mbedtls/sha256.h>
#include <mbedtls/pk.h>
#include <mbedtls/base64.h>
#include <base64.h>

// ── Firmware identity / update settings ───────────────────────────────
#define FW_VERSION    "1.1.0"          // bump on every release (x.y.z)
#define FW_CHANNEL    "stable"
#define OTA_CHECK_MS  600000UL         // look for new firmware every 10 min
#define CFG_CHECK_MS  60000UL          // look for remote config every 60 s
#define OTA_CONFIRM_MS 90000UL         // healthy for this long + cloud OK → keep image

// RSA-2048 PUBLIC key. Generate the pair with tools/publish_firmware.sh keygen,
// paste the public half here. While it still says REPLACE_ME, remote OTA is OFF.
static const char OTA_PUBKEY[] =
"-----BEGIN PUBLIC KEY-----\n"
"REPLACE_ME\n"
"-----END PUBLIC KEY-----\n";

// ── Supabase ──────────────────────────────────────────────────────────
#define SUPABASE_URL  "https://cslrbpptdcehxbljgvvm.supabase.co"
#define SUPABASE_KEY  "sb_publishable_b-DZiQOIQ3N4u3v7yYN0Ow_eKwj4nyp"
#define CLOUD_MS_DEF  5000

// ── Default identity (set per board via Config page) ──────────────────
#define DEF_SITE      "Hillside"
#define DEF_WB_NAME   "Weighbridge-1"
#define DEF_BS_NAME   "FM1-BeltScale"
#define DEF_MDNS      "iss-ftp"
#define DEF_AP_SSID   "ISS-Gateway"
#define DEF_AP_PASS   "weighforward"

// ── Pins ──────────────────────────────────────────────────────────────
#define RS232_RX  27
#define RS232_TX  26
#define RS485_RX  16
#define RS485_TX  17
#define RS485_DE   4    // -1 for auto-direction board
#define LED_PIN    2

// ══════════════════════════════════════════════════════════════════════
//  Structs — declared before everything else
// ══════════════════════════════════════════════════════════════════════
#define SNIFF_SZ 4096
struct RingBuf {
  uint8_t  b[SNIFF_SZ];
  uint32_t n;
  RingBuf() : n(0) { memset(b, 0, SNIFF_SZ); }
};

struct GwCfg {
  String wifiSsid, wifiPass;
  String apSsid,   apPass;
  String mdns;
  String site, wbName, bsName;
  uint32_t baud232, baud485;
};

// Non-blocking WebSocket frame receiver state
struct WsRx {
  uint8_t  stage  = 0;
  uint8_t  h0 = 0, h1 = 0;
  uint8_t  ext[8];
  uint8_t  extIdx = 0;
  uint32_t need   = 0;
  uint32_t payload = 0;
};

// Forward declarations
struct RingBuf;
void   rbPush(RingBuf& r, const uint8_t* d, size_t n);
String rbDelta(RingBuf& r, uint32_t since, uint32_t& nt);

// ══════════════════════════════════════════════════════════════════════
//  Globals
// ══════════════════════════════════════════════════════════════════════
HardwareSerial p232(1);
HardwareSerial p485(2);
WebServer      webSrv(80);
NetworkServer  tcpWs(81);
Preferences    prefs;

RingBuf rb232, rb485;

#define WS_MAX 3
NetworkClient wsConn[WS_MAX];
WsRx          wsRx[WS_MAX];

GwCfg gwc;

// Weighbridge parse state
char     wbBuf[256];
int      wbLen  = 0;
long     wbW    = 0;
bool     wbSt   = false, wbV = false;
uint32_t wbRx   = 0;

// Belt scale parse state
#define BS_SZ 64
char     bsBuf[BS_SZ];
int      bsI    = 0;
float    bsR    = 0, bsSp = 0, bsTot = 0;
bool     bsV    = false, bsTotV = false;
uint32_t bsRx   = 0;

uint32_t tCl = 0, tLed = 0, tWs = 0, tWsChk = 0;
uint32_t tOta = 0, tCfg = 0;

// Remote-controlled settings (persisted in NVS, changed via device_config)
uint32_t cloudMs   = CLOUD_MS_DEF;
bool     otaEnabled = true;
bool     fwConfirmed = false;      // true once the running image is marked valid
int      lastPostCode = 0;         // HTTP status of the last readings POST
String   otaStatus = "idle";       // shown on the status page

// The core's default says "validate immediately". We want to validate ONLY after
// the new image has proven it can reach the cloud, so a bad image rolls back.
extern "C" bool verifyRollbackLater() { return true; }

// ══════════════════════════════════════════════════════════════════════
//  Ring buffer
// ══════════════════════════════════════════════════════════════════════
void rbPush(RingBuf& r, const uint8_t* d, size_t n) {
  for (size_t i = 0; i < n; i++) { r.b[r.n % SNIFF_SZ] = d[i]; r.n++; }
}

String rbDelta(RingBuf& r, uint32_t since, uint32_t& nt) {
  uint32_t tot = r.n; nt = tot;
  uint32_t s = since;
  if (s > tot) s = tot;
  if (tot - s > 1500) s = tot - 1500;
  String h; h.reserve((tot - s) * 3);
  for (uint32_t i = s; i < tot; i++) {
    char t[4]; sprintf(t, "%02X ", r.b[i % SNIFF_SZ]); h += t;
  }
  return h;
}

// ══════════════════════════════════════════════════════════════════════
//  WebSocket — mbedtls SHA1 + non-blocking WsRx state machine
// ══════════════════════════════════════════════════════════════════════
String wsAcceptHash(const String& key) {
  String s = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  uint8_t out[20];
  mbedtls_sha1((const unsigned char*)s.c_str(), s.length(), out);
  return base64::encode(out, 20);
}

String wsHdrLine(NetworkClient& c) {
  String ln; uint32_t t0 = millis();
  while (c.connected() && millis()-t0 < 2000) {
    if (!c.available()) { delay(1); continue; }
    int ch = c.read();
    if (ch < 0) continue;
    if (ch == '\n') break;
    if (ch != '\r') ln += (char)ch;
  }
  return ln;
}

void wsRaw(NetworkClient& c, const char* s) {
  c.write((const uint8_t*)s, strlen(s));
}

void wsCheckNew() {
  NetworkClient c = tcpWs.accept();
  if (!c) return;
  String key;
  for (int i = 0; i < 40; i++) {
    String ln = wsHdrLine(c);
    if (ln.startsWith("Sec-WebSocket-Key:")) { key=ln.substring(18); key.trim(); }
    if (ln.length() == 0) break;
  }
  if (!key.length()) { c.stop(); return; }
  String acc = wsAcceptHash(key);
  wsRaw(c, "HTTP/1.1 101 Switching Protocols\r\n");
  wsRaw(c, "Upgrade: websocket\r\n");
  wsRaw(c, "Connection: Upgrade\r\n");
  wsRaw(c, "Sec-WebSocket-Accept: ");
  wsRaw(c, acc.c_str());
  wsRaw(c, "\r\n\r\n");
  for (int i = 0; i < WS_MAX; i++) {
    if (!wsConn[i].connected()) { wsConn[i]=c; wsRx[i]=WsRx(); return; }
  }
  c.stop();
}

void wsBroadcast(const String& s) {
  size_t n = s.length();
  for (int i = 0; i < WS_MAX; i++) {
    if (!wsConn[i].connected()) continue;
    uint8_t hdr[4]; int hl;
    hdr[0] = 0x81;
    if (n < 126) { hdr[1]=(uint8_t)n; hl=2; }
    else { hdr[1]=126; hdr[2]=(uint8_t)(n>>8); hdr[3]=(uint8_t)(n&0xFF); hl=4; }
    wsConn[i].write(hdr, hl);
    wsConn[i].write((const uint8_t*)s.c_str(), n);
  }
}

void wsHandleFrame(int i) {
  uint8_t op = wsRx[i].h0 & 0x0F;
  if (op==0x08) { wsConn[i].stop(); }
  else if (op==0x09) { uint8_t p[2]={0x8A,0x00}; wsConn[i].write(p,2); }
}

void wsService() {
  for (int i = 0; i < WS_MAX; i++) {
    NetworkClient& c = wsConn[i];
    if (!c.connected()) { wsRx[i]=WsRx(); continue; }
    while (c.available()) {
      WsRx& r = wsRx[i];
      if (r.stage==0) {
        int v=c.read(); if(v<0) break; r.h0=(uint8_t)v; r.stage=1;
      } else if (r.stage==1) {
        int v=c.read(); if(v<0) break; r.h1=(uint8_t)v;
        uint8_t len=r.h1&0x7F;
        if (len<126) {
          r.payload=len; r.extIdx=0;
          r.stage=(r.h1&0x80)?3:4;
          r.need=(r.h1&0x80)?4:r.payload;
          if (r.need==0&&r.payload==0){wsHandleFrame(i);r=WsRx();}
        } else if (len==126) { r.stage=2; r.need=2; r.extIdx=0; }
        else { r.stage=2; r.need=8; r.extIdx=0; }
      } else if (r.stage==2) {
        while (c.available()&&r.extIdx<r.need){int v=c.read();if(v<0)break;r.ext[r.extIdx++]=(uint8_t)v;}
        if (r.extIdx<r.need) break;
        r.payload=((r.h1&0x7F)==126)?((uint32_t)r.ext[0]<<8)|r.ext[1]:0;
        r.stage=(r.h1&0x80)?3:4; r.need=(r.h1&0x80)?4:r.payload; r.extIdx=0;
        if (r.need==0&&r.payload==0){wsHandleFrame(i);r=WsRx();}
      } else if (r.stage==3) {
        while (c.available()&&r.extIdx<4){int v=c.read();if(v<0)break;r.extIdx++;}
        if (r.extIdx<4) break;
        r.stage=4; r.need=r.payload;
        if (r.need==0){wsHandleFrame(i);r=WsRx();}
      } else {
        uint32_t skip=min((uint32_t)c.available(),r.need);
        for (uint32_t k=0;k<skip;k++) c.read();
        r.need-=skip;
        if (r.need==0){wsHandleFrame(i);r=WsRx();}
        break;
      }
    }
  }
}

// ══════════════════════════════════════════════════════════════════════
//  Weighbridge RS232 parse
// ══════════════════════════════════════════════════════════════════════
bool wbOk() { return millis()-wbRx < 4000; }

void parseWB() {
  int kg=-1;
  for (int i=wbLen-2;i>=0;i--)
    if (wbBuf[i]=='k'&&wbBuf[i+1]=='g'){kg=i;break;}
  if (kg<0) return;
  int e=kg-1,s=e;
  while (s>=0&&((wbBuf[s]>='0'&&wbBuf[s]<='9')||wbBuf[s]=='-'||wbBuf[s]=='.')) s--;
  if (s==e) return;
  char num[16]; int nc=0;
  for (int i=s+1;i<=e&&nc<15;i++) num[nc++]=wbBuf[i];
  num[nc]=0; wbW=atol(num);
  bool st=false;
  for (int i=s;i>=0;i--){if(wbBuf[i]==0)break;if(wbBuf[i]=='S'||wbBuf[i]=='s'){st=true;break;}}
  wbSt=st; wbV=true;
}

void wbFeed(uint8_t byt) {
  wbRx=millis();
  if (byt==0x0A){parseWB();wbLen=0;}
  else if (wbLen<255) wbBuf[wbLen++]=byt;
}

// Telemetry JSON for the ISS Weighbridge app WeighBox protocol
String telemetryJson() {
  String j = "{\"box_name\":\"";
  j += gwc.bsName;
  j += "\",\"online\":true";
  j += ",\"weight\":"; j += wbW;
  j += ",\"kg\":";       j += wbW;
  j += ",\"stable\":";   j += (wbSt?"true":"false");
  j += ",\"scale_ok\":"; j += (wbOk()?"true":"false");
  j += "}";
  return j;
}

// ══════════════════════════════════════════════════════════════════════
//  Belt scale Modbus ASCII parse
// ══════════════════════════════════════════════════════════════════════
bool bsOk() { return millis()-bsRx < 6000; }

int hexNib(char c) {
  if (c>='0'&&c<='9') return c-'0';
  if (c>='A'&&c<='F') return c-'A'+10;
  if (c>='a'&&c<='f') return c-'a'+10;
  return -1;
}

float bsF32(const uint8_t* b) {
  uint32_t u=((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3];
  float f; memcpy(&f,&u,4); return f;
}

void bsParse() {
  if ((int)strlen(bsBuf)<30) return;
  uint8_t d[12]; bool ok=true;
  for (int i=0;i<12;i++){
    int h=hexNib(bsBuf[6+i*2]),l=hexNib(bsBuf[6+i*2+1]);
    if(h<0||l<0){ok=false;break;}
    d[i]=(uint8_t)((h<<4)|l);
  }
  if (!ok) return;
  if (!(d[0]==0xFF&&d[1]==0xFF)){
    uint32_t rv=((uint32_t)d[0]<<24)|((uint32_t)d[1]<<16)|((uint32_t)d[2]<<8)|d[3];
    if (rv!=0xFFFFFFFF&&rv!=0){bsTot=rv*0.1f;bsTotV=true;}
  }
  float sp=bsF32(d+4); if(!isnan(sp)&&!isinf(sp)&&sp>-100&&sp<100) bsSp=sp;
  float rt=bsF32(d+8); if(!isnan(rt)&&!isinf(rt)&&rt>-9999&&rt<9999) bsR=rt;
  bsV=true;
}

void bsFeed(uint8_t byt) {
  bsRx=millis();
  if (byt==':'){bsI=0;memset(bsBuf,0,BS_SZ);return;}
  if (byt=='\r'||byt=='\n'){if(bsI>0)bsParse();bsI=0;return;}
  if (bsI<BS_SZ-1) bsBuf[bsI++]=(char)byt;
}

// ══════════════════════════════════════════════════════════════════════
//  Supabase HTTPS helpers
// ══════════════════════════════════════════════════════════════════════
String urlEnc(const String& s) {
  String o; char t[4];
  for (size_t i = 0; i < s.length(); i++) {
    char c = s[i];
    if (isalnum((unsigned char)c) || c=='-' || c=='_' || c=='.' || c=='~') o += c;
    else { sprintf(t, "%%%02X", (unsigned char)c); o += t; }
  }
  return o;
}

String deviceKey() { return gwc.site + "-" + gwc.bsName; }

int sbPost(const String& body) {
  if (WiFi.status()!=WL_CONNECTED) return -1;
  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/readings";
  http.begin(url);
  http.addHeader("Content-Type",  "application/json");
  http.addHeader("apikey",        SUPABASE_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  http.addHeader("Prefer",        "return=minimal");
  int code = http.POST(body);
  http.end();
  return code;
}

// GET a PostgREST path (relative to /rest/v1/) into `out`. Returns HTTP status.
int sbGet(const String& path, String& out) {
  if (WiFi.status()!=WL_CONNECTED) return -1;
  WiFiClientSecure cli; cli.setInsecure();   // integrity comes from the signed image, not TLS pinning
  HTTPClient http;
  http.begin(cli, String(SUPABASE_URL) + "/rest/v1/" + path);
  http.addHeader("apikey",        SUPABASE_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_KEY);
  int code = http.GET();
  if (code == 200) out = http.getString();
  http.end();
  return code;
}

// Post telemetry. Fields not yet known are OMITTED (never posted as 0) — a 0.0
// totalizer would be read by the hourly ledger as a reset and corrupt tonnage.
void cloudPost() {
  String b = "{\"device\":\"" + deviceKey() + "\",";
  b += "\"site\":\"" + gwc.site + "\",";
  b += "\"scale_name\":\"" + gwc.bsName + "\",";
  b += "\"online\":true,";
  b += "\"heartbeat\":true,";
  b += "\"weight\":" + String(wbW) + ",";
  b += "\"stable\":" + String(wbSt?"true":"false") + ",";
  b += "\"rate\":" + String(bsR,3) + ",";
  b += "\"speed\":" + String(bsSp,3);
  if (bsTotV) b += ",\"total\":" + String(bsTot,1);
  b += "}";
  lastPostCode = sbPost(b);
}

// ══════════════════════════════════════════════════════════════════════
//  Tiny JSON field readers (responses are flat PostgREST rows)
// ══════════════════════════════════════════════════════════════════════
String jStr(const String& j, const char* key) {
  String k = String("\"") + key + "\":";
  int p = j.indexOf(k); if (p < 0) return "";
  p += k.length();
  while (p < (int)j.length() && j[p]==' ') p++;
  if (j.startsWith("null", p)) return "";
  if (j[p] == '"') { int e = j.indexOf('"', p+1); return e<0 ? "" : j.substring(p+1, e); }
  int e = p; while (e < (int)j.length() && j[e]!=',' && j[e]!='}' && j[e]!=']') e++;
  String v = j.substring(p, e); v.trim(); return v;
}

// "1.2.3" compare → <0, 0, >0
int verCmp(const String& a, const String& b) {
  int x[3]={0,0,0}, y[3]={0,0,0};
  sscanf(a.c_str(), "%d.%d.%d", &x[0],&x[1],&x[2]);
  sscanf(b.c_str(), "%d.%d.%d", &y[0],&y[1],&y[2]);
  for (int i=0;i<3;i++) if (x[i]!=y[i]) return x[i]<y[i] ? -1 : 1;
  return 0;
}

// ══════════════════════════════════════════════════════════════════════
//  Pull-OTA: signed firmware from Supabase
// ══════════════════════════════════════════════════════════════════════
bool otaKeyConfigured() { return !strstr(OTA_PUBKEY, "REPLACE_ME"); }

// Signature = RSA-2048 PKCS#1 v1.5 over the SHA-256 of the .bin
// (what `openssl dgst -sha256 -sign key.pem fw.bin` produces).
bool verifySig(const uint8_t hash[32], const String& sigB64) {
  uint8_t sig[512]; size_t sl = 0;
  if (mbedtls_base64_decode(sig, sizeof(sig), &sl,
        (const unsigned char*)sigB64.c_str(), sigB64.length()) != 0) return false;
  mbedtls_pk_context pk; mbedtls_pk_init(&pk);
  int rc = mbedtls_pk_parse_public_key(&pk, (const unsigned char*)OTA_PUBKEY, strlen(OTA_PUBKEY)+1);
  if (rc == 0) rc = mbedtls_pk_verify(&pk, MBEDTLS_MD_SHA256, hash, 32, sig, sl);
  mbedtls_pk_free(&pk);
  return rc == 0;
}

String hex32(const uint8_t* h) {
  String s; char t[3];
  for (int i=0;i<32;i++){ sprintf(t,"%02x",h[i]); s+=t; }
  return s;
}

bool otaApply(const String& url, size_t size, String shaHex, const String& sigB64) {
  otaStatus = "downloading";
  WiFiClientSecure cli; cli.setInsecure();
  HTTPClient http;
  http.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
  http.begin(cli, url);
  int code = http.GET();
  if (code != 200) { otaStatus = "download failed " + String(code); http.end(); return false; }
  int len = http.getSize();
  if (len <= 0 || (size && (size_t)len != size)) { otaStatus = "size mismatch"; http.end(); return false; }
  if (!Update.begin(len)) { otaStatus = "no space"; http.end(); return false; }

  mbedtls_sha256_context ctx; mbedtls_sha256_init(&ctx); mbedtls_sha256_starts(&ctx, 0);
  WiFiClient* s = http.getStreamPtr();
  uint8_t buf[1024]; int got = 0; uint32_t last = millis();
  while (got < len) {
    size_t a = s->available();
    if (a) {
      int r = s->readBytes(buf, min(a, sizeof(buf)));
      if (r <= 0) continue;
      if (Update.write(buf, r) != (size_t)r) { otaStatus = "flash write failed"; Update.abort(); http.end(); return false; }
      mbedtls_sha256_update(&ctx, buf, r);
      got += r; last = millis();
    } else {
      if (!s->connected() || millis()-last > 20000) break;
      delay(2);
    }
  }
  http.end();
  uint8_t hash[32]; mbedtls_sha256_finish(&ctx, hash); mbedtls_sha256_free(&ctx);
  if (got != len) { otaStatus = "incomplete download"; Update.abort(); return false; }
  shaHex.toLowerCase();
  if (hex32(hash) != shaHex)   { otaStatus = "sha256 mismatch";   Update.abort(); return false; }
  if (!verifySig(hash, sigB64)) { otaStatus = "BAD SIGNATURE";     Update.abort(); return false; }
  if (!Update.end(true))        { otaStatus = "finalise failed";   return false; }
  otaStatus = "installed — rebooting";
  delay(300); ESP.restart();
  return true;
}

void otaCheck() {
  if (!otaEnabled || !otaKeyConfigured() || WiFi.status()!=WL_CONNECTED) return;
  String q = String("firmware_releases?select=version,url,sha256,sig,size&active=eq.true&channel=eq.") + FW_CHANNEL
           + "&or=(device.is.null,device.eq." + urlEnc(deviceKey()) + ")&order=created_at.desc&limit=1";
  String body;
  int code = sbGet(q, body);
  if (code != 200) { otaStatus = "check failed " + String(code); return; }
  String ver = jStr(body, "version");
  if (!ver.length()) { otaStatus = "up to date (" FW_VERSION ")"; return; }
  if (verCmp(ver, FW_VERSION) <= 0) { otaStatus = "up to date (" FW_VERSION ")"; return; }  // never downgrade; roll back by publishing a HIGHER version
  String url = jStr(body, "url"), sha = jStr(body, "sha256"), sig = jStr(body, "sig");
  size_t size = (size_t)jStr(body, "size").toInt();
  if (!url.length() || sha.length()!=64 || !sig.length()) { otaStatus = "bad release row"; return; }
  otaApply(url, size, sha, sig);
}

// ══════════════════════════════════════════════════════════════════════
//  Config NVS
// ══════════════════════════════════════════════════════════════════════
void loadCfg() {
  prefs.begin("iss", true);
  gwc.wifiSsid = prefs.getString("wss", "");
  gwc.wifiPass = prefs.getString("wsp", "");
  gwc.apSsid   = prefs.getString("aps", DEF_AP_SSID);
  gwc.apPass   = prefs.getString("app", DEF_AP_PASS);
  gwc.mdns     = prefs.getString("mdn", DEF_MDNS);
  gwc.site     = prefs.getString("sit", DEF_SITE);
  gwc.wbName   = prefs.getString("wbn", DEF_WB_NAME);
  gwc.bsName   = prefs.getString("bsn", DEF_BS_NAME);
  gwc.baud232  = prefs.getUInt  ("b2",  9600);
  gwc.baud485  = prefs.getUInt  ("b4",  9600);
  cloudMs      = prefs.getUInt  ("cms", CLOUD_MS_DEF);
  otaEnabled   = prefs.getBool  ("ota", true);
  prefs.end();
}

void saveCfg() {
  prefs.begin("iss", false);
  prefs.putString("wss", gwc.wifiSsid);
  prefs.putString("wsp", gwc.wifiPass);
  prefs.putString("aps", gwc.apSsid);
  prefs.putString("app", gwc.apPass);
  prefs.putString("mdn", gwc.mdns);
  prefs.putString("sit", gwc.site);
  prefs.putString("wbn", gwc.wbName);
  prefs.putString("bsn", gwc.bsName);
  prefs.putUInt  ("b2",  gwc.baud232);
  prefs.putUInt  ("b4",  gwc.baud485);
  prefs.end();
}

// ══════════════════════════════════════════════════════════════════════
//  Remote config from Supabase device_config (one row per device key)
//  Keys: cloud_ms (2000-60000), baud232, baud485, ota (true/false), reboot (counter)
//  Identity (site / names) and WiFi are deliberately NOT remotely changeable.
// ══════════════════════════════════════════════════════════════════════
void cfgCheck() {
  if (WiFi.status()!=WL_CONNECTED) return;
  String body;
  if (sbGet("device_config?select=config&device=eq." + urlEnc(deviceKey()) + "&limit=1", body) != 200) return;
  if (body.length() < 5) return;     // no row → defaults

  bool restart = false;
  prefs.begin("iss", false);

  long cm = jStr(body, "cloud_ms").toInt();
  if (cm >= 2000 && cm <= 60000 && (uint32_t)cm != cloudMs) { cloudMs = cm; prefs.putUInt("cms", cloudMs); }

  String o = jStr(body, "ota");
  if (o.length()) { bool v = (o == "true"); if (v != otaEnabled) { otaEnabled = v; prefs.putBool("ota", v); } }

  long b2 = jStr(body, "baud232").toInt(), b4 = jStr(body, "baud485").toInt();
  if (b2 >= 1200 && b2 <= 115200 && (uint32_t)b2 != gwc.baud232) { gwc.baud232 = b2; prefs.putUInt("b2", b2); restart = true; }
  if (b4 >= 1200 && b4 <= 115200 && (uint32_t)b4 != gwc.baud485) { gwc.baud485 = b4; prefs.putUInt("b4", b4); restart = true; }

  String rb = jStr(body, "reboot");
  if (rb.length() && (uint32_t)rb.toInt() != prefs.getUInt("rbn", 0)) { prefs.putUInt("rbn", (uint32_t)rb.toInt()); restart = true; }

  prefs.end();
  if (restart) { delay(300); ESP.restart(); }
}

// ══════════════════════════════════════════════════════════════════════
//  Web pages
// ══════════════════════════════════════════════════════════════════════
const char PH[] PROGMEM =
  "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
  "<style>"
  "body{font-family:system-ui;margin:0;background:#0f1720;color:#e7edf3}"
  "header{background:#1A3A6B;color:#fff;padding:12px 16px;font-weight:600}"
  ".b{color:#29ABE2}a{color:#2183C2}"
  "main{padding:16px;max-width:900px;margin:auto}"
  "nav a{margin-right:14px}"
  "pre{background:#0b1219;border:1px solid #223;border-radius:8px;padding:8px;"
      "height:36vh;overflow:auto;white-space:pre-wrap;font:12px/1.4 monospace}"
  "label{display:block;margin:8px 0 2px;font-size:13px;color:#9fb2c4}"
  "input{width:100%;padding:8px;border-radius:6px;border:1px solid #334;"
        "background:#0b1219;color:#e7edf3;box-sizing:border-box}"
  "button{background:#2183C2;color:#fff;border:0;padding:10px 16px;"
         "border-radius:6px;margin-top:12px;cursor:pointer}"
  ".card{background:#141d28;border:1px solid #223;border-radius:10px;padding:12px;margin:10px 0}"
  ".tog{background:#334;padding:4px 8px;border-radius:6px;cursor:pointer;font-size:12px}"
  ".hl{color:#29ABE2;font-weight:700}"
  "</style>"
  "<header>ISS <span class=b>WeighBox</span> &middot; Weigh Forward</header>"
  "<main><nav>"
  "<a href=/>Status</a> "
  "<a href=/sniff>Sniffer</a> "
  "<a href=/config>Config</a> "
  "<a href=/update>Update</a>"
  "</nav>";

void handleRoot() {
  String p = FPSTR(PH);
  String sta = (WiFi.status()==WL_CONNECTED)
    ? (gwc.wifiSsid + " @ " + WiFi.localIP().toString())
    : String("not connected");
  p += "<div class=card><b>Network</b><br>"
       "STA: " + sta + "<br>"
       "AP: "  + gwc.apSsid + " @ " + WiFi.softAPIP().toString() + "<br>"
       "mDNS: <span class=hl>" + gwc.mdns + ".local</span><br>"
       "WS: ws://" + WiFi.localIP().toString() + ":81/</div>";
  p += "<div class=card>"
       "<b>Site: <span class=hl>" + gwc.site + "</span></b><br>" +
       gwc.bsName + ": Rate " + String(bsR,2) + " t/h  Spd " +
       String(bsSp,2) + " m/s  Tot " + String(bsTot,1) +
       " t &nbsp; ok: " + (bsOk()?"yes":"no") + "</div>";
  p += "<div class=card><b>Firmware</b> " FW_VERSION " &middot; remote OTA: ";
  p += otaKeyConfigured() ? (otaEnabled ? "on" : "off (config)") : "off (no key)";
  p += "<br>Last check: " + otaStatus;
  p += "<br>Image: "; p += fwConfirmed ? "confirmed" : "on probation";
  p += "<br>Cloud: HTTP " + String(lastPostCode) + " &middot; every " + String(cloudMs/1000.0,1) + " s</div>";
  p += "<div class=card>Heap: " + String(ESP.getFreeHeap()) + " B &middot; RSSI: " + String(WiFi.RSSI()) + " dBm</div></main>";
  webSrv.send(200, "text/html", p);
}

void handleInfo() {
  webSrv.sendHeader("Access-Control-Allow-Origin","*");
  String j = "{\"box_name\":\"" + gwc.bsName + "\""
             ",\"site\":\"" + gwc.site + "\""
             ",\"online\":true"
             ",\"scale_ok\":" + (bsOk()?"true":"false") +
             ",\"weight\":" + String(wbW) +
             ",\"stable\":" + (wbSt?"true":"false") +
             ",\"ws\":\"ws://" + WiFi.localIP().toString() + ":81/\""
             ",\"mdns\":\"" + gwc.mdns + ".local\""
             ",\"fw\":\"iss-wb\",\"fw_version\":\"" FW_VERSION "\"}";
  webSrv.send(200, "application/json", j);
}

void handleSniff() {
  String p = FPSTR(PH);
  p += "<div style='display:flex;gap:8px'>"
       "<span class=tog onclick='hex=!hex'>ASCII/HEX</span>"
       "<span class=tog onclick='paused=!paused'>Pause</span>"
       "<span class=tog onclick=\"o2.textContent='';o4.textContent=''\">Clear</span></div>"
       "<div class=card><b>RS232</b> (" + gwc.wbName + ")"
       "<input id=i2 placeholder='send+Enter'><pre id=o2></pre></div>"
       "<div class=card><b>RS485</b> (" + gwc.bsName + ")"
       "<input id=i4 placeholder='send+Enter'><pre id=o4></pre></div>"
       "<script>let hex=false,paused=false,a=0,b=0;"
       "let o2=document.getElementById('o2'),o4=document.getElementById('o4');"
       "function h2a(h){return h.trim().split(' ').filter(x=>x).map(x=>{"
         "let c=parseInt(x,16);"
         "return c>=32&&c<127?String.fromCharCode(c):(c==10?'\\n':'.');}).join('');}"
       "function put(el,h){if(!h)return;el.textContent+=(hex?h:h2a(h));"
         "if(el.textContent.length>20000)el.textContent=el.textContent.slice(-15000);"
         "el.scrollTop=el.scrollHeight;}"
       "async function poll(){if(!paused){try{"
         "let r=await fetch('/data?a='+a+'&b='+b);"
         "let j=await r.json();"
         "put(o2,j.h232);a=j.t232;put(o4,j.h485);b=j.t485;"
       "}catch(e){}}setTimeout(poll,250);}poll();"
       "function snd(id,pt){let i=document.getElementById(id);"
         "i.addEventListener('keydown',ev=>{if(ev.key=='Enter'){"
           "fetch('/send?p='+pt+'&d='+encodeURIComponent(i.value));i.value='';}});}"
       "snd('i2','232');snd('i4','485');"
       "</script></main>";
  webSrv.send(200, "text/html", p);
}

void handleData() {
  uint32_t t2, t4;
  uint32_t a  = (uint32_t)atol(webSrv.arg("a").c_str());
  uint32_t bv = (uint32_t)atol(webSrv.arg("b").c_str());
  String h2 = rbDelta(rb232, a,  t2);
  String h4 = rbDelta(rb485, bv, t4);
  String j = "{\"t232\":" + String(t2) + ",\"h232\":\"" + h2 +
             "\",\"t485\":" + String(t4) + ",\"h485\":\"" + h4 + "\"}";
  webSrv.send(200, "application/json", j);
}

void handleSend() {
  String pt=webSrv.arg("p"), d=webSrv.arg("d");
  if (pt=="232") { p232.print(d); p232.print("\r\n"); }
  else if (pt=="485") {
    if (RS485_DE>=0) digitalWrite(RS485_DE, HIGH);
    p485.print(d); p485.print("\r\n"); p485.flush();
    if (RS485_DE>=0) digitalWrite(RS485_DE, LOW);
  }
  webSrv.send(200, "text/plain", "ok");
}

void handleConfig() {
  String p = FPSTR(PH);
  p += "<form method=POST action=/save>"
       "<div class=card><b>Site &amp; Scale identity</b>"
       "<label>Site name</label>"
       "<input name=sit value='" + gwc.site + "'>"
       "<label>Scale Name (Target Tab)</label>"
       "<input name=bsn value='" + gwc.bsName + "'>"
       "<label>mDNS hostname</label>"
       "<input name=mdn value='" + gwc.mdns + "'></div>"
       "<div class=card><b>WiFi (site network)</b>"
       "<label>SSID</label>"
       "<input name=wss value='" + gwc.wifiSsid + "'>"
       "<label>Password</label>"
       "<input name=wsp value='" + gwc.wifiPass + "'></div>"
       "<div class=card><b>Hotspot (AP)</b>"
       "<label>AP SSID</label>"
       "<input name=aps value='" + gwc.apSsid + "'>"
       "<label>AP Password (8+ chars) — also protects /update</label>"
       "<input name=app value='" + gwc.apPass + "'></div>"
       "<div class=card><b>Serial baud rates</b>"
       "<label>RS232 baud</label>"
       "<input name=b2 value='" + String(gwc.baud232) + "'>"
       "<label>RS485 baud</label>"
       "<input name=b4 value='" + String(gwc.baud485) + "'></div>"
       "<button>Save &amp; Reboot</button>"
       "</form></main>";
  webSrv.send(200, "text/html", p);
}

void handleSave() {
  gwc.site     = webSrv.arg("sit");
  gwc.bsName   = webSrv.arg("bsn");
  gwc.mdns     = webSrv.arg("mdn");
  gwc.wifiSsid = webSrv.arg("wss");
  gwc.wifiPass = webSrv.arg("wsp");
  gwc.apSsid   = webSrv.arg("aps");
  gwc.apPass   = webSrv.arg("app");
  gwc.baud232  = (uint32_t)atol(webSrv.arg("b2").c_str());
  gwc.baud485  = (uint32_t)atol(webSrv.arg("b4").c_str());
  saveCfg();
  webSrv.send(200, "text/html",
    String("<meta http-equiv=refresh content='3;url=/'>Saved. Rebooting..."));
  delay(400); ESP.restart();
}

// ── LAN firmware upload (fallback when the cloud path is unavailable) ──
// Locked unless the AP password has been changed from the well-known default.
// NOTE: this path does not check the release signature — it is as strong as the AP password.
bool updAuth() {
  if (gwc.apPass == DEF_AP_PASS) { webSrv.send(403, "text/plain", "Change the AP password in /config first"); return false; }
  if (!webSrv.authenticate("admin", gwc.apPass.c_str())) { webSrv.requestAuthentication(); return false; }
  return true;
}
void handleUpdatePage() {
  if (!updAuth()) return;
  String p = FPSTR(PH);
  p += "<div class=card><b>Firmware " FW_VERSION "</b><br>Upload a compiled .bin (Sketch → Export Compiled Binary)."
       "<form method=POST action=/update enctype='multipart/form-data'>"
       "<input type=file name=fw accept='.bin'><button>Upload &amp; flash</button></form></div></main>";
  webSrv.send(200, "text/html", p);
}
void handleUpdateDone() {
  if (!updAuth()) return;
  bool ok = !Update.hasError();
  webSrv.send(200, "text/html", ok ? "<meta http-equiv=refresh content='15;url=/'>Flashed. Rebooting..." : "Update FAILED");
  if (ok) { delay(400); ESP.restart(); }
}
void handleUpdateUpload() {
  if (gwc.apPass == DEF_AP_PASS || !webSrv.authenticate("admin", gwc.apPass.c_str())) return;
  HTTPUpload& up = webSrv.upload();
  if (up.status == UPLOAD_FILE_START)      Update.begin(UPDATE_SIZE_UNKNOWN);
  else if (up.status == UPLOAD_FILE_WRITE) Update.write(up.buf, up.currentSize);
  else if (up.status == UPLOAD_FILE_END)   Update.end(true);
  else if (up.status == UPLOAD_FILE_ABORTED) Update.abort();
}

// ══════════════════════════════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  if (RS485_DE>=0) { pinMode(RS485_DE,OUTPUT); digitalWrite(RS485_DE,LOW); }
  loadCfg();
  p232.begin(gwc.baud232, SERIAL_8N1, RS232_RX, RS232_TX);
  p485.begin(gwc.baud485, SERIAL_8N1, RS485_RX, RS485_TX);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(gwc.apSsid.c_str(), gwc.apPass.c_str());
  if (gwc.wifiSsid.length()) WiFi.begin(gwc.wifiSsid.c_str(), gwc.wifiPass.c_str());
  if (MDNS.begin(gwc.mdns.c_str())) {
    MDNS.addService("http","tcp",80);
    MDNS.addService("ws",  "tcp",81);
  }
  webSrv.on("/",       handleRoot);
  webSrv.on("/info",   handleInfo);
  webSrv.on("/sniff",  handleSniff);
  webSrv.on("/data",   handleData);
  webSrv.on("/send",   handleSend);
  webSrv.on("/config", handleConfig);
  webSrv.on("/save",   HTTP_POST, handleSave);
  webSrv.on("/update", HTTP_GET,  handleUpdatePage);
  webSrv.on("/update", HTTP_POST, handleUpdateDone, handleUpdateUpload);
  webSrv.begin();
  tcpWs.begin();
  tOta = millis() - OTA_CHECK_MS + 60000;   // first update check ~1 min after boot
}

void loop() {
  webSrv.handleClient();
  wsCheckNew();
  wsService();

  uint8_t buf[128]; size_t n;

  n=0; while (p232.available()&&n<sizeof(buf)) buf[n++]=p232.read();
  if (n){rbPush(rb232,buf,n);for(size_t i=0;i<n;i++) wbFeed(buf[i]);}

  n=0; while (p485.available()&&n<sizeof(buf)) buf[n++]=p485.read();
  if (n){rbPush(rb485,buf,n);for(size_t i=0;i<n;i++) bsFeed(buf[i]);}

  if (millis()-tWs>=250){tWs=millis();wsBroadcast(telemetryJson());}

  // Telemetry + heartbeat in one post (the old separate 30 s heartbeat was a duplicate)
  if (millis()-tCl>=cloudMs){tCl=millis();cloudPost();}

  // A freshly flashed image is only kept once it has run a while AND reached the cloud.
  // If it crashes or can't connect, the bootloader reverts to the previous image.
  if (!fwConfirmed && millis()>OTA_CONFIRM_MS && lastPostCode>=200 && lastPostCode<300) {
    esp_ota_mark_app_valid_cancel_rollback();
    fwConfirmed = true;
  }

  if (fwConfirmed && millis()-tCfg>=CFG_CHECK_MS) { tCfg=millis(); cfgCheck(); }
  if (fwConfirmed && millis()-tOta>=OTA_CHECK_MS) { tOta=millis(); otaCheck(); }

  if (millis()-tWsChk>=10000){tWsChk=millis();tcpWs.begin();}

  if (millis()-tLed>(WiFi.status()==WL_CONNECTED?1500:300)){
    tLed=millis();digitalWrite(LED_PIN,!digitalRead(LED_PIN));
  }
}
