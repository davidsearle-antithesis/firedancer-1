#!/bin/bash
# =============================================================================
# solfiredancer — Firedancer validator entrypoint
#
# Waits for genesis, generates identity keys, funds & stakes itself on-chain,
# downloads a snapshot from the bootstrap validator, and starts firedancer-dev.
# =============================================================================
set -euxo pipefail

VALIDATOR_ID="${VALIDATOR_ID:?VALIDATOR_ID is required}"
BOOTSTRAP_GOSSIP="${BOOTSTRAP_GOSSIP:?BOOTSTRAP_GOSSIP is required}"
BOOTSTRAP_RPC="${BOOTSTRAP_RPC:?BOOTSTRAP_RPC is required}"
STAKE_LAMPORTS="${STAKE_LAMPORTS:-1000000000000000}"

# Tile counts (container-sized defaults)
VERIFY_TILE_COUNT="${VERIFY_TILE_COUNT:-4}"
EXECLE_TILE_COUNT="${EXECLE_TILE_COUNT:-2}"
EXECRP_TILE_COUNT="${EXECRP_TILE_COUNT:-4}"
BANK_TILE_COUNT="${BANK_TILE_COUNT:-2}"
SHRED_TILE_COUNT="${SHRED_TILE_COUNT:-1}"
NET_TILE_COUNT="${NET_TILE_COUNT:-1}"
QUIC_TILE_COUNT="${QUIC_TILE_COUNT:-1}"
RESOLV_TILE_COUNT="${RESOLV_TILE_COUNT:-1}"
GOSSVF_TILE_COUNT="${GOSSVF_TILE_COUNT:-1}"
SIGN_TILE_COUNT="${SIGN_TILE_COUNT:-2}"
SNAPSHOT_HASH_TILE_COUNT="${SNAPSHOT_HASH_TILE_COUNT:-2}"
MAX_ACCOUNTS="${MAX_ACCOUNTS:-10000000}"
FILE_SIZE_GIB="${FILE_SIZE_GIB:-8}"

HASHES_PER_TICK="${HASHES_PER_TICK:-1024}"
TICKS_PER_SLOT="${TICKS_PER_SLOT:-64}"
TARGET_TICK_DURATION_MICROS="${TARGET_TICK_DURATION_MICROS:-6250}"

DATA_DIR="/data/validator-${VALIDATOR_ID}"
KEYS_DIR="/genesis/keys"
mkdir -p "$DATA_DIR"

# ---- Wait for genesis ----
echo "Validator $VALIDATOR_ID: waiting for genesis..."
while [ ! -f /genesis/ready ]; do sleep 1; done
echo "Validator $VALIDATOR_ID: genesis ready"

SHRED_VERSION=$(cat /genesis/shred_version)

# ---- Generate this validator's keypairs ----
solana-keygen new --no-bip39-passphrase --force -o "$DATA_DIR/identity.json"
solana-keygen new --no-bip39-passphrase --force -o "$DATA_DIR/vote.json"
solana-keygen new --no-bip39-passphrase --force -o "$DATA_DIR/stake.json"
solana-keygen new --no-bip39-passphrase --force -o "$DATA_DIR/withdrawer.json"

IDENTITY_PUBKEY=$(solana-keygen pubkey "$DATA_DIR/identity.json")
echo "Validator $VALIDATOR_ID: identity=$IDENTITY_PUBKEY"

# ---- Wait for bootstrap RPC to become healthy ----
echo "Validator $VALIDATOR_ID: waiting for bootstrap RPC..."
until curl -sf "$BOOTSTRAP_RPC" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
  | grep -q '"ok"'; do
  sleep 2
done
echo "Validator $VALIDATOR_ID: bootstrap RPC healthy"

# ---- Wait for sufficient block height to have a snapshot ----
echo "Validator $VALIDATOR_ID: waiting for block height >= 150..."
while true; do
  HEIGHT=$(curl -sf "$BOOTSTRAP_RPC" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getBlockHeight"}' \
    | jq -r '.result // 0' 2>/dev/null || echo "0")
  if [ "$HEIGHT" -ge 150 ] 2>/dev/null; then break; fi
  sleep 2
done
echo "Validator $VALIDATOR_ID: block height=$HEIGHT, proceeding"

# ---- Fund this validator and create vote/stake accounts ----
echo "Validator $VALIDATOR_ID: funding and staking..."

solana -u "$BOOTSTRAP_RPC" --keypair "$KEYS_DIR/faucet-keypair.json" \
    transfer --allow-unfunded-recipient "$DATA_DIR/identity.json" 400000 \
    --commitment confirmed

solana -u "$BOOTSTRAP_RPC" --keypair "$DATA_DIR/identity.json" \
    create-vote-account "$DATA_DIR/vote.json" "$DATA_DIR/identity.json" "$DATA_DIR/withdrawer.json" \
    --commitment confirmed

solana -u "$BOOTSTRAP_RPC" --keypair "$DATA_DIR/identity.json" \
    create-stake-account "$DATA_DIR/stake.json" 300000 \
    --commitment confirmed

solana -u "$BOOTSTRAP_RPC" --keypair "$DATA_DIR/identity.json" \
    delegate-stake "$DATA_DIR/stake.json" "$DATA_DIR/vote.json" \
    --commitment confirmed

echo "Validator $VALIDATOR_ID: staked successfully"

# ---- Download snapshot from bootstrap ----
echo "Validator $VALIDATOR_ID: downloading snapshot..."
cd "$DATA_DIR"

# Retry snapshot download (bootstrap may still be writing it)
for attempt in $(seq 1 30); do
  SNAPSHOT_FILE=$(wget --trust-server-names -q -P "$DATA_DIR" \
    "http://10.0.0.10:8899/snapshot.tar.bz2" 2>&1 | grep -o 'snapshot-[^ ]*' || true)
  if [ -n "$SNAPSHOT_FILE" ] && ls "$DATA_DIR"/snapshot-*.tar.bz2 1>/dev/null 2>&1; then
    SNAPSHOT_FILE=$(ls "$DATA_DIR"/snapshot-*.tar.bz2 | head -1)
    echo "Validator $VALIDATOR_ID: downloaded $SNAPSHOT_FILE"
    break
  fi
  echo "Validator $VALIDATOR_ID: snapshot not yet available (attempt $attempt/30), retrying..."
  sleep 5
done

if ! ls "$DATA_DIR"/snapshot-*.tar.bz2 1>/dev/null 2>&1; then
  echo "ERROR: Failed to download snapshot after 30 attempts"
  exit 1
fi

SNAPSHOT_PATH=$(ls "$DATA_DIR"/snapshot-*.tar.bz2 | head -1)

# ---- Port allocation per validator to avoid collisions ----
BASE_PORT=$((8700 + VALIDATOR_ID * 100))
GOSSIP_PORT=$BASE_PORT
REPAIR_INTAKE_PORT=$((BASE_PORT + 1))
REPAIR_SERVE_PORT=$((BASE_PORT + 2))
RPC_PORT=8123

# ---- Generate Firedancer TOML config ----
cat > "$DATA_DIR/config.toml" <<TOML
name = "fd${VALIDATOR_ID}"
user = "solana"
telemetry = false

[paths]
    base = "${DATA_DIR}/fd-home"
    identity_key = "${DATA_DIR}/identity.json"
    vote_account = "${DATA_DIR}/vote.json"
    genesis = "/genesis/ledger/genesis.bin"

[log]
    path = "${DATA_DIR}/firedancer.log"
    level_logfile = "DEBUG"
    level_stderr = "INFO"
    level_flush = "WARNING"

[gossip]
    entrypoints = ["${BOOTSTRAP_GOSSIP}"]
    port = ${GOSSIP_PORT}

[consensus]
    expected_shred_version = ${SHRED_VERSION}
    wait_for_vote_to_start_leader = false

[accounts]
    max_accounts = ${MAX_ACCOUNTS}
    file_size_gib = ${FILE_SIZE_GIB}

[layout]
    affinity = "auto"
    net_tile_count = ${NET_TILE_COUNT}
    quic_tile_count = ${QUIC_TILE_COUNT}
    resolv_tile_count = ${RESOLV_TILE_COUNT}
    verify_tile_count = ${VERIFY_TILE_COUNT}
    gossvf_tile_count = ${GOSSVF_TILE_COUNT}
    execle_tile_count = ${EXECLE_TILE_COUNT}
    execrp_tile_count = ${EXECRP_TILE_COUNT}
    shred_tile_count = ${SHRED_TILE_COUNT}
    sign_tile_count = ${SIGN_TILE_COUNT}
    snapshot_hash_tile_count = ${SNAPSHOT_HASH_TILE_COUNT}

[net]
    provider = "socket"

    [net.socket]
        receive_buffer_size = 134217728
        send_buffer_size = 134217728

[hugetlbfs]
    max_page_size = "huge"

[snapshots]
    incremental_snapshots = false

[rpc]
    port = ${RPC_PORT}
    full_api = true
    extended_tx_metadata_storage = true

[tiles]
    [tiles.repair]
        repair_intake_listen_port = ${REPAIR_INTAKE_PORT}
        repair_serve_listen_port = ${REPAIR_SERVE_PORT}

    [tiles.replay]
        snapshot = "${SNAPSHOT_PATH}"

    [tiles.gui]
        enabled = false

[development]
    sandbox = false
    no_clone = true

    [development.genesis]
        validate_genesis_hash = false
        hashes_per_tick = ${HASHES_PER_TICK}
        ticks_per_slot = ${TICKS_PER_SLOT}
        target_tick_duration_micros = ${TARGET_TICK_DURATION_MICROS}
TOML

echo "Validator $VALIDATOR_ID: config written to $DATA_DIR/config.toml"

# ---- Configure system (hugepages, etc.) ----
firedancer-dev configure init hugetlbfs --config "$DATA_DIR/config.toml" || true
firedancer-dev configure init keys --config "$DATA_DIR/config.toml" || true

# ---- Start Firedancer ----
echo "Validator $VALIDATOR_ID: starting firedancer-dev..."
exec firedancer-dev dev \
    --no-configure \
    --config "$DATA_DIR/config.toml" \
    --log-path "$DATA_DIR/firedancer.log"
