#!/bin/bash
# =============================================================================
# solfiredancer — Bootstrap validator entrypoint (Agave)
#
# Creates genesis, starts the bootstrap validator, and serves as the gossip
# seed and snapshot source for Firedancer validators joining the cluster.
# =============================================================================
set -euxo pipefail

SLOTS_PER_EPOCH="${SLOTS_PER_EPOCH:-200}"
HASHES_PER_TICK="${HASHES_PER_TICK:-1024}"
TICKS_PER_SLOT="${TICKS_PER_SLOT:-64}"
BOOTSTRAP_STAKE_LAMPORTS="${BOOTSTRAP_STAKE_LAMPORTS:-11000000000000000}"
BOOTSTRAP_VALIDATOR_LAMPORTS="${BOOTSTRAP_VALIDATOR_LAMPORTS:-11000000000000000}"
FAUCET_LAMPORTS="${FAUCET_LAMPORTS:-1000000000000000000}"
ENABLE_WARMUP_EPOCHS="${ENABLE_WARMUP_EPOCHS:-true}"
GOSSIP_HOST="${GOSSIP_HOST:-$(hostname -i)}"

LEDGER_DIR="/genesis/ledger"
KEYS_DIR="/genesis/keys"

# ---- Generate keypairs ----
mkdir -p "$KEYS_DIR" "$LEDGER_DIR"

solana-keygen new --no-bip39-passphrase --force -o "$KEYS_DIR/faucet-keypair.json"
solana-keygen new --no-bip39-passphrase --force -o "$KEYS_DIR/bootstrap-identity.json"
solana-keygen new --no-bip39-passphrase --force -o "$KEYS_DIR/bootstrap-vote.json"
solana-keygen new --no-bip39-passphrase --force -o "$KEYS_DIR/bootstrap-stake.json"

# ---- Fetch SPL programs needed for token operations ----
UPGRADEABLE_LOADER="BPFLoaderUpgradeab1e11111111111111111111111"
GENESIS_ARGS=()

fetch_program() {
  local name=$1 version=$2 address=$3 loader=$4
  local so="spl_${name}-${version}.so"
  local so_name="spl_${name//-/_}.so"

  if [[ "$loader" == "$UPGRADEABLE_LOADER" ]]; then
    GENESIS_ARGS+=(--upgradeable-program "$address" "$loader" "$so" none)
  else
    GENESIS_ARGS+=(--bpf-program "$address" "$loader" "$so")
  fi

  if [[ -r "$so" ]]; then return; fi

  echo "Downloading SPL $name $version ..."
  curl -L --retry 5 --retry-delay 2 --retry-connrefused \
    -o "$so" \
    "https://github.com/solana-labs/solana-program-library/releases/download/${name}-v${version}/${so_name}" \
    || echo "WARN: failed to download $so_name — genesis may lack this program"
}

cd /tmp
fetch_program token 3.5.0 TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA BPFLoader2111111111111111111111111111111111
fetch_program token-2022 1.0.0 TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb "$UPGRADEABLE_LOADER"
fetch_program memo 1.0.0 Memo1UhkJRfHyvLMcVucJwxXeuD728EqVDDwQDxFMNo BPFLoader1111111111111111111111111111111111
fetch_program memo 3.0.0 MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr BPFLoader2111111111111111111111111111111111
fetch_program associated-token-account 1.1.2 ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL BPFLoader2111111111111111111111111111111111

# ---- Create genesis ----
echo "Creating genesis..."
WARMUP_FLAG=""
if [[ "$ENABLE_WARMUP_EPOCHS" == "true" ]]; then
  WARMUP_FLAG="--enable-warmup-epochs"
fi

GENESIS_OUTPUT=$(solana-genesis \
    --cluster-type development \
    --ledger "$LEDGER_DIR" \
    --bootstrap-validator \
        "$KEYS_DIR/bootstrap-identity.json" \
        "$KEYS_DIR/bootstrap-vote.json" \
        "$KEYS_DIR/bootstrap-stake.json" \
    --bootstrap-stake-authorized-pubkey "$KEYS_DIR/bootstrap-identity.json" \
    --bootstrap-validator-lamports "$BOOTSTRAP_VALIDATOR_LAMPORTS" \
    --bootstrap-validator-stake-lamports "$BOOTSTRAP_STAKE_LAMPORTS" \
    --faucet-pubkey "$KEYS_DIR/faucet-keypair.json" \
    --faucet-lamports "$FAUCET_LAMPORTS" \
    --slots-per-epoch "$SLOTS_PER_EPOCH" \
    --hashes-per-tick "$HASHES_PER_TICK" \
    --ticks-per-slot "$TICKS_PER_SLOT" \
    $WARMUP_FLAG \
    "${GENESIS_ARGS[@]}")

echo "$GENESIS_OUTPUT"

# Extract genesis hash and shred version for validators
GENESIS_HASH=$(echo "$GENESIS_OUTPUT" | grep -oP '(?<=Genesis hash:)\s*\S+' | xargs)
SHRED_VERSION=$(echo "$GENESIS_OUTPUT" | grep -oP '(?<=Shred version:)\s*\S+' | xargs)

echo "$GENESIS_HASH" > /genesis/genesis_hash
echo "$SHRED_VERSION" > /genesis/shred_version

# Signal that genesis is ready for validators to read
touch /genesis/ready
echo "Genesis ready — hash=$GENESIS_HASH shred_version=$SHRED_VERSION"

# ---- Start bootstrap Agave validator ----
echo "Starting Agave bootstrap validator..."

exec agave-validator \
    --identity "$KEYS_DIR/bootstrap-identity.json" \
    --ledger "$LEDGER_DIR" \
    --limit-ledger-size 1000000000 \
    --no-genesis-fetch \
    --no-snapshot-fetch \
    --no-poh-speed-test \
    --no-os-network-limits-test \
    --no-wait-for-vote-to-start-leader \
    --no-incremental-snapshots \
    --full-snapshot-interval-slots 100 \
    --maximum-full-snapshots-to-retain 10 \
    --rpc-port 8899 \
    --gossip-port 8001 \
    --gossip-host "$GOSSIP_HOST" \
    --dynamic-port-range 8100-10000 \
    --full-rpc-api \
    --allow-private-addr \
    --rpc-faucet-address "0.0.0.0:9900" \
    --enable-rpc-transaction-history \
    --tpu-enable-udp \
    --log "/genesis/bootstrap-validator.log"
