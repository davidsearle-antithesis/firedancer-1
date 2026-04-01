#ifndef HEADER_fd_src_disco_shred_fd_shred_tile_h
#define HEADER_fd_src_disco_shred_fd_shred_tile_h

#include "../tiles.h"
#include "../../flamenco/types/fd_types_custom.h"

/* Forward declarations */
typedef struct fd_fec_resolver fd_fec_resolver_t;
typedef struct fd_keyswitch_private fd_keyswitch_t;
typedef struct fd_keyguard_client fd_keyguard_client_t;

/* Shred tile context structure */
typedef struct {
  fd_shredder_t      * shredder;
  fd_fec_resolver_t  * resolver;
  fd_pubkey_t          identity_key[1]; /* Just the public key */
  /* ... rest of the structure members ... */
} fd_shred_shared_ctx_t;

/* first 32 bits of sig is the source of the message */
#define SHRED_SIG_SRC_TURBINE         (0UL) /* base */
#define SHRED_SIG_SRC_LEADER          (1UL) /* base */
#define SHRED_SIG_SRC_RECONSTRUCTED   (2UL) /* base */
#define SHRED_SIG_SRC_REPAIR          (3UL) /* repair */
#define SHRED_SIG_FEC_EVICTED         (5UL) /* evicted */
#define SHRED_SIG_FEC_COMPLETE        (6UL) /* complete */
#define SHRED_SIG_FEC_COMPLETE_LEADER (7UL) /* complete */

struct fd_shred_base {
  union {
    uchar        shred_[ FD_SHRED_MAX_SZ ];
    fd_shred_t   shred;
  };
  fd_hash_t merkle_root;
};
typedef struct fd_shred_base fd_shred_base_t;

struct fd_shred_repair {
  union {
    uchar        shred_[ FD_SHRED_MAX_SZ ];
    fd_shred_t   shred;
  };
  fd_hash_t merkle_root;

  uint      nonce;
};
typedef struct fd_shred_repair fd_shred_repair_t;

struct fd_shred_evicted {
  ulong slot;
  uint  fec_set_idx;
};
typedef struct fd_shred_evicted fd_shred_evicted_t;

struct fd_shred_complete {
  fd_shred_t last_shred; /* last data shred in the FEC set */
  fd_hash_t  merkle_root;
  fd_hash_t  chained_merkle_root;
};
typedef struct fd_shred_complete fd_shred_complete_t;

union fd_shred_message {
  fd_shred_repair_t    repair;
  fd_shred_base_t      shred;
  fd_shred_evicted_t   evicted;
  fd_shred_complete_t  complete;
};
typedef union fd_shred_message fd_shred_message_t;

#endif /* HEADER_fd_src_disco_shred_fd_shred_tile_h */
