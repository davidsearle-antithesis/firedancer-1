#!/bin/bash
# =============================================================================
# solfiredancer — Workload generator entrypoint
#
# Cycles through multiple stress scenarios designed to expose timing,
# coordination, and state-consistency bugs in Firedancer validators.
#
# Each phase targets a different failure mode:
#   Phase 0: High-frequency SOL transfers       (PoH pacing, pack, bank)
#   Phase 1: Account creation storm              (account DB / funk pressure)
#   Phase 2: Hot-account contention              (write-lock contention)
#   Phase 3: Burst-pause pattern                 (queue overflow / drain races)
#   Phase 4: Cross-validator submission          (gossip forwarding, dedup)
#   Phase 5: Compute-heavy transactions          (execution timeout pressure)
# =============================================================================
set -euo pipefail

BOOTSTRAP_RPC="${BOOTSTRAP_RPC:?BOOTSTRAP_RPC is required}"
RPC_ENDPOINTS="${RPC_ENDPOINTS:-$BOOTSTRAP_RPC}"
TPU_ENDPOINTS="${TPU_ENDPOINTS:-}"
TARGET_TPS="${TARGET_TPS:-5000}"
WARMUP_SECONDS="${WARMUP_SECONDS:-120}"
PHASE_DURATION_SECONDS="${PHASE_DURATION_SECONDS:-120}"

echo "=== solfiredancer workload generator ==="
echo "Bootstrap RPC: $BOOTSTRAP_RPC"
echo "Target TPS:    $TARGET_TPS"

# ---- Wait for genesis and bootstrap ----
echo "Waiting for genesis..."
while [ ! -f /genesis/ready ]; do sleep 1; done

echo "Waiting for bootstrap RPC to become healthy..."
until curl -sf "$BOOTSTRAP_RPC" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
  | grep -q '"ok"'; do
  sleep 2
done

# ---- Wait for validators to be voting (cluster liveness) ----
echo "Waiting for cluster to have voting validators..."
while true; do
  VOTE_ACCOUNTS=$(curl -sf "$BOOTSTRAP_RPC" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getVoteAccounts"}' \
    | jq '.result.current | length' 2>/dev/null || echo "0")
  if [ "$VOTE_ACCOUNTS" -ge 3 ] 2>/dev/null; then
    echo "Cluster has $VOTE_ACCOUNTS active vote accounts — proceeding"
    break
  fi
  echo "Waiting for validators to vote (currently $VOTE_ACCOUNTS)..."
  sleep 5
done

# ---- Warmup: let the cluster reach steady state ----
echo "Warmup: waiting ${WARMUP_SECONDS}s for cluster steady state..."
sleep "$WARMUP_SECONDS"

# ---- Signal Antithesis that setup is complete ----
# If the Antithesis SDK notifier is available, signal setup_complete
if [ -f /opt/antithesis/notify ]; then
  /opt/antithesis/notify setup_complete
fi
echo "=== ANTITHESIS SETUP COMPLETE — beginning workload ==="

# ---- Run workload phases in an infinite loop ----
PHASE=0
IFS=',' read -ra RPC_ARRAY <<< "$RPC_ENDPOINTS"
IFS=',' read -ra TPU_ARRAY <<< "$TPU_ENDPOINTS"

# Pick a random RPC endpoint for this phase
pick_rpc() {
  echo "${RPC_ARRAY[$((RANDOM % ${#RPC_ARRAY[@]}))]}"
}

while true; do
  SCENARIO=$((PHASE % 6))
  RPC=$(pick_rpc)
  echo ""
  echo "=========================================="
  echo "Phase $PHASE — Scenario $SCENARIO"
  echo "RPC: $RPC  Duration: ${PHASE_DURATION_SECONDS}s"
  echo "=========================================="

  case $SCENARIO in
    0)
      # --- High-frequency SOL transfers ---
      # Stresses: pack tile pacing, PoH slot boundaries, bank execution
      echo ">> SOL transfers at ${TARGET_TPS} TPS"
      python3 /workload/solfiredancer-workload.py \
        --rpc "$RPC" \
        --faucet-keypair /genesis/keys/faucet-keypair.json \
        --mode transfer \
        --tps "$TARGET_TPS" \
        --num-accounts 10000 \
        --duration "$PHASE_DURATION_SECONDS" \
        || echo "WARN: phase $PHASE exited non-zero"
      ;;

    1)
      # --- Account creation storm ---
      # Stresses: account DB (funk), snapshot generation, state hashing
      echo ">> Account creation storm at 2000 TPS"
      python3 /workload/solfiredancer-workload.py \
        --rpc "$RPC" \
        --faucet-keypair /genesis/keys/faucet-keypair.json \
        --mode transfer \
        --tps 2000 \
        --num-accounts 100000 \
        --duration "$PHASE_DURATION_SECONDS" \
        || echo "WARN: phase $PHASE exited non-zero"
      ;;

    2)
      # --- Hot-account contention ---
      # Stresses: write-lock scheduling, bank parallelism limits
      echo ">> Hot-account contention (10 accounts, 3000 TPS)"
      python3 /workload/solfiredancer-workload.py \
        --rpc "$RPC" \
        --faucet-keypair /genesis/keys/faucet-keypair.json \
        --mode transfer \
        --tps 3000 \
        --num-accounts 10 \
        --duration "$PHASE_DURATION_SECONDS" \
        || echo "WARN: phase $PHASE exited non-zero"
      ;;

    3)
      # --- Burst-pause pattern ---
      # Stresses: queue overflow/drain, pack buffer management, PoH catchup
      echo ">> Burst-pause: 10x TPS for 10s, then 10s pause"
      BURST_TPS=$((TARGET_TPS * 10))
      BURSTS=$((PHASE_DURATION_SECONDS / 20))
      for i in $(seq 1 "$BURSTS"); do
        echo "  Burst $i/$BURSTS at ${BURST_TPS} TPS"
        python3 /workload/solfiredancer-workload.py \
          --rpc "$RPC" \
          --faucet-keypair /genesis/keys/faucet-keypair.json \
          --mode transfer \
          --tps "$BURST_TPS" \
          --num-accounts 5000 \
          --duration 10 \
          || true
        echo "  Pausing 10s..."
        sleep 10
      done
      ;;

    4)
      # --- Cross-validator submission ---
      # Stresses: gossip forwarding, transaction dedup, shred propagation
      # Send transactions to different validators round-robin
      echo ">> Cross-validator round-robin at ${TARGET_TPS} TPS"
      for rpc_endpoint in "${RPC_ARRAY[@]}"; do
        echo "  Submitting to $rpc_endpoint"
        python3 /workload/solfiredancer-workload.py \
          --rpc "$rpc_endpoint" \
          --faucet-keypair /genesis/keys/faucet-keypair.json \
          --mode transfer \
          --tps "$((TARGET_TPS / ${#RPC_ARRAY[@]}))" \
          --num-accounts 5000 \
          --duration "$((PHASE_DURATION_SECONDS / ${#RPC_ARRAY[@]}))" \
          || true
      done
      ;;

    5)
      # --- Compute-heavy transactions ---
      # Stresses: execution tile deadlines, replay timeout, CU metering
      echo ">> Compute-heavy transfers at 4000 TPS"
      python3 /workload/solfiredancer-workload.py \
        --rpc "$RPC" \
        --faucet-keypair /genesis/keys/faucet-keypair.json \
        --mode transfer \
        --tps 4000 \
        --num-accounts 50000 \
        --compute-units 200000 \
        --duration "$PHASE_DURATION_SECONDS" \
        || echo "WARN: phase $PHASE exited non-zero"
      ;;
  esac

  PHASE=$((PHASE + 1))
done
