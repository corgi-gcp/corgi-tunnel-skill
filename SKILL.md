---
name: corgi-tunnel
description: Set up, diagnose, and maintain the Corgi Dashboard tunnel connecting this Eragon gateway to the shared web relay. Use when asked to set up the dashboard, connect to the relay, start the tunnel, enable the web UI, fix "Reconnecting" issues, or troubleshoot connectivity. Triggers on "corgi dashboard", "tunnel setup", "web UI", "relay connection", "reconnecting", "disconnected", "tunnel down", "tunnel not working".
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

The tunnel process dies silently when the parent shell session is cleaned up, when the relay redeploys, or when the Mac sleeps. **Always set up a keepalive** using one of these methods (in order of preference):

**Option A — Eragon Cron (recommended, always works):**

Create a cron job that checks every 2 minutes:
```
Schedule: every 120000ms
Payload (systemEvent): "TUNNEL KEEPALIVE: Run pgrep -f 'node.*client.js'. If no process, run /path/to/ensure-running.sh. If running, reply HEARTBEAT_OK."
Session target: main
```

**Option B — System crontab:**
```bash
* * * * * /path/to/ensure-running.sh
```
Note: `crontab` may be blocked by macOS permissions (operation not permitted). Use Option A instead.

**Option C — launchd (macOS):**
LaunchAgents require write access to `~/Library/LaunchAgents/` — agent processes often get EPERM. Use Option A instead.

The `ensure-running.sh` script (created by setup.sh) checks `pgrep` and restarts the watchdog if dead.

## Troubleshooting Guide

### "Reconnecting..." in Dashboard

This is the most common issue. Diagnose with this sequence:

#### Step 1: Is the tunnel process alive?

```bash
pgrep -af "client.js" | grep -v pgrep
```

If no output → tunnel is dead. Restart it:
```bash
bash /path/to/ensure-running.sh
```
Or manually:
```bash
cd ~/corgi-tunnel/client && source .env
export RELAY_URL GATEWAY_URL GATEWAY_TOKEN TUNNEL_SECRET TUNNEL_ID DASHBOARD_ORIGIN
nohup bash -c 'while true; do node client.js >> /tmp/tunnel-client.log 2>&1; sleep 3; done' &
```

#### Step 2: Is the tunnel registered on the relay?

```bash
curl -s https://relay-production-724a.up.railway.app/health | python3 -m json.tool
```

Check `tunnelDetails` for your tunnel ID. If missing:
- Tunnel process may be running but disconnected (check log)
- Relay may have redeployed (tunnel auto-reconnects in 3s)
- `TUNNEL_SECRET` may be wrong — must be `corgi-tunnel-2026`

**Known issue:** Relay can show a stale tunnel as "connected" for up to 60s after the process dies (WebSocket ping timeout lag). Check `pgrep` first, don't trust `/health` alone.

#### Step 3: Is the gateway running?

```bash
lsof -i -P | grep <PORT> | head -3
```

Replace `<PORT>` with the gateway port from `.env`. Should show a `node` process LISTENING. If not, the Eragon gateway itself is down — restart it with `eragon gateway restart`.

#### Step 4: Check the tunnel log

```bash
tail -30 /tmp/tunnel-client.log
```

**Healthy pattern:**
```
[tunnel:ID] Connecting to relay...
[tunnel:ID] ✓ Connected to relay
[tunnel:ID] Registered 1 token(s) with relay
[tunnel:ID] Opening gateway for browser abc123
[tunnel:ID] Gateway open for abc123
```

**Unhealthy patterns:**

| Log Pattern | Cause | Fix |
|---|---|---|
| `Gateway open` then immediate `Gateway closed` | Gateway rejecting connection | Check Origin header in .env matches `DASHBOARD_ORIGIN` |
| `Shutting down...` repeated | Process received SIGTERM | Something is killing it — check for conflicting watchdogs |
| No recent output | Process hung or dead | Kill and restart |
| `ECONNREFUSED` | Gateway not running on expected port | Verify port in .env matches eragon.json |
| `401` or auth errors | Wrong tunnel secret | Verify `TUNNEL_SECRET=corgi-tunnel-2026` |

#### Step 5: Gateway connections open then immediately close

This was a major recurring issue. Root causes found:

1. **Origin header mismatch**: The gateway checks `allowedOrigins`. The tunnel client must send `Origin: https://dashboard-production-3553.up.railway.app` when connecting to the gateway. This is set via the `DASHBOARD_ORIGIN` env var.

2. **Gateway protocol mismatch**: The gateway sends `connect.challenge` first. If the browser's response doesn't reach the gateway within the timeout (because the relay was waiting for browser message before routing), connections die immediately. Fix: relay v3.1 routes on connect using token query param.

3. **Multiple watchdog instances**: If multiple watchdog loops are running, they compete — one opens a gateway connection, another's process gets killed, connection drops. Always `pkill -f "corgi-tunnel.*client.js"` before starting a new watchdog.

#### Step 6: Test the full path manually

Direct gateway test (bypasses relay):
```bash
cd ~/corgi-tunnel/client && node -e "
const WS=require('ws');
const ws=new WS(process.env.GATEWAY_URL,{headers:{Origin:process.env.DASHBOARD_ORIGIN}});
ws.on('open',()=>console.log('OPEN'));
ws.on('message',d=>{const m=JSON.parse(d.toString());console.log(m.type,m.event||'');if(m.event==='connect.challenge'){ws.send(JSON.stringify({type:'req',id:'t1',method:'connect',params:{minProtocol:3,maxProtocol:3,auth:{token:process.env.GATEWAY_TOKEN},role:'operator',scopes:['operator.admin'],caps:['tool-events'],client:{id:'test',version:'1.0.0'}}}));console.log('→ sent connect')}});
ws.on('close',(c,r)=>console.log('CLOSED',c,r.toString()));
setTimeout(()=>{ws.close();process.exit(0)},8000);
"
```

Expected: `OPEN → event connect.challenge → sent connect → res (hello-ok) → event health → event tick`

Through-relay test:
```bash
node -e "
const WS=require('ws');
const ws=new WS('wss://relay-production-724a.up.railway.app/ws?token='+encodeURIComponent(process.env.GATEWAY_TOKEN));
ws.on('open',()=>console.log('RELAY OPEN'));
ws.on('message',d=>{const m=JSON.parse(d.toString());console.log(m.type,m.event||'')});
ws.on('close',(c,r)=>console.log('CLOSED',c,r.toString()));
setTimeout(()=>{ws.close();process.exit(0)},8000);
"
```

If direct works but relay doesn't → relay or tunnel issue.
If neither works → gateway issue.

### Browser Shows "Disconnected" (Never Connects)

- Token not entered in dashboard Settings (must paste gateway auth token)
- Wrong WebSocket URL (must be `wss://relay-production-724a.up.railway.app/ws`)
- Browser may have cached old JS — hard refresh (Cmd+Shift+R)

### Tunnel Works from CLI but Not from Browser

- Browser WebSocket may have different timeout behavior
- Check browser console (F12 → Console) for WebSocket errors
- Try incognito window to rule out extension interference

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
