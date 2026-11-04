#!/usr/bin/env bash
# Runs real releases against the server under steady traffic and records what users would have seen.
# Usage, from the ansible directory: ../scripts/run_release_scenarios.sh
set -u

HOST=$(sed -n 2p inventory.ini | cut -d' ' -f1)
PROBE_SECONDS="${PROBE_SECONDS:-100}"
SSH_OPTS="-i $HOME/.ssh/shop-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
WORK=$(mktemp -d)

remote() { ssh $SSH_OPTS "ubuntu@$HOST" "$1"; }

live_release() {
  curl --silent --max-time 5 "http://$HOST/health" || echo "no response"
  echo
}

# Arguments: title, the deploy.sh arguments, and the exit status this scenario should produce.
scenario() {
  local title=$1 command=$2 expected=$3 status
  echo
  echo "=================================================="
  echo "SCENARIO: $title"
  echo "command: deploy.sh $command   (expected exit: $expected)"
  echo "before: $(live_release)"

  remote "python3 /opt/shop/scripts/probe.py --seconds $PROBE_SECONDS --rate 20" > "$WORK/server.json" &
  local server_probe=$!
  python3 "$(dirname "$0")/probe.py" --url "http://$HOST/api/products" --seconds "$PROBE_SECONDS" --rate 5 > "$WORK/laptop.json" &
  local laptop_probe=$!

  remote "sudo /opt/shop/scripts/deploy.sh $command 2>&1" | grep -E '^\[deploy\]|Smoke test|FAILED'
  status=${PIPESTATUS[0]}
  wait "$server_probe" "$laptop_probe"

  echo "deploy exit: $status"
  if [ "$status" -eq "$expected" ]; then echo "result: AS EXPECTED"; else echo "result: UNEXPECTED"; fi
  echo "after: $(live_release)"
  echo "--- traffic from inside the server (20 requests per second)"
  cat "$WORK/server.json"
  echo "--- traffic from the laptop over the internet (5 requests per second)"
  cat "$WORK/laptop.json"
}

echo "Release scenarios against $HOST, started $(date -u +%FT%TZ)"
scenario "good release" "deploy v1.1.0" 0
scenario "bad release: unhealthy from the start" "deploy v1.2.0-bad-unhealthy unhealthy" 1
scenario "bad release: fails only after it goes live" "deploy v1.3.0-bad-late late" 1
scenario "manual rollback" "rollback" 0
scenario "good release after the failures" "deploy v1.4.0" 0

echo
echo "=================================================="
echo "FINAL STATE"
remote "sudo /opt/shop/scripts/deploy.sh status"
echo "--- deploy history"
remote "sudo tail -30 /opt/shop/deploy-history.log"
rm -rf "$WORK"
