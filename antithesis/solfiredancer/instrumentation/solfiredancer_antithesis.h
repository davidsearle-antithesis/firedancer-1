/* =============================================================================
   solfiredancer_antithesis.h — Antithesis assertion and fault injection macros
   for the Firedancer Solana validator.

   This header wraps the Antithesis C SDK to provide domain-specific assertion
   macros for Firedancer's consensus, timing, and networking subsystems.

   USAGE:
     1. Include this header in the files you want to instrument.
     2. Link against the Antithesis SDK shared library.
     3. Define FD_ANTITHESIS_ENABLED=1 at compile time to activate.
        When not defined, all macros expand to no-ops.

   The macros fall into three categories:
     - ALWAYS:    Safety invariants that must hold on every evaluation.
     - SOMETIMES: Liveness properties that should hold at least once.
     - REACHABLE: Code paths that should be exercised at least once.

   See: https://docs.antithesis.com/instrumentation/
   ============================================================================= */

#ifndef HEADER_solfiredancer_antithesis_h
#define HEADER_solfiredancer_antithesis_h

#include <stdbool.h>

/* ---- Antithesis SDK linkage ---- */

#if FD_ANTITHESIS_ENABLED

/* The Antithesis C SDK exposes these three functions.  They are
   provided by the Antithesis shared library injected at runtime. */
extern void antithesis_assert_always(
    bool   condition,
    const char * message,
    const char * class_name,
    const char * function_name,
    const char * file_name,
    int          line_number );

extern void antithesis_assert_sometimes(
    bool   condition,
    const char * message,
    const char * class_name,
    const char * function_name,
    const char * file_name,
    int          line_number );

extern void antithesis_assert_reachable(
    const char * message,
    const char * class_name,
    const char * function_name,
    const char * file_name,
    int          line_number );

extern void antithesis_setup_complete( void );

/* Fault injection: returns non-zero when the Antithesis scheduler
   wants to inject a fault at this point. */
extern bool antithesis_should_inject_fault(
    const char * fault_class,
    const char * description,
    const char * file_name,
    int          line_number );

/* ---- Core macros ---- */

#define SOLFIREDANCER_ASSERT_ALWAYS( cond, msg ) \
  antithesis_assert_always( (cond), (msg), "solfiredancer", __func__, __FILE__, __LINE__ )

#define SOLFIREDANCER_ASSERT_SOMETIMES( cond, msg ) \
  antithesis_assert_sometimes( (cond), (msg), "solfiredancer", __func__, __FILE__, __LINE__ )

#define SOLFIREDANCER_ASSERT_REACHABLE( msg ) \
  antithesis_assert_reachable( (msg), "solfiredancer", __func__, __FILE__, __LINE__ )

#define SOLFIREDANCER_SETUP_COMPLETE() \
  antithesis_setup_complete()

#define SOLFIREDANCER_INJECT_FAULT( fault_class, desc ) \
  antithesis_should_inject_fault( (fault_class), (desc), __FILE__, __LINE__ )

#else /* FD_ANTITHESIS_ENABLED not defined */

#define SOLFIREDANCER_ASSERT_ALWAYS( cond, msg )       do { (void)(cond); } while(0)
#define SOLFIREDANCER_ASSERT_SOMETIMES( cond, msg )    do { (void)(cond); } while(0)
#define SOLFIREDANCER_ASSERT_REACHABLE( msg )           ((void)0)
#define SOLFIREDANCER_SETUP_COMPLETE()                   ((void)0)
#define SOLFIREDANCER_INJECT_FAULT( fault_class, desc ) (0)

#endif /* FD_ANTITHESIS_ENABLED */


/* ============================================================================
   DOMAIN-SPECIFIC ASSERTION MACROS

   These encode the specific safety and liveness properties of Firedancer
   that we want Antithesis to check.
   ============================================================================ */

/* ---- Consensus / Tower ---- */

/* Root slot must never decrease — this is the fundamental finality guarantee. */
#define SOLFIREDANCER_ASSERT_ROOT_MONOTONIC( old_root, new_root ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    (new_root) >= (old_root), \
    "root slot must never decrease (finality violation)" )

/* A validator must never vote on two different blocks at the same slot height. */
#define SOLFIREDANCER_ASSERT_NO_EQUIVOCATION( slot, prev_hash, new_hash ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    fd_hash_eq( (prev_hash), (new_hash) ), \
    "equivocation: voted on two different blocks at same slot" )

/* Vote lockout must be respected — cannot switch forks until lockout expires. */
#define SOLFIREDANCER_ASSERT_LOCKOUT_RESPECTED( current_slot, expiration_slot ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    (current_slot) >= (expiration_slot), \
    "fork switch before vote lockout expired" )

/* GHOST fork weight must never be negative. */
#define SOLFIREDANCER_ASSERT_GHOST_WEIGHT_NONNEG( weight ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    (long)(weight) >= 0, \
    "GHOST fork weight is negative" )

/* ---- PoH Timing ---- */

/* Slot boundary must not drift more than max_drift_ns from expected wallclock. */
#define SOLFIREDANCER_ASSERT_SLOT_TIMING( actual_ns, expected_ns, max_drift_ns ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    ((actual_ns) - (expected_ns)) < (max_drift_ns) && \
    ((expected_ns) - (actual_ns)) < (max_drift_ns), \
    "slot boundary drifted beyond acceptable wallclock tolerance" )

/* Leader transition should happen — liveness property. */
#define SOLFIREDANCER_SOMETIMES_LEADER_PRODUCED_BLOCK( produced ) \
  SOLFIREDANCER_ASSERT_SOMETIMES( \
    (produced), \
    "this validator produced a block as leader" )

/* ---- Replay ---- */

/* Replay must complete before the deadline. */
#define SOLFIREDANCER_ASSERT_REPLAY_DEADLINE( now_ns, deadline_ns ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    (now_ns) <= (deadline_ns), \
    "replay did not complete before leader deadline" )

/* Bank hash must agree across validators for the same finalized slot. */
#define SOLFIREDANCER_ASSERT_BANK_HASH_AGREEMENT( slot, our_hash, their_hash ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    fd_hash_eq( (our_hash), (their_hash) ), \
    "bank hash mismatch for finalized slot" )

/* ---- Repair ---- */

/* Missing shreds should eventually be recovered — liveness property. */
#define SOLFIREDANCER_SOMETIMES_REPAIR_RECOVERED( slot, recovered ) \
  SOLFIREDANCER_ASSERT_SOMETIMES( \
    (recovered), \
    "repair recovered missing shreds for slot" )

/* ---- Gossip ---- */

/* All validators should eventually discover each other. */
#define SOLFIREDANCER_SOMETIMES_PEER_DISCOVERED( total_peers, expected_peers ) \
  SOLFIREDANCER_ASSERT_SOMETIMES( \
    (total_peers) >= (expected_peers), \
    "gossip discovered all expected peers" )

/* Gossip peer saturation should eventually be reached. */
#define SOLFIREDANCER_SOMETIMES_GOSSIP_SATURATED( saturated ) \
  SOLFIREDANCER_ASSERT_SOMETIMES( \
    (saturated), \
    "gossip reached peer saturation" )

/* ---- Shred / Turbine ---- */

/* No shred equivocation — same (leader, slot, shred_idx) must have same data. */
#define SOLFIREDANCER_ASSERT_NO_SHRED_EQUIVOCATION( match ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    (match), \
    "shred equivocation: same slot+idx, different data" )

/* ---- Pack ---- */

/* No duplicate transactions in a single block. */
#define SOLFIREDANCER_ASSERT_NO_DUPLICATE_TXN( is_unique ) \
  SOLFIREDANCER_ASSERT_ALWAYS( \
    (is_unique), \
    "duplicate transaction packed into same block" )

/* ---- Epoch Boundary ---- */

/* Epoch transition should be reached — liveness property. */
#define SOLFIREDANCER_SOMETIMES_EPOCH_BOUNDARY( crossed ) \
  SOLFIREDANCER_ASSERT_SOMETIMES( \
    (crossed), \
    "epoch boundary was crossed" )

/* ---- Reachability markers ---- */

/* These mark code paths that should be exercised at least once during testing. */
#define SOLFIREDANCER_REACHABLE_FORK_CREATED() \
  SOLFIREDANCER_ASSERT_REACHABLE( "fork was created and later resolved" )

#define SOLFIREDANCER_REACHABLE_LEADER_ROTATION() \
  SOLFIREDANCER_ASSERT_REACHABLE( "leader rotation occurred" )

#define SOLFIREDANCER_REACHABLE_REPAIR_ACTIVATED() \
  SOLFIREDANCER_ASSERT_REACHABLE( "repair protocol activated to fill shred gap" )

#define SOLFIREDANCER_REACHABLE_SNAPSHOT_CATCHUP() \
  SOLFIREDANCER_ASSERT_REACHABLE( "validator caught up via snapshot" )

#define SOLFIREDANCER_REACHABLE_VOTE_CAST() \
  SOLFIREDANCER_ASSERT_REACHABLE( "validator cast a consensus vote" )


/* ============================================================================
   FAULT INJECTION POINTS

   These macros return true when the Antithesis scheduler wants to inject a
   fault at the call site.  The caller should check the return value and
   simulate the fault (drop packet, delay, return error, etc.)
   ============================================================================ */

/* Network fault: drop an incoming/outgoing packet. */
#define SOLFIREDANCER_FAULT_DROP_PACKET() \
  SOLFIREDANCER_INJECT_FAULT( "network", "drop packet" )

/* Network fault: delay packet processing. */
#define SOLFIREDANCER_FAULT_DELAY_PACKET() \
  SOLFIREDANCER_INJECT_FAULT( "network", "delay packet" )

/* Clock fault: skew the wallclock read. */
#define SOLFIREDANCER_FAULT_CLOCK_SKEW() \
  SOLFIREDANCER_INJECT_FAULT( "clock", "skew wallclock" )

/* Disk fault: fail a blockstore write. */
#define SOLFIREDANCER_FAULT_DISK_WRITE_FAIL() \
  SOLFIREDANCER_INJECT_FAULT( "disk", "fail blockstore write" )

/* Disk fault: delay a blockstore read. */
#define SOLFIREDANCER_FAULT_DISK_READ_DELAY() \
  SOLFIREDANCER_INJECT_FAULT( "disk", "delay blockstore read" )

/* Gossip fault: drop a gossip message to simulate partial partition. */
#define SOLFIREDANCER_FAULT_GOSSIP_DROP() \
  SOLFIREDANCER_INJECT_FAULT( "gossip", "drop gossip message" )

/* Repair fault: fail a repair response. */
#define SOLFIREDANCER_FAULT_REPAIR_FAIL() \
  SOLFIREDANCER_INJECT_FAULT( "repair", "fail repair response" )

#endif /* HEADER_solfiredancer_antithesis_h */
