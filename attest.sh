#!/usr/bin/env bash
# attest.sh
#
# Generates fresh random keypairs, creates an attestation, submits both
# signatures, and sets block extraData — every run is unique.
#
# Prerequisites: foundry (forge + cast), python3, running Geth --dev node
#
# Required env vars (printed by setup-geth.sh):
#   RPC_URL      - Geth JSON-RPC endpoint
#   DEV_ACCOUNT  - Geth auto-created dev account (unlocked, funds new wallets)
#   ISSUER       - deployed ShinzoChallengeIssuerV1 address
#
# Optional:
#   CONSENSUS_PUBKEY    - hex consensus pubkey bytes (default: secp256k1 G point)
#   SKIP_RELAYER_CHECK  - set to 1 to skip the forge RelayerFromExtraData check

set -euo pipefail

BOLD="\033[1m"; CYAN="\033[36m"; GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; RESET="\033[0m"
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
ok()     { echo -e "${GREEN}✔ $*${RESET}"; }
info()   { echo -e "${YELLOW}  $*${RESET}"; }
err()    { echo -e "${RED}✘ $*${RESET}" >&2; }

for var in RPC_URL DEV_ACCOUNT ISSUER; do
  if [ -z "${!var:-}" ]; then
    err "Missing required env var: $var"
    echo "Run setup-geth.sh first — it prints the full command." >&2
    exit 1
  fi
done

# secp256k1 generator point G (compressed, 33 bytes) — valid default consensus key.
CONSENSUS_PUBKEY="${CONSENSUS_PUBKEY:-0x0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798}"
SKIP_RELAYER_CHECK="${SKIP_RELAYER_CHECK:-0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── 1. generate fresh random keypairs ─────────────────────────────────────────
header "Generating fresh keypairs"

new_wallet() {
  local out
  out=$(cast wallet new 2>&1)
  local addr pk
  addr=$(echo "$out" | grep -i "^Address:"     | awk '{print $NF}')
  pk=$(echo "$out"   | grep -i "^Private key:" | awk '{print $NF}')
  echo "$addr $pk"
}

read -r WITHDRAWAL_ADDR WITHDRAWAL_PK <<< "$(new_wallet)"
read -r DELEGATE_ADDR   DELEGATE_PK   <<< "$(new_wallet)"

# DELEGATE_KEY (bytes32): delegate EVM address zero-padded to 32 bytes.
DELEGATE_KEY="0x000000000000000000000000${DELEGATE_ADDR#0x}"

ok "Withdrawal : $WITHDRAWAL_ADDR"
ok "Delegate   : $DELEGATE_ADDR"
ok "DelegateKey: $DELEGATE_KEY"

# ── 2. fund from the dev account ──────────────────────────────────────────────
header "Funding accounts"

cast send \
  --rpc-url "$RPC_URL" \
  --unlocked \
  --from "$DEV_ACCOUNT" \
  "$WITHDRAWAL_ADDR" \
  --value 10ether > /dev/null
ok "Funded $WITHDRAWAL_ADDR with 10 ETH"

cast send \
  --rpc-url "$RPC_URL" \
  --unlocked \
  --from "$DEV_ACCOUNT" \
  "$DELEGATE_ADDR" \
  --value 1ether > /dev/null
ok "Funded $DELEGATE_ADDR with 1 ETH"

# ── 3. create attestation ─────────────────────────────────────────────────────
header "Creating attestation"

CREATE_OUT=$(ISSUER="$ISSUER" \
  CONSENSUS_PUBKEY="$CONSENSUS_PUBKEY" \
  DELEGATE_KEY="$DELEGATE_KEY" \
  forge script script/CreateAttestation.s.sol \
    --rpc-url "$RPC_URL" \
    --private-key "$WITHDRAWAL_PK" \
    --broadcast 2>&1)
echo "$CREATE_OUT"

ATTESTATION_ID=$(echo "$CREATE_OUT" | grep -E "Attestation ID:" | awk '{print $NF}')
[ -z "$ATTESTATION_ID" ] && { err "Could not parse ATTESTATION_ID"; exit 1; }
ok "ATTESTATION_ID = $ATTESTATION_ID"

# ── 4. submit withdrawal + delegate signatures ────────────────────────────────
header "Submitting signatures"

SUBMIT_OUT=$(ISSUER="$ISSUER" \
  ATTESTATION_ID="$ATTESTATION_ID" \
  WITHDRAWAL_PK="$WITHDRAWAL_PK" \
  DELEGATE_PK="$DELEGATE_PK" \
  forge script script/SubmitAttestationSignature.s.sol \
    --rpc-url "$RPC_URL" \
    --private-key "$WITHDRAWAL_PK" \
    --broadcast 2>&1)
echo "$SUBMIT_OUT"

EXTRADATA_STR=$(echo "$SUBMIT_OUT" | grep -E "SH[0-9a-f]{30}" | tr -d ' ' | head -1)
[ -z "$EXTRADATA_STR" ] && { err "Could not parse ExtraData string from submit output"; exit 1; }
ok "ExtraData string = $EXTRADATA_STR"

EXTRADATA_HEX=$(python3 - <<EOF
s = "$EXTRADATA_STR"
b = s.encode("ascii")
padded = b + b"\x00" * (32 - len(b))
print("0x" + padded.hex())
EOF
)
ok "ExtraData hex    = $EXTRADATA_HEX"

# ── 5. set miner extraData ────────────────────────────────────────────────────
# miner_setExtra expects the plain ASCII string, not hex bytes.
header "Setting miner extraData"

cast rpc miner_setExtra "$EXTRADATA_STR" --rpc-url "$RPC_URL"
ok "miner_setExtra accepted"

# ── 6. mine a block ───────────────────────────────────────────────────────────
header "Mining a block"

cast send \
  --rpc-url "$RPC_URL" \
  --unlocked \
  --from "$DEV_ACCOUNT" \
  "$DEV_ACCOUNT" \
  --value 1wei > /dev/null
ok "Block mined"

# ── 7. verify block.extraData ─────────────────────────────────────────────────
header "Verifying block.extraData"

BLOCK_EXTRA=$(curl -s -X POST "$RPC_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['result']['extraData'])")

ok "block.extraData = $BLOCK_EXTRA"

if [[ "$BLOCK_EXTRA" == 0x5348* ]]; then
  ok "Tag 'SH' confirmed in block extraData"
else
  err "Unexpected extraData — expected 0x5348... prefix"
fi

# ── 8. relayer simulation (optional) ─────────────────────────────────────────
if [ "$SKIP_RELAYER_CHECK" != "1" ]; then
  header "Relayer simulation (RelayerFromExtraData)"
  ISSUER="$ISSUER" \
  EXTRA_DATA="$EXTRADATA_HEX" \
  forge script script/RelayerFromExtraData.s.sol \
    --rpc-url "$RPC_URL"
fi

# ── summary ───────────────────────────────────────────────────────────────────
header "Done"
info "ATTESTATION_ID  = $ATTESTATION_ID"
info "Withdrawal addr = $WITHDRAWAL_ADDR"
info "Delegate   addr = $DELEGATE_ADDR"
info "ExtraData str   = $EXTRADATA_STR"
info "ExtraData hex   = $EXTRADATA_HEX"
info "block.extraData = $BLOCK_EXTRA"
echo ""
ok "Relayer should pick this up on the next scan."
