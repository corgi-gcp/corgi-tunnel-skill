#!/usr/bin/env bash
# Ensure tunnel is running — called by Eragon cron keepalive or system crontab
TUNNEL_DIR="/Users/corgi12/.eragon-joshua_augustine/joshua_augustine_workspace/corgi-tunnel/client"
LOG="/tmp/tunnel-client.log"

# Check if tunnel client.js is already running (match node + client.js but not this script)
if pgrep -f "node.*client\.js" > /dev/null 2>&1; then
  # Verify it's actually connected by checking relay health
  HEALTH=$(curl -s --max-time 5 "https://relay-production-724a.up.railway.app/health" 2>/dev/null)
  if echo "$HEALTH" | grep -q '"josh"'; then
    exit 0  # Running and registered
  fi
  # Running but not registered — kill and restart
  echo "[ensure-running] Tunnel running but not registered on relay — restarting $(date)" >> "$LOG"
  pkill -f "node.*client\.js" 2>/dev/null
  sleep 2
fi

# Not running — start watchdog
cd "$TUNNEL_DIR" || exit 1
source .env
export RELAY_URL GATEWAY_URL GATEWAY_TOKEN TUNNEL_SECRET TUNNEL_ID DASHBOARD_ORIGIN

# Kill any zombie watchdog loops
pkill -f "watchdog\.sh" 2>/dev/null
sleep 1

nohup bash -c "
cd '$TUNNEL_DIR' && source .env
export RELAY_URL GATEWAY_URL GATEWAY_TOKEN TUNNEL_SECRET TUNNEL_ID DASHBOARD_ORIGIN
while true; do
  node client.js >> '$LOG' 2>&1
  echo '[watchdog] Restarting \$(date)' >> '$LOG'
  sleep 3
done
" > /dev/null 2>&1 &

echo "[ensure-running] Started tunnel PID $! at $(date)" >> "$LOG"
