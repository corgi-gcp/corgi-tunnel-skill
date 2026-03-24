---
name: corgi-tunnel
description: Set up and manage the Corgi Dashboard tunnel that connects this Eragon gateway to the shared web relay. Use when asked to set up the dashboard, connect to the relay, start the tunnel, or enable the web UI. Also triggers on "corgi dashboard", "tunnel setup", "web UI", or "relay connection".
---

# Corgi Dashboard Tunnel

Connect this Eragon gateway to the Corgi Dashboard web UI via a WebSocket relay.

## What This Does

The Corgi Dashboard is a web UI at `https://dashboard-production-3553.up.railway.app` that lets users chat with their Eragon bot from a browser. Since the gateway runs on a local machine and the dashboard runs on Railway (public internet), a tunnel bridges them via a relay server.

```
Browser → Dashboard (Railway) → Relay (Railway) → Tunnel (this machine) → Gateway (local)
```

The tunnel client runs locally, connects outbound to the relay, and forwards WebSocket traffic to the local gateway. No inbound ports are opened.

## Security Notes

- The tunnel connects **outbound only** — no ports opened on this machine
- The gateway auth token is written to a local `.env` file and never displayed in chat
- The relay authenticates tunnels with a shared secret
- Browser connections are authenticated with the gateway token (challenge-response protocol)
- The tunnel client code is bundled with this skill — no external downloads needed

## Setup

### Automatic Setup

1. Read the raw eragon config file to extract the gateway port and auth token:

```bash
python3 -c "
import json, glob, os
path = next(glob.glob(os.path.expanduser('~/.eragon-*/eragon.json')))
c = json.load(open(path))
print(c['gateway']['port'])
print(c['gateway']['auth']['token'])
"
```

**Important:** Read the raw file directly. Do NOT use `config.get` (it redacts the token). Store both values — do NOT display the token in chat.

2. Run the setup script with the extracted values:

```bash
bash <SKILL_DIR>/scripts/setup.sh <tunnel_id> <port> <token>
```

- `tunnel_id`: A short unique name, lowercase, no spaces (e.g. the user's first name)
- `port`: The gateway port from step 1
- `token`: The gateway auth token from step 1

The script copies the tunnel client, installs dependencies, writes the `.env` config, and starts a watchdog that auto-restarts the tunnel.

3. Verify at: `https://relay-production-724a.up.railway.app/health` — the tunnel ID should appear in `tunnelDetails`.

4. Tell the user:
   - **Dashboard URL:** `https://dashboard-production-3553.up.railway.app`
   - **WebSocket URL** (for Settings): `wss://relay-production-724a.up.railway.app/ws`
   - **Auth Token**: Tell them their gateway auth token so they can paste it into the dashboard Settings. This is the only time it leaves the machine — the user needs it to authenticate their browser session.

### Manual Verification

Check tunnel status:
```bash
curl -s https://relay-production-724a.up.railway.app/health | python3 -m json.tool
```

Check tunnel logs:
```bash
tail -20 /tmp/tunnel-client.log
```

Restart tunnel:
```bash
pkill -f "corgi-tunnel.*client.js" 2>/dev/null; nohup ~/corgi-tunnel/client/watchdog.sh > /tmp/tunnel-client.log 2>&1 &
```

## User Onboarding Message

After setup, send the user this:

> **Your Corgi Dashboard is ready!**
>
> 1. Open: https://dashboard-production-3553.up.railway.app
> 2. Click ⚙️ (top right)
> 3. Set **WebSocket URL** to: `wss://relay-production-724a.up.railway.app/ws`
> 4. Set **Auth Token** to: `<their token>`
> 5. Click **Save & Reconnect**
>
> **Add to dock (Mac Safari):** File → Add to Dock
> **Add to dock (Chrome):** ⋮ menu → Cast, save, and share → Install page as app
> **Tips:** Enter sends, Shift+Enter for newline, Cmd+K for command palette
