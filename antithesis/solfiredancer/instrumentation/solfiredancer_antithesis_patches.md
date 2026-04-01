# solfiredancer — Antithesis Instrumentation Guide

This document describes where to insert `solfiredancer_antithesis.h` macros
into the Firedancer codebase for maximum Antithesis coverage.

## How to use

1. Add `-DFD_ANTITHESIS_ENABLED=1` to the build flags
2. Include `solfiredancer_antithesis.h` in the files listed below
3. Insert the macro calls at the specified locations

## Insertion Points

### 1. Tower / Consensus — `src/choreo/tower/fd_tower.c`

**Root monotonicity:**
```c
// In the function that updates the root slot:
// Before: ctx->root_slot = new_root;
SOLFIREDANCER_ASSERT_ROOT_MONOTONIC( ctx->root_slot, new_root );
// After:  ctx->root_slot = new_root;
```

**Lockout enforcement:**
```c
// In the vote decision function, before casting a vote:
SOLFIREDANCER_ASSERT_LOCKOUT_RESPECTED( current_slot, vote_expiration_slot );
```

**Vote reachability:**
```c
// After successfully submitting a vote:
SOLFIREDANCER_REACHABLE_VOTE_CAST();
```

### 2. PoH Timing — `src/discoh/pohh/fd_pohh_tile.c`

**Slot timing drift:**
```c
// In the slot boundary detection code, after computing actual vs expected:
long actual_ns   = fd_log_wallclock();
long expected_ns = reset_slot_start_ns + (slot - reset_slot) * slot_duration_ns;
SOLFIREDANCER_ASSERT_SLOT_TIMING( actual_ns, expected_ns, 100000000L /* 100ms */ );
```

**Leader block production:**
```c
// After a leader successfully publishes a block:
SOLFIREDANCER_SOMETIMES_LEADER_PRODUCED_BLOCK( 1 );
```

**Leader rotation reachability:**
```c
// When leadership transitions to a different validator:
SOLFIREDANCER_REACHABLE_LEADER_ROTATION();
```

### 3. Replay — `src/discof/replay/fd_replay_tile.c`

**Replay deadline:**
```c
// After block replay completes, before voting:
long now_ns      = fd_log_wallclock();
long deadline_ns = expected_slot_start_ns + slot_duration_ns;
SOLFIREDANCER_ASSERT_REPLAY_DEADLINE( now_ns, deadline_ns );
```

### 4. GHOST Fork Choice — `src/choreo/ghost/fd_ghost.c`

**Weight invariant:**
```c
// After computing fork weight:
SOLFIREDANCER_ASSERT_GHOST_WEIGHT_NONNEG( fork->weight );
```

**Fork reachability:**
```c
// When a fork is detected:
SOLFIREDANCER_REACHABLE_FORK_CREATED();
```

### 5. Gossip — `src/discof/gossip/fd_gossip_tile.c`

**Peer discovery:**
```c
// In the peer table update callback:
SOLFIREDANCER_SOMETIMES_PEER_DISCOVERED( ctx->peer_cnt, EXPECTED_CLUSTER_SIZE );
```

**Saturation:**
```c
// When PEER_SATURATED message is published:
SOLFIREDANCER_SOMETIMES_GOSSIP_SATURATED( 1 );
```

**Setup complete (call once when ALL validators have saturated):**
```c
SOLFIREDANCER_SETUP_COMPLETE();
```

### 6. Repair — `src/discof/repair/fd_repair_tile.c`

**Recovery liveness:**
```c
// After successfully receiving a repaired shred:
SOLFIREDANCER_SOMETIMES_REPAIR_RECOVERED( slot, 1 );
SOLFIREDANCER_REACHABLE_REPAIR_ACTIVATED();
```

### 7. Shred — `src/disco/shred/fd_shred_tile.c`

**No equivocation:**
```c
// When receiving a shred for a (slot, idx) we already have:
int match = fd_memeq( existing_data, new_data, data_sz );
SOLFIREDANCER_ASSERT_NO_SHRED_EQUIVOCATION( match );
```

### 8. Pack — `src/disco/pack/fd_pack_tile.c`

**No duplicate transactions:**
```c
// After dedup check before packing:
SOLFIREDANCER_ASSERT_NO_DUPLICATE_TXN( is_unique );
```

### 9. Network (Fault Injection) — `src/waltz/udp/fd_udp.c` or `src/disco/net/fd_net_tile.c`

**Packet drop injection:**
```c
// At packet receive:
if( SOLFIREDANCER_FAULT_DROP_PACKET() ) {
  // Skip processing this packet
  continue;
}
```

**Packet delay injection:**
```c
// At packet receive:
if( SOLFIREDANCER_FAULT_DELAY_PACKET() ) {
  fd_log_sleep( 50000000L ); // 50ms delay
}
```

### 10. Wallclock (Fault Injection) — `src/util/log/fd_log.c`

**Clock skew injection:**
```c
// In fd_log_wallclock() or its callers:
long t = fd_log_wallclock();
if( SOLFIREDANCER_FAULT_CLOCK_SKEW() ) {
  t += (long)((fd_rng_double( rng ) - 0.5) * 200000000.0); // +/- 100ms
}
```

## Build Integration

Add to `config/extra/with-antithesis.mk`:
```make
CPPFLAGS += -DFD_ANTITHESIS_ENABLED=1
CPPFLAGS += -I$(CURDIR)/antithesis/solfiredancer/instrumentation
LDFLAGS  += -lantithesis
```

Then build with:
```bash
make -j EXTRAS="debug,antithesis"
```
