/**
 * Corgi Tunnel Client — connects local Eragon gateway to the shared relay.
 *
 * Env vars (all required):
 *   RELAY_URL       — wss://relay-production-724a.up.railway.app
 *   GATEWAY_URL     — ws://127.0.0.3:<port>
 *   GATEWAY_TOKEN   — auth token from eragon.json gateway.auth.token
 *   TUNNEL_SECRET   — shared relay secret
 *   TUNNEL_ID       — unique name for this tunnel (e.g. first name lowercase)
 *   DASHBOARD_ORIGIN — https://dashboard-production-3553.up.railway.app
 */
'use strict';

const WebSocket = require('ws');

const R = process.env.RELAY_URL;
const G = process.env.GATEWAY_URL;
const T = process.env.GATEWAY_TOKEN;
const S = process.env.TUNNEL_SECRET;
const I = process.env.TUNNEL_ID;
const O = process.env.DASHBOARD_ORIGIN;

if (!R) { console.error('[tunnel] RELAY_URL required'); process.exit(1); }
if (!G) { console.error('[tunnel] GATEWAY_URL required'); process.exit(1); }
if (!T) { console.error('[tunnel] GATEWAY_TOKEN required'); process.exit(1); }

let relayWs = null;
const gateways = new Map();

function openGateway(sid) {
  if (gateways.has(sid)) return;
  const entry = { ws: null, ready: false, queue: [] };
  gateways.set(sid, entry);
  console.log(`[tunnel:${I}] Opening gateway for ${sid.slice(0, 8)}`);

  const ws = new WebSocket(G, { headers: { Origin: O } });
  entry.ws = ws;

  ws.on('open', () => {
    console.log(`[tunnel:${I}] Gateway open for ${sid.slice(0, 8)}`);
    entry.ready = true;
    for (const m of entry.queue) ws.send(m);
    entry.queue = [];
  });

  ws.on('message', (data) => {
    const str = typeof data === 'string' ? data : data.toString();
    if (relayWs && relayWs.readyState === WebSocket.OPEN) {
      relayWs.send(JSON.stringify({ sid, data: str }));
    }
  });

  ws.on('close', () => {
    console.log(`[tunnel:${I}] Gateway closed for ${sid.slice(0, 8)}`);
    gateways.delete(sid);
  });

  ws.on('error', () => {});
}

function closeGateway(sid) {
  const entry = gateways.get(sid);
  if (entry) { entry.ws?.close(); gateways.delete(sid); }
}

function forwardToGateway(sid, data) {
  let entry = gateways.get(sid);
  if (!entry) { openGateway(sid); entry = gateways.get(sid); }
  if (entry.ready) entry.ws.send(data);
  else entry.queue.push(data);
}

function connectRelay() {
  if (relayWs && relayWs.readyState === WebSocket.OPEN) return;
  console.log(`[tunnel:${I}] Connecting to relay...`);

  const url = `${R.replace(/\/+$/, '')}/tunnel?token=${encodeURIComponent(S)}&id=${encodeURIComponent(I)}`;
  relayWs = new WebSocket(url);

  relayWs.on('open', () => {
    console.log(`[tunnel:${I}] ✓ Connected to relay`);
    if (T) {
      relayWs.send(JSON.stringify({
        type: 'register_tokens',
        tokens: T.split(',').map(t => t.trim()).filter(Boolean),
      }));
      console.log(`[tunnel:${I}] Registered token(s) with relay`);
    }
  });

  relayWs.on('message', (raw) => {
    try {
      const envelope = JSON.parse(raw.toString());
      if (envelope.type === 'browser_open') { openGateway(envelope.sid); return; }
      if (envelope.type === 'browser_close') { closeGateway(envelope.sid); return; }
      if (envelope.sid && envelope.data) { forwardToGateway(envelope.sid, envelope.data); return; }
    } catch (e) {
      console.error(`[tunnel:${I}] Parse error:`, e.message);
    }
  });

  relayWs.on('close', (code) => {
    console.log(`[tunnel:${I}] Relay disconnected (${code}). Reconnecting in 3s...`);
    relayWs = null;
    for (const [, entry] of gateways) entry.ws?.close();
    gateways.clear();
    setTimeout(connectRelay, 3000);
  });

  relayWs.on('error', () => {});
}

connectRelay();
setInterval(() => {}, 30000);

process.on('SIGTERM', () => {
  console.log(`[tunnel:${I}] Shutting down...`);
  relayWs?.close();
  for (const [, entry] of gateways) entry.ws?.close();
  process.exit(0);
});
