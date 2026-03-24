#!/usr/bin/env bash
# Corgi Tunnel — automated setup script
# Usage: setup.sh <tunnel_id> <gateway_port> <gateway_token>
set -euo pipefail

TUNNEL_ID="${1:?Usage: setup.sh <tunnel_id> <gateway_port> <gateway_token>}"
GATEWAY_PORT="${2:?Usage: setup.sh <tunnel_id> <gateway_port> <gateway_token>}"
GATEWAY_TOKEN="${3:?Usage: setup.sh <tunnel_id> <gateway_port> <gateway_token>}"

RELAY_URL="wss://relay-production-62fa.up.railway.app"
TUNNEL_SECRET="corgi-tunnel-2026"
DASHBOARD_ORIGIN="https://dashboard-production-3553.up.railway.app"

DIR="$HOME/corgi-tunnel/client"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[setup] Creating $DIR..."
mkdir -p "$DIR"

# Copy tunnel client from skill
cp "$SKILL_DIR/tunnel-client.js" "$DIR/client.js"

# Install ws if needed
cd "$DIR"
if [ ! -d "node_modules/ws" ]; then
  echo "[setup] Installing ws..."
  npm init -y > /dev/null 2>&1 || true
  npm install ws > /dev/null 2>&1
fi

# Write .env (token stays on disk, never displayed)
cat > "$DIR/.env" << EOF
RELAY_URL=${RELAY_URL}
GATEWAY_URL=ws://127.0.0.3:${GATEWAY_PORT}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
TUNNEL_SECRET=${TUNNEL_SECRET}
TUNNEL_ID=${TUNNEL_ID}
DASHBOARD_ORIGIN=${DASHBOARD_ORIGIN}
EOF

# Write watchdog
cat > "$DIR/watchdog.sh" << 'WATCHDOG'
#!/usr/bin/env bash
cd "$(dirname "$0")" && source .env
export RELAY_URL GATEWAY_URL GATEWAY_TOKEN TUNNEL_SECRET TUNNEL_ID DASHBOARD_ORIGIN
while true; do
  node client.js 2>&1
  echo "[watchdog] Restarting in 3s... ($(date))"
  sleep 3
done
WATCHDOG
chmod +x "$DIR/watchdog.sh"

echo "[setup] ✓ Tunnel configured at $DIR"
echo "[setup] Starting tunnel..."

# Kill any existing tunnel
pkill -f "corgi-tunnel.*client.js" 2>/dev/null || true
sleep 1

# Start watchdog
nohup "$DIR/watchdog.sh" > /tmp/tunnel-client.log 2>&1 &
echo "[setup] ✓ Tunnel running (PID: $!)"

# Verify
sleep 4
HEALTH=$(curl -s "https://relay-production-62fa.up.railway.app/health" 2>/dev/null)
if echo "$HEALTH" | grep -q "\"$TUNNEL_ID\""; then
  echo "[setup] ✓ Tunnel '$TUNNEL_ID' visible on relay"
  echo "[setup]"
  echo "[setup] Dashboard: https://dashboard-production-3553.up.railway.app"
  echo "[setup] Gateway port: $GATEWAY_PORT"
  echo "[setup] Tunnel ID: $TUNNEL_ID"
else
  echo "[setup] ⚠ Tunnel not yet visible on relay. Check /tmp/tunnel-client.log"
fi
