#ifndef HEADER_fd_src_discof_restore_utils_fd_ssload_h
#define HEADER_fd_src_discof_restore_utils_fd_ssload_h

#include "fd_ssmsg.h"
#include "../../../flamenco//runtime/fd_blockhashes.h"

FD_PROTOTYPES_BEGIN

void
blockhashes_recover( fd_blockhashes_t *                       blockhashes,
                     fd_snapshot_manifest_blockhash_t const * ages,
                     ulong                                    age_cnt,
                     ulong                                    seed );

/* fd_ssload_recover_bank populates bank state fields from the snapshot
   manifest.  This includes slot, hashes, inflation, epoch schedule,
   rent, blockhashes, stake delegations, etc.  Called from snapin. */
void
fd_ssload_recover_bank( fd_snapshot_manifest_t * manifest,
                        fd_banks_t *            banks,
                        fd_bank_t *             bank,
                        int                     is_incremental );

/* fd_ssload_recover_epoch_stakes populates vote stakes and top votes
   on the bank, and epoch credits on the runtime stack.  Called from
   replay after the bank has been populated by fd_ssload_recover_bank. */
void
fd_ssload_recover_epoch_stakes( fd_snapshot_manifest_t * manifest,
                                fd_bank_t *              bank,
                                fd_runtime_stack_t *     runtime_stack,
                                int                      is_incremental );

/* fd_ssload_recover is a convenience wrapper that calls both
   fd_ssload_recover_bank and fd_ssload_recover_epoch_stakes. */
void
fd_ssload_recover( fd_snapshot_manifest_t *  manifest,
                   fd_banks_t *              banks,
                   fd_bank_t *               bank,
                   fd_runtime_stack_t *      runtime_stack,
                   int                       is_incremental );

FD_PROTOTYPES_END

#endif /* HEADER_fd_src_discof_restore_utils_fd_ssload_h */
