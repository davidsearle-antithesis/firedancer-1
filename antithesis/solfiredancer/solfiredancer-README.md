# solfiredancer — Antithesis Testing for Firedancer

Antithesis test harness for the Firedancer Solana validator. Stands up
a local 8-validator cluster (1 Agave bootstrap + 7 Firedancer) from
genesis, runs workload phases, and validates consensus invariants under
fault injection.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Docker Network: 10.0.0.0/24                  │
│                                                                 │
│  ┌──────────────┐   ┌──────────┐ ┌──────────┐ ┌──────────┐    │
│  │   bootstrap   │   │  fd-val-1 │ │  fd-val-2 │ │  fd-val-3 │  │
│  │   (Agave)     │   │(Firedncr)│ │(Firedncr)│ │(Firedncr)│    │
│  │  10.0.0.10    │   │ 10.0.0.11│ │ 10.0.0.12│ │ 10.0.0.13│    │
│  └──────┬───────┘   └────┬─────┘ └────┬─────┘ └────┬─────┘    │
│         │  gossip+repair  │            │            │           │
│  ┌──────┴───────┐   ┌────┴─────┐ ┌────┴─────┐ ┌────┴─────┐    │
│  │  fd-val-4     │   │  fd-val-5 │ │  fd-val-6 │ │  fd-val-7 │  │
│  │ 10.0.0.14    │   │ 10.0.0.15│ │ 10.0.0.16│ │ 10.0.0.17│    │
│  └──────────────┘   └──────────┘ └──────────┘ └──────────┘    │
│                                                                 │
│         ┌──────────────────┐                                    │
│         │  workload gen     │                                   │
│         │  10.0.0.20        │                                   │
│         └──────────────────┘                                    │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# From the firedancer repo root (requires amd64 / x86_64 host):

# 1. Build images (amd64)
./antithesis/solfiredancer/solfiredancer-build.sh

# 2. Build and push to registry
./antithesis/solfiredancer/solfiredancer-build.sh --push

# 3. Start the cluster
cd antithesis/solfiredancer
podman-compose -f solfiredancer-docker-compose.yml up
```

## NixOS Setup

```bash
# Clone the repo
git clone https://github.com/firedancer-io/firedancer.git
cd firedancer

# Build images natively on amd64
./antithesis/solfiredancer/solfiredancer-build.sh --push

# Or just run the cluster (pulls from registry)
cd antithesis/solfiredancer
podman-compose -f solfiredancer-docker-compose.yml up
```

## Files

| File | Purpose |
|------|---------|
| `solfiredancer-docker-compose.yml` | 8-validator cluster + workload |
| `Dockerfile.firedancer` | Firedancer + Agave tools (x86_64) |
| `Dockerfile.workload` | Python workload generator (x86_64) |
| `solfiredancer-entrypoint-bootstrap.sh` | Genesis creation + Agave bootstrap |
| `solfiredancer-entrypoint-validator.sh` | Firedancer validator join + run |
| `solfiredancer-entrypoint-workload.sh` | Phased stress workload |
| `solfiredancer-build.sh` | Build all images |
| `workload/solfiredancer-workload.py` | Transaction generator |
| `instrumentation/solfiredancer_antithesis.h` | Antithesis C SDK assertion macros |
| `instrumentation/solfiredancer_antithesis_patches.md` | Where to insert assertions |
| `config/solfiredancer-antithesis-properties.json` | Property definitions |
| `config/solfiredancer-validator-template.toml` | Reference TOML config |
| `config/solfiredancer-with-antithesis.mk` | Build extra for Antithesis SDK |

## Cluster Configuration

| Parameter | Value | Notes |
|-----------|-------|-------|
| Validators | 1 Agave + 7 Firedancer | 8 total for BFT threshold |
| `hashes_per_tick` | 1,024 | 61x faster than mainnet (62,500) |
| `ticks_per_slot` | 64 | Same as mainnet |
| `slots_per_epoch` | 200 | ~1.3s epochs (vs 2 days mainnet) |
| `warmup_epochs` | enabled | Fast stake activation |
| Net provider | socket | No XDP in containers |
| Sandbox | disabled | Container compatibility |
| Hugepages | 2 MiB only | No gigantic pages in containers |

## Workload Phases

The workload generator cycles through 6 scenarios:

| Phase | Description | Target |
|-------|-------------|--------|
| 0 | High-frequency SOL transfers | PoH pacing, pack, bank |
| 1 | Account creation storm | Account DB (funk), state hashing |
| 2 | Hot-account contention | Write-lock scheduling |
| 3 | Burst-pause (10x TPS / pause) | Queue overflow/drain races |
| 4 | Cross-validator submission | Gossip forwarding, dedup |
| 5 | Compute-heavy transactions | Execution deadlines, CU metering |

## Antithesis Instrumentation

### Enabling Assertions

```bash
# Copy the build extra into the Firedancer build system
cp config/solfiredancer-with-antithesis.mk ../../config/extra/with-antithesis.mk

# Build with Antithesis assertions
MACHINE=linux_gcc_x86_64 make -j EXTRAS="debug,antithesis"
```

### Safety Properties (must ALWAYS hold)

- Root slot never decreases (finality)
- No equivocation (same slot, different blocks)
- Vote lockout respected
- GHOST weight non-negative
- Slot timing within 100ms of expected
- Bank hash agreement across validators
- No shred equivocation
- No duplicate transactions in a block

### Liveness Properties (must SOMETIMES hold)

- Leader produces blocks
- Repair recovers missing shreds
- Gossip discovers all peers
- Epoch boundary crossed

### Fault Injection Targets

- Network: packet drop, delay, partition
- Clock: wallclock skew (+/- 100ms)
- Disk: write failure, read delay
- Gossip: message drop
- Repair: response failure

## Tuning

To adjust slot speed, change `HASHES_PER_TICK` in the compose file:

| Value | Slot Duration | Use Case |
|-------|--------------|----------|
| 1,024 | ~6.5ms | Maximum speed, aggressive timing |
| 4,096 | ~26ms | Fast but more realistic |
| 12,500 | ~80ms | Close to historic mainnet |
| 62,500 | ~400ms | Mainnet speed |

Lower values = faster slots = more timing races exposed, but validators
may not keep up if container resources are constrained.
