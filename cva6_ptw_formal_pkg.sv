// cva6_ptw_formal_pkg.sv
// -----------------------------------------------------------------------------
// Formal package for standalone CVA6 PTW verification.
//
// PTW = Page Table Walker.
//
// Purpose:
//   - Build one concrete CVA6 configuration for a compact PTW proof target.
//   - Define the local PTE/update/cache-request types needed by cva6_ptw.
//   - Keep this first proof intentionally abstract and reusable.
//
// Initial proof target:
//   - Shared TLB is enabled because the PTW is started from the shared-TLB miss
//     path in the MMU.
//   - RVH/hypervisor translation is disabled for the first compact proof.
//   - Svnapot/NAPOT is disabled for the first compact proof.
//   - PMP functionality is not verified in this proof target; the checker assumes
//     the PTW page-table memory access is allowed.
//
// Later extensions can re-enable RVH and Svnapot by changing force_ptw_base_cfg()
// and by extending the scoreboard content/g_content rules.
// -----------------------------------------------------------------------------
package cva6_ptw_formal_pkg;

  // Start from the selected CVA6 user configuration.
  localparam config_pkg::cva6_cfg_t CVA6CfgBuilt =
      build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  // First compact PTW proof configuration.
  // RVH     = RISC-V Hypervisor extension.
  // Svnapot = RISC-V naturally aligned power-of-two page extension.
  function automatic config_pkg::cva6_cfg_t force_ptw_base_cfg(
      input config_pkg::cva6_cfg_t cfg
  );
    force_ptw_base_cfg = cfg;
    force_ptw_base_cfg.UseSharedTlb = 1'b1;
    force_ptw_base_cfg.RVH          = 1'b1;
    force_ptw_base_cfg.SvnapotEn    = 1'b0;
  endfunction

  localparam config_pkg::cva6_cfg_t CVA6Cfg = force_ptw_base_cfg(CVA6CfgBuilt);

  // HYP_EXT is the extra hypervisor dimension used by the CVA6 TLB update type.
  localparam int unsigned HYP_EXT = 1;

  // Bounded fairness values for the abstract memory/cache environment.
  // Increase these if the real cache wrapper or proof target needs more latency.
  localparam int unsigned PTW_MAX_GRANT_LAT  = 5;
  localparam int unsigned PTW_MAX_RVALID_LAT = 5;
  //found out that the worst case execution time for the page table walk ,
  // owhen going through the three levels of the page table entry
  //was 27 clck cycles, 9 cycles for each level of the page table entry, and 3 levels in total,
  //so 9*3=27 clock cycles
  localparam int unsigned PTW_MAX_WALK_LAT   = 27;


  // PTE = Page Table Entry.
  // Same packed layout as the local pte_cva6_t used inside cva6_mmu.
  typedef struct packed {
    logic n;                              // NAPOT extension bit.
    logic [8:0] reserved;                 // Reserved PTE bits.
    logic [CVA6Cfg.PPNW-1:0] ppn;         // PPN = Physical Page Number.
    logic [1:0] rsw;                      // Reserved for software.
    logic d;                              // Dirty bit.
    logic a;                              // Accessed bit.
    logic g;                              // Global mapping bit.
    logic u;                              // User-accessible bit.
    logic x;                              // Execute permission.
    logic w;                              // Write permission.
    logic r;                              // Read permission.
    logic v;                              // Valid bit.
  } pte_cva6_t;

  // TLB update packet produced by the PTW and consumed by the shared TLB.
  typedef struct packed {
    logic valid;                                      // Packet is active.
    logic is_napot_64k;                               // 64 KiB NAPOT translation.
    logic [CVA6Cfg.PtLevels-2:0][HYP_EXT:0] is_page;  // Leaf level flags.
    logic [CVA6Cfg.VpnLen-1:0] vpn;                   // VPN = Virtual Page Number.
    logic [CVA6Cfg.ASID_WIDTH-1:0] asid;              // ASID = Address Space ID.
    logic [CVA6Cfg.VMID_WIDTH-1:0] vmid;              // VMID = Virtual Machine ID.
    logic [HYP_EXT*2:0] v_st_enbl;                    // Stage context; unused here.
    pte_cva6_t content;                               // Main/S-stage PTE content.
    pte_cva6_t g_content;                             // G-stage PTE content.
  } tlb_update_cva6_t;

  // Minimal cache request going from PTW to data cache.
  // Only fields driven by cva6_ptw are included.
  typedef struct packed {
    logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic                                  data_req;
    logic                                  data_we;
    logic [1:0]                            data_size;
    logic [CVA6Cfg.XLEN/8-1:0]             data_be;
    logic [CVA6Cfg.XLEN-1:0]               data_wdata;
    logic [0:0]                            data_id;
    logic [0:0]                            data_wuser;
    logic [1:0]                            cbo_op;
    logic                                  tag_valid;
    logic                                  kill_req;
  } dcache_req_i_t;

  // Minimal cache response going from data cache to PTW.
  // Only fields read by cva6_ptw are included.
  typedef struct packed {
    logic                    data_gnt;
    logic                    data_rvalid;
    logic [CVA6Cfg.XLEN-1:0] data_rdata;
  } dcache_req_o_t;

endpackage
