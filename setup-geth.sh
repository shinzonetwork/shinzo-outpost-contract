#!/usr/bin/env bash
# setup-geth.sh
#
# One-time setup: starts a Geth --dev Docker container and deploys
# ShinzoChallengeIssuerV1. Prints the exact command to run attest.sh.
#
# Geth is left running after this script exits.
#
# Prerequisites: docker, foundry (forge + cast), python3
#
# Usage:
#   ./setup-geth.sh
#
# Overrideable env vars:
#   RPC_URL      default: http://127.0.0.1:8545
#   GETH_IMAGE   default: ethereum/client-go:v1.13.15

set -euo pipefail

BOLD="\033[1m"; CYAN="\033[36m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
ok()     { echo -e "${GREEN}✔ $*${RESET}"; }
info()   { echo -e "${YELLOW}  $*${RESET}"; }
err()    { echo -e "${RED}✘ $*${RESET}" >&2; }

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
GETH_IMAGE="${GETH_IMAGE:-ethereum/client-go:v1.13.15}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── 1. start Geth ─────────────────────────────────────────────────────────────
header "Starting Geth dev node ($GETH_IMAGE)"

GETH_CID=$(docker run -d \
  -p 8545:8545 \
  "$GETH_IMAGE" \
  --http \
  --http.addr 0.0.0.0 \
  --http.port 8545 \
  --http.api eth,net,web3,personal,txpool,miner \
  --allow-insecure-unlock \
  --dev \
  --verbosity 1)

ok "Container ID: $GETH_CID"

for i in $(seq 1 30); do
  if curl -sf -X POST "$RPC_URL" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      > /dev/null 2>&1; then
    ok "Geth is up"
    break
  fi
  [ "$i" -eq 30 ] && { err "Geth did not respond after 30s"; docker logs "$GETH_CID" >&2; exit 1; }
  sleep 1
done

# ── 2. discover the auto-created dev account ───────────────────────────────────
header "Querying Geth dev account"

DEV_ACCOUNT=$(curl -s -X POST "$RPC_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_accounts","params":[],"id":1}' \
  | python3 -c "
import sys, json
accounts = json.load(sys.stdin).get('result', [])
if not accounts:
    print('ERROR: no accounts returned', file=sys.stderr)
    sys.exit(1)
print(accounts[0])
")

ok "Dev account: $DEV_ACCOUNT (pre-funded, unlocked)"

# ── 3. deploy ShinzoChallengeIssuerV1 ─────────────────────────────────────────
# Deploy from the unlocked dev account — no private key needed.
header "Deploying ShinzoChallengeIssuerV1"

DEPLOY_OUT=$(forge script script/DeployChallengeIssuer.s.sol \
  --rpc-url "$RPC_URL" \
  --sender "$DEV_ACCOUNT" \
  --unlocked \
  --broadcast 2>&1)
echo "$DEPLOY_OUT"

ISSUER=$(echo "$DEPLOY_OUT" | grep -E "deployed at:" | awk '{print $NF}')
[ -z "$ISSUER" ] && { err "Could not parse ISSUER address from deploy output"; exit 1; }
ok "ISSUER = $ISSUER"

# ── summary ───────────────────────────────────────────────────────────────────
header "Setup complete"
info "Geth container : $GETH_CID"
info "RPC            : $RPC_URL"
info "Dev account    : $DEV_ACCOUNT"
info "ISSUER         : $ISSUER"
echo ""
echo -e "${BOLD}Run this to create an attestation (call as many times as you like):${RESET}"
echo ""
echo "  RPC_URL=$RPC_URL \\"
echo "  DEV_ACCOUNT=$DEV_ACCOUNT \\"
echo "  ISSUER=$ISSUER \\"
echo "  $REPO_ROOT/attest.sh"
echo ""
echo -e "${YELLOW}  Stop Geth when done:  docker stop $GETH_CID${RESET} \n`"
