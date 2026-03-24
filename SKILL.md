---
name: corgi-tunnel
description: Set up, diagnose, and maintain the Corgi Dashboard tunnel connecting this Eragon gateway to the shared web relay. Use when asked to set up the dashboard, connect to the relay, start the tunnel, enable the web UI, fix "Reconnecting" issues, or troubleshoot connectivity. Triggers on "corgi dashboard", "tunnel setup", "web UI", "relay connection", "reconnecting", "disconnected", "tunnel down", "tunnel not working", "chat history not loading".
---

# Corgi Dashboard Tunnel

Connect this Eragon gateway to the Corgi Dashboard web UI via a WebSocket relay.

## Architecture

```
Browser → Dashboard (Railway) → Relay (Railway) → Tunnel (this machine) → Gateway (local)
```

- **Dashboard**: Static SPA at `https://dashboard-production-3553.up.railway.app`
- **Relay**: WebSocket router at `wss://relay-production-724a.up.railway.app`
- **Tunnel**: Node.js client running locally, connects outbound to relay
- **Gateway**: Eragon gateway on `127.0.0.3:<port>` (port from eragon.json)

### Key Protocol Details

The Eragon gateway speaks first — it sends a `connect.challenge` (nonce) before the browser sends anything. The browser responds with `{type:"req", method:"connect", params:{auth:{token:"..."}}}`. The relay must route the browser to the correct tunnel **immediately on connect** (before any messages), using the gateway token passed as a URL query param: `/ws?token=<TOKEN>`.

### Multi-Tunnel Routing

Multiple Mac minis can connect simultaneously. Each tunnel registers with a unique `TUNNEL_ID` and declares its gateway token(s) via `register_tokens`. The relay routes each browser to the correct tunnel based on which token they authenticate with.

Relay health: `curl -s https://relay-production-724a.up.railway.app/health` — shows all connected tunnels and browser count.

## Security Notes

- Tunnel connects **outbound only** — no ports opened on this machine
- Gateway auth token is written to a local `.env` file — never display it in chat
- Relay authenticates tunnels with a shared secret (`TUNNEL_SECRET`)
- Browser connections authenticated via gateway token (challenge-response)
- Tunnel client code is bundled with this skill — no external downloads

## Setup

### Automatic Setup

1. Read the raw eragon config to get port and token:

```bash
python3 -c "
import json, glob, os
path = next(glob.glob(os.path.expanduser('~/.eragon-*/eragon.json')))
c = json.load(open(path))
print(c['gateway']['port'])
print(c['gateway']['auth']['token'])
"
```

**Important:** Read the raw file directly. Do NOT use `config.get` — it redacts `gateway.auth.token`. Store both values. Do NOT display the token in chat.

2. Run the setup script:

```bash
bash <SKILL_DIR>/scripts/setup.sh <tunnel_id> <port> <token>
```

- `tunnel_id`: short unique name, lowercase, no spaces (e.g. first name)
- `port`: gateway port from step 1
- `token`: gateway auth token from step 1

3. Verify: `curl -s https://relay-production-724a.up.railway.app/health | python3 -m json.tool`
   — the tunnel ID should appear in `tunnelDetails`.

4. Tell the user their dashboard URL, WebSocket URL, and auth token (for browser Settings).

### Keepalive Setup (Critical)

The tunnel process dies silently and frequently. Known causes:
- Parent shell session cleaned up by OS
- Relay redeploys (Railway push triggers new container, all tunnel WS connections drop)
- Mac sleep/wake
- `nohup` processes are NOT reliable long-term on macOS

**Always set up a keepalive.** Options in order of preference:

**Option A — Eragon Cron (recommended, always works):**

Create a cron job that fires every 2 minutes:
```
Schedule: every 120000ms
Payload (systemEvent): "TUNNEL KEEPALIVE: Run pgrep -f 'node.*client.js'. If no process, run /path/to/ensure-running.sh. If running, reply HEARTBEAT_OK."
Session target: main
```

**Option B — System crontab:**
```bash
* * * * * /path/to/ensure-running.sh
```
Note: `crontab` is often blocked by macOS permissions (operation not permitted). Use Option A.

**Option C — launchd (macOS):**
LaunchAgents require write access to `~/Library/LaunchAgents/` — agent processes usually get EPERM. Use Option A.

The `ensure-running.sh` script checks `pgrep`, verifies the tunnel is registered on the relay health endpoint, kills zombie processes, and restarts the watchdog if needed.

## Troubleshooting Guide

### Quick Health Check

Run this first for any connectivity issue:

```bash
echo "=== TUNNEL PROCESS ===" && \
pgrep -af "client.js" | grep -v pgrep || echo "DEAD" && \
echo "" && echo "=== RELAY ===" && \
curl -s "https://relay-production-724a.up.railway.app/health" | python3 -m json.tool && \
echo "" && echo "=== LOG (last 10) ===" && \
tail -10 /tmp/tunnel-client.log
```

### "Reconnecting..." in Dashboard

Most common issue. Work through this sequence:

#### Step 1: Is the tunnel process alive?

```bash
pgrep -af "client.js" | grep -v pgrep
```

If no output → tunnel is dead. Run `ensure-running.sh` or restart manually:
```bash
cd ~/corgi-tunnel/client && source .env
export RELAY_URL GATEWAY_URL GATEWAY_TOKEN TUNNEL_SECRET TUNNEL_ID DASHBOARD_ORIGIN
pkill -f "node.*client\.js" 2>/dev/null; sleep 1
nohup bash -c 'while true; do node client.js >> /tmp/tunnel-client.log 2>&1; sleep 3; done' &
```

#### Step 2: Is the tunnel registered on the relay?

```bash
curl -s https://relay-production-724a.up.railway.app/health | python3 -m json.tool
```

Check `tunnelDetails` for your tunnel ID. Common issues:
- **Tunnel process alive but not in health response**: Relay may have redeployed. Tunnel auto-reconnects in 3s, but check log for errors.
- **Known issue**: Relay can show a stale tunnel as "connected" for up to 60s after the process dies (WebSocket ping timeout). Always check `pgrep` first.
- Wrong `TUNNEL_SECRET` — must be `corgi-tunnel-2026`

#### Step 3: Is the gateway running?

```bash
lsof -i -P | grep <PORT> | head -3
```

Replace `<PORT>` with the gateway port from `.env`. Should show a `node` process LISTENING. If not → `eragon gateway restart`.

#### Step 4: Check the tunnel log

```bash
tail -30 /tmp/tunnel-client.log
```

**Healthy log:**
```
[tunnel:ID] Connecting to relay...
[tunnel:ID] ✓ Connected to relay
[tunnel:ID] Registered 1 token(s) with relay
[tunnel:ID] Opening gateway for browser abc123
[tunnel:ID] Gateway open for abc123
```

**Problem patterns:**

| Log Pattern | Cause | Fix |
|---|---|---|
| `Gateway open` → immediate `Gateway closed` | Origin header mismatch | Verify `DASHBOARD_ORIGIN` in .env matches `https://dashboard-production-3553.up.railway.app` |
| `Shutting down...` repeated | Process receiving SIGTERM | Multiple competing watchdogs — kill all, restart one |
| No recent output | Process hung or dead | Kill and restart |
| `ECONNREFUSED` | Gateway not running | Check port in .env, run `eragon gateway restart` |
| `401` or auth errors | Wrong tunnel secret | Verify `TUNNEL_SECRET=corgi-tunnel-2026` |

#### Step 5: Gateway connections open then immediately close (rapid open/close cycle)

Root causes found and fixed:

1. **Origin header mismatch**: Gateway checks `allowedOrigins`. Tunnel client must send `Origin: https://dashboard-production-3553.up.railway.app`. Set via `DASHBOARD_ORIGIN` env var.

2. **Relay protocol mismatch (v3.0 bug, fixed in v3.1)**: Relay v3.0 waited for browser's first message to decide routing. But the gateway sends `connect.challenge` first — so the relay sat in dead silence. Fix: relay v3.1 routes on connect using token from URL query param `/ws?token=<TOKEN>`.

3. **Multiple watchdog instances**: Competing bash loops each start a node process, they fight for the same gateway connection. Fix: always `pkill -f "node.*client\.js"` before starting a new watchdog.

#### Step 6: Test the full path manually

**Direct gateway test** (bypasses relay and tunnel):
```bash
cd ~/corgi-tunnel/client && source .env && export GATEWAY_URL GATEWAY_TOKEN DASHBOARD_ORIGIN
node -e "
const WS=require('ws');
const ws=new WS(process.env.GATEWAY_URL,{headers:{Origin:process.env.DASHBOARD_ORIGIN}});
ws.on('open',()=>console.log('OPEN'));
ws.on('message',d=>{const m=JSON.parse(d.toString());console.log(m.type,m.event||'');if(m.event==='connect.challenge'){ws.send(JSON.stringify({type:'req',id:'t1',method:'connect',params:{minProtocol:3,maxProtocol:3,auth:{token:process.env.GATEWAY_TOKEN},role:'operator',scopes:['operator.admin'],caps:['tool-events'],client:{id:'test',version:'1.0.0'}}}));console.log('→ sent connect')}});
ws.on('close',(c,r)=>console.log('CLOSED',c,r.toString()));
setTimeout(()=>{ws.close();process.exit(0)},8000);
"
```

Expected: `OPEN → event connect.challenge → sent connect → res (hello-ok) → event health → event tick`

**Through-relay test** (full path, same as browser):
```bash
cd ~/corgi-tunnel/client && source .env && export GATEWAY_TOKEN
node -e "
const WS=require('ws');
const ws=new WS('wss://relay-production-724a.up.railway.app/ws?token='+encodeURIComponent(process.env.GATEWAY_TOKEN));
ws.on('open',()=>console.log('RELAY OPEN'));
ws.on('message',d=>{const m=JSON.parse(d.toString());console.log(m.type,m.event||'');if(m.event==='connect.challenge'){ws.send(JSON.stringify({type:'req',id:'t1',method:'connect',params:{minProtocol:3,maxProtocol:3,auth:{token:process.env.GATEWAY_TOKEN},role:'operator',scopes:['operator.admin'],caps:['tool-events'],client:{id:'test',version:'1.0.0'}}}));console.log('→ sent connect')}});
ws.on('close',(c,r)=>console.log('CLOSED',c,r.toString()));
setTimeout(()=>{ws.close();process.exit(0)},8000);
"
```

**Test chat.history through relay** (proves data flows end-to-end):
```bash
cd ~/corgi-tunnel/client && source .env && export GATEWAY_TOKEN
node -e "
const WS=require('ws');
const ws=new WS('wss://relay-production-724a.up.railway.app/ws?token='+encodeURIComponent(process.env.GATEWAY_TOKEN));
let ok=false;
ws.on('message',d=>{
  const m=JSON.parse(d.toString());
  if(m.event==='connect.challenge'){ws.send(JSON.stringify({type:'req',id:'c1',method:'connect',params:{minProtocol:3,maxProtocol:3,auth:{token:process.env.GATEWAY_TOKEN},role:'operator',scopes:['operator.admin'],caps:['tool-events'],client:{id:'test',version:'1.0.0'}}}));}
  if(m.type==='res'&&m.id==='c1'&&m.ok){ws.send(JSON.stringify({type:'req',id:'h1',method:'chat.history',params:{limit:3}}));}
  if(m.type==='res'&&m.id==='h1'){console.log('✓ chat.history:',(m.payload?.messages?.length||0),'messages');ws.close();process.exit(0);}
});
setTimeout(()=>{console.log('TIMEOUT');process.exit(1)},10000);
"
```

If direct works but relay doesn't → relay or tunnel issue.
If neither works → gateway issue.
If both work but browser doesn't → browser cache, extension, or proxy issue (try incognito).

### Chat History Not Loading (Skeleton Stuck)

Dashboard connects (green dot) but messages show as gray loading skeletons.

**Root cause found:** The dashboard's `serve.js` was serving files from a `dist/` subdirectory but the actual built files were in the repo root. Every deploy appeared to succeed but served stale old JS that didn't have the latest fixes.

**Diagnosis:**
```bash
# Check what JS the dashboard is actually serving
curl -s "https://dashboard-production-3553.up.railway.app/" | grep -o 'index-[A-Za-z0-9_-]*\.js'
```

Compare with what's in the deploy repo. If they don't match → `serve.js` is looking in the wrong directory.

**Other causes:**
- `chat.history` request timing out (15s timeout, 3 retries with backoff built in)
- Gateway returning empty messages (filtered too aggressively)
- Tap the skeleton to manually trigger a retry (built into UI)

**Fix (dashboard deploy repo):** Ensure `serve.js` has `const DIST = __dirname;` (serve from repo root), NOT `const DIST = path.join(__dirname, 'dist');`.

### Browser Shows "Disconnected" (Never Connects)

- No token entered in dashboard Settings
- Wrong WebSocket URL (must be `wss://relay-production-724a.up.railway.app/ws`)
- Service worker caching stale HTML/JS → hard refresh (Cmd+Shift+R)
- Try incognito to rule out extensions

### Deploy Goes Through but Old JS Still Served

**Root cause found and fixed:** The deploy repo's `serve.js` referenced a `dist/` subdirectory that contained stale files from a previous build structure. New dist files were copied to the repo root. Railway deployed successfully but `serve.js` kept reading old files from `dist/`.

**Prevention:** After copying new build artifacts to the deploy repo:
1. Ensure there's no stale `dist/` subdirectory
2. Verify `serve.js` serves from the correct path (`__dirname` for root)
3. Check deployed JS hash matches: `curl -s <dashboard-url>/ | grep -o 'index-[A-Za-z0-9_-]*\.js'`

## .env Reference

```bash
RELAY_URL=wss://relay-production-724a.up.railway.app
GATEWAY_URL=ws://127.0.0.3:<PORT>
GATEWAY_TOKEN=<from eragon.json gateway.auth.token>
TUNNEL_SECRET=corgi-tunnel-2026
TUNNEL_ID=<lowercase unique name>
DASHBOARD_ORIGIN=https://dashboard-production-3553.up.railway.app
```

## File Locations

| File | Path |
|---|---|
| Tunnel client | `~/corgi-tunnel/client/client.js` |
| Environment config | `~/corgi-tunnel/client/.env` |
| Watchdog script | `~/corgi-tunnel/client/watchdog.sh` |
| Keepalive script | `~/corgi-tunnel/client/ensure-running.sh` |
| Tunnel log | `/tmp/tunnel-client.log` |
| Eragon config | `~/.eragon-*/eragon.json` |
| Dashboard deploy repo | `corgi-gcp/corgi-dashboard-app` on GitHub |
| Dashboard serve.js | In deploy repo root: `serve.js` |
| Relay source | `corgi-gcp/corgi-relay` on GitHub |

## User Onboarding Message

After setup, send the user:

> **Your Corgi Dashboard is ready!**
>
> 1. Open: https://dashboard-production-3553.up.railway.app
> 2. Click ⚙️ (top right)
> 3. Set **WebSocket URL** to: `wss://relay-production-724a.up.railway.app/ws`
> 4. Set **Auth Token** to: `<their token>`
> 5. Click **Save & Reconnect**
>
> **Install as app (Safari):** File → Add to Dock
> **Install as app (Chrome):** ⋮ → Cast, save, and share → Install page as app
> **Tips:** Enter sends, Shift+Enter for newline, Cmd+K for command palette
