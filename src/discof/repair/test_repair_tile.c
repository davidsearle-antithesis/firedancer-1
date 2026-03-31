#include "fd_repair_tile.c"

static void
test_future_slots( fd_wksp_t * wksp, ulong slot_max ) {
  static ctx_t ctx[1];
  memset( ctx, 0, sizeof(*ctx) );

  void * forest_mem    = fd_wksp_alloc_laddr( wksp, fd_forest_align(), fd_forest_footprint( slot_max ), 1UL );
  void * inflights_mem = fd_wksp_alloc_laddr( wksp, fd_inflights_align(), fd_inflights_footprint(), 1UL );

  ctx->forest    = fd_forest_join   ( fd_forest_new   ( forest_mem, slot_max, 0UL ) );
  ctx->inflights = fd_inflights_join( fd_inflights_new( inflights_mem, 0UL ) );

  /* 1. after_snap initialized forest to slot 1000 */

  fd_forest_init( ctx->forest, 1000 );
  ulong turbine_slot = 4000;

  /* 2. after_shred inserts slot 4000, which causes orphan repair. As
     orphan repair occurs, turbine should be continuing. Every 5 orphans
     we get back, get a turbine slot. */

  for( ulong slot = turbine_slot; slot >= 1000; slot-- ) {
    ulong sig = fd_disco_shred_out_shred_sig( 0, slot, 320, 351 );
    fd_shred_t shred = {
        .slot = slot,
        .idx = 351,
        .fec_set_idx = 320,
        .variant = FD_SHRED_TYPE_MERKLE_DATA_CHAINED_RESIGNED | 0xF , // merkle data (chained resigned)
        .data = {
            .flags = FD_SHRED_DATA_FLAG_SLOT_COMPLETE,
            .parent_off = 1,
        },
    };
    fd_hash_t mr  = { .ul = { slot, 320 } };
    fd_hash_t cmr = { .ul = { slot, 288 } };
    after_shred( ctx, sig, &shred, 0, &mr, &cmr );

    if( slot % 5 == 0 ) {
      turbine_slot++;
      ulong sig = fd_disco_shred_out_shred_sig( 1, turbine_slot, 0, 0 );
      fd_shred_t shred = {
          .slot = turbine_slot,
          .idx = 0,
          .fec_set_idx = 0,
          .variant = FD_SHRED_TYPE_MERKLE_DATA_CHAINED_RESIGNED | 0xF , // merkle data (chained resigned)
          .data = {
              .flags = FD_SHRED_DATA_FLAG_SLOT_COMPLETE,
              .parent_off = 1,
          },
      };
      fd_hash_t mr  = { .ul = { turbine_slot, 0 } };
      fd_hash_t cmr = { .ul = { turbine_slot, 0 } };
      after_shred( ctx, sig, &shred, 0, &mr, &cmr );
    }
  }
}

int main( int argc, char ** argv ) {
  fd_boot( &argc, &argv );

  ulong  page_cnt = 1;
  char * page_sz = "gigantic";
  ulong  numa_idx = fd_shmem_numa_idx( 0 );
  fd_wksp_t * wksp = fd_wksp_new_anonymous( fd_cstr_to_shmem_page_sz( page_sz ), page_cnt, fd_shmem_cpu_idx( numa_idx ), "wksp", 0UL );
  FD_TEST( wksp );

  ulong repair_slot_max = 1024;

  test_future_slots( wksp, repair_slot_max );

  fd_halt();
  return 0;
}
