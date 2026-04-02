#!/usr/bin/env python3
"""
solfiredancer-workload.py — Transaction workload generator for Antithesis testing.

Generates and submits SOL transfer transactions at a configurable TPS rate
to stress the Firedancer validator cluster.  Designed to be called repeatedly
by the workload entrypoint script with different parameters per phase.

Modes:
  transfer  — Simple SOL transfers between pre-funded accounts
"""

import argparse
import json
import logging
import math
import os
import random
import socket
import struct
import sys
import time
import threading
from typing import List, Optional

import requests
from solders.keypair import Keypair
from solders.hash import Hash
from solders.pubkey import Pubkey
from solders.system_program import TransferParams, transfer
from solders.compute_budget import set_compute_unit_limit, set_compute_unit_price
from solana.transaction import Transaction

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("solfiredancer-workload")


# =============================================================================
# RPC helpers
# =============================================================================

def rpc_call(rpc_url: str, method: str, params: list = None, retries: int = 3):
    """Make a JSON-RPC call with retries."""
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": method,
        "params": params or [],
    }
    for attempt in range(retries):
        try:
            resp = requests.post(
                rpc_url,
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=30,
            )
            result = resp.json()
            if "error" in result:
                log.warning("RPC error: %s", result["error"])
                time.sleep(1)
                continue
            return result.get("result")
        except Exception as e:
            log.warning("RPC call failed (attempt %d): %s", attempt + 1, e)
            time.sleep(1)
    return None


def get_recent_blockhash(rpc_url: str) -> Optional[Hash]:
    """Fetch the latest blockhash."""
    result = rpc_call(rpc_url, "getLatestBlockhash", [{"commitment": "processed"}])
    if result and "value" in result:
        return Hash.from_string(result["value"]["blockhash"])
    return None


def get_balance(rpc_url: str, pubkey: Pubkey) -> int:
    """Get balance for an account."""
    result = rpc_call(rpc_url, "getBalance", [str(pubkey), {"commitment": "confirmed"}])
    if result and "value" in result:
        return result["value"]
    return 0


def send_transaction_rpc(rpc_url: str, txn_bytes: bytes):
    """Submit a signed transaction via RPC."""
    import base64
    encoded = base64.b64encode(txn_bytes).decode("ascii")
    rpc_call(rpc_url, "sendTransaction", [encoded, {"encoding": "base64"}])


# =============================================================================
# Account management
# =============================================================================

def derive_accounts(faucet_seed: bytes, num_accounts: int) -> List[Keypair]:
    """Derive deterministic keypairs from the faucet seed."""
    accounts = []
    for i in range(num_accounts):
        # Use derivation path to generate unique keypairs
        seed = Keypair.from_seed_and_derivation_path(
            faucet_seed, f"m/44'/45'/30'/{i}'"
        )
        accounts.append(seed)
    return accounts


def fund_accounts(
    rpc_url: str,
    faucet: Keypair,
    accounts: List[Keypair],
    amount_lamports: int = 1_000_000_000,  # 1 SOL each
    batch_size: int = 10,
):
    """Fund accounts from the faucet, skipping already-funded ones."""
    blockhash = get_recent_blockhash(rpc_url)
    if blockhash is None:
        log.error("Cannot get blockhash for funding")
        return

    funded = 0
    for i in range(0, len(accounts), batch_size):
        batch = accounts[i : i + batch_size]
        for acct in batch:
            balance = get_balance(rpc_url, acct.pubkey())
            if balance >= amount_lamports // 2:
                funded += 1
                continue

            txn = Transaction()
            txn.add(
                transfer(
                    TransferParams(
                        from_pubkey=faucet.pubkey(),
                        to_pubkey=acct.pubkey(),
                        lamports=amount_lamports,
                    )
                )
            )
            txn.recent_blockhash = blockhash
            txn.sign(faucet)
            try:
                send_transaction_rpc(rpc_url, bytes(txn.serialize()))
                funded += 1
            except Exception as e:
                log.warning("Failed to fund account %s: %s", acct.pubkey(), e)

        # Refresh blockhash periodically
        if i % (batch_size * 5) == 0 and i > 0:
            new_bh = get_recent_blockhash(rpc_url)
            if new_bh:
                blockhash = new_bh

    log.info("Funded %d / %d accounts", funded, len(accounts))


# =============================================================================
# Transaction generation
# =============================================================================

def generate_transfer_txn(
    sender: Keypair,
    receiver_pubkey: Pubkey,
    blockhash: Hash,
    lamports: int = 1000,
    compute_units: int = 0,
) -> bytes:
    """Create a signed SOL transfer transaction."""
    txn = Transaction()

    if compute_units > 0:
        txn.add(set_compute_unit_limit(compute_units))
        txn.add(set_compute_unit_price(1))

    txn.add(
        transfer(
            TransferParams(
                from_pubkey=sender.pubkey(),
                to_pubkey=receiver_pubkey,
                lamports=lamports,
            )
        )
    )

    txn.recent_blockhash = blockhash
    txn.sign(sender)
    return bytes(txn.serialize())


# =============================================================================
# Blockhash refresh thread
# =============================================================================

class BlockhashRefresher:
    """Background thread that keeps the blockhash fresh."""

    def __init__(self, rpc_url: str, interval: float = 2.0):
        self.rpc_url = rpc_url
        self.interval = interval
        self.blockhash: Optional[Hash] = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.blockhash = get_recent_blockhash(self.rpc_url)
        self._thread.start()

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=5)

    def _run(self):
        while not self._stop.is_set():
            try:
                bh = get_recent_blockhash(self.rpc_url)
                if bh:
                    self.blockhash = bh
            except Exception:
                pass
            self._stop.wait(self.interval)


# =============================================================================
# Main workload loop
# =============================================================================

def run_transfer_workload(
    rpc_url: str,
    faucet: Keypair,
    tps: int,
    num_accounts: int,
    duration_seconds: int,
    compute_units: int = 0,
):
    """Run the transfer workload at the target TPS for the given duration."""
    log.info(
        "Starting transfer workload: tps=%d accounts=%d duration=%ds compute_units=%d",
        tps, num_accounts, duration_seconds, compute_units,
    )

    # Derive and fund accounts
    faucet_seed = bytes(faucet)
    log.info("Deriving %d accounts...", min(num_accounts, 500))
    # Cap actual derived accounts to keep memory reasonable
    actual_accounts = min(num_accounts, 500)
    accounts = derive_accounts(faucet_seed, actual_accounts)

    log.info("Funding accounts...")
    fund_accounts(rpc_url, faucet, accounts, amount_lamports=5_000_000_000)

    # Wait for funding to confirm
    time.sleep(5)

    # Start blockhash refresher
    bh_refresher = BlockhashRefresher(rpc_url)
    bh_refresher.start()

    if bh_refresher.blockhash is None:
        log.error("Cannot get initial blockhash — aborting")
        return

    # Calculate send interval
    interval = 1.0 / tps if tps > 0 else 1.0
    txn_count = 0
    error_count = 0
    start_time = time.monotonic()
    end_time = start_time + duration_seconds

    log.info("Sending transactions at %d TPS...", tps)

    while time.monotonic() < end_time:
        loop_start = time.monotonic()

        # Pick random sender and receiver
        sender_idx = random.randint(0, len(accounts) - 1)
        receiver_idx = random.randint(0, len(accounts) - 2)
        if receiver_idx >= sender_idx:
            receiver_idx += 1

        sender = accounts[sender_idx]
        receiver = accounts[receiver_idx]

        blockhash = bh_refresher.blockhash
        if blockhash is None:
            time.sleep(0.1)
            continue

        try:
            txn_bytes = generate_transfer_txn(
                sender=sender,
                receiver_pubkey=receiver.pubkey(),
                blockhash=blockhash,
                lamports=1000,
                compute_units=compute_units,
            )
            send_transaction_rpc(rpc_url, txn_bytes)
            txn_count += 1
        except Exception as e:
            error_count += 1
            if error_count % 100 == 1:
                log.warning("Transaction send error (%d total): %s", error_count, e)

        # Pace to target TPS
        elapsed = time.monotonic() - loop_start
        if elapsed < interval:
            time.sleep(interval - elapsed)

        # Log progress every 10 seconds
        if txn_count > 0 and txn_count % (tps * 10) == 0:
            wall = time.monotonic() - start_time
            actual_tps = txn_count / wall if wall > 0 else 0
            log.info(
                "Progress: %d txns sent, %.0f actual TPS, %d errors, %.0fs elapsed",
                txn_count, actual_tps, error_count, wall,
            )

    bh_refresher.stop()

    wall = time.monotonic() - start_time
    actual_tps = txn_count / wall if wall > 0 else 0
    log.info(
        "Workload complete: %d txns in %.1fs (%.0f TPS), %d errors",
        txn_count, wall, actual_tps, error_count,
    )


# =============================================================================
# CLI
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser(description="solfiredancer workload generator")
    parser.add_argument("--rpc", required=True, help="RPC endpoint URL")
    parser.add_argument("--faucet-keypair", required=True, help="Path to faucet keypair JSON")
    parser.add_argument("--mode", default="transfer", choices=["transfer"], help="Workload mode")
    parser.add_argument("--tps", type=int, default=1000, help="Target transactions per second")
    parser.add_argument("--num-accounts", type=int, default=1000, help="Number of accounts to use")
    parser.add_argument("--duration", type=int, default=60, help="Duration in seconds")
    parser.add_argument("--compute-units", type=int, default=0, help="Compute unit limit per txn (0=default)")
    return parser.parse_args()


def main():
    args = parse_args()

    # Load faucet keypair
    with open(args.faucet_keypair, "r") as f:
        faucet_bytes = bytes(json.load(f))
    faucet = Keypair.from_bytes(faucet_bytes)
    log.info("Faucet pubkey: %s", faucet.pubkey())

    if args.mode == "transfer":
        run_transfer_workload(
            rpc_url=args.rpc,
            faucet=faucet,
            tps=args.tps,
            num_accounts=args.num_accounts,
            duration_seconds=args.duration,
            compute_units=args.compute_units,
        )


if __name__ == "__main__":
    main()
