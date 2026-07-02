// cva6_ptw_formal_top.sv
// -----------------------------------------------------------------------------
// Standalone formal top wrapper for CVA6 PTW verification.
//
// Purpose:
//   - Instantiate cva6_ptw with concrete package-defined types.
//   - Expose the PTW RTL interface to the formal environment.
//   - Tie PMP configuration to zero and leave PMP functional correctness out of
//     this proof target. The checker additionally assumes allow_access == 1.
//   - Keep the wrapper free of scoreboard logic; the scoreboard is bound into
//     cva6_ptw by cva6_ptw_scoreboard_bind.sv.
// -----------------------------------------------------------------------------
module cva6_ptw_formal_top
  import ariane_pkg::*;
  import cva6_ptw_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // Speculative-walk flush/kill input.
    input logic flush_i,

    // Translation enables and request-side context.
    input logic enable_translation_i,
    input logic enable_g_translation_i,
    input logic en_ld_st_translation_i,
    input logic en_ld_st_g_translation_i,
    input logic v_i,
    input logic ld_st_v_i,
    input logic hlvx_inst_i,
    input logic lsu_is_store_i,

    // Abstract data-cache response interface.
    input dcache_req_o_t req_port_i,
    output dcache_req_i_t req_port_o,

    // Update output to shared TLB.
    output tlb_update_cva6_t shared_tlb_update_o,
    output logic [CVA6Cfg.VLEN-1:0] update_vaddr_o,

    // Address-space and virtual-machine identifiers.
    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_i,

    // Shared-TLB miss input side.
    input logic                    shared_tlb_access_i,
    input logic                    shared_tlb_hit_i,
    input logic [CVA6Cfg.VLEN-1:0] shared_tlb_vaddr_i,
    input logic                    itlb_req_i,

    // Page-table root pointers from CSRs.
    input logic [CVA6Cfg.PPNW-1:0] satp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_i,
    input logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_i,

    // Permission/endian controls. For the compact proof, the checker assumes
    // little-endian mode and focuses on successful memory-access forwarding.
    input logic mxr_i,
    input logic vmxr_i,
    input logic mbe_i,

    // Main PTW status outputs.
    output logic ptw_active_o,
    output logic walking_instr_o,
    output logic ptw_error_o,
    output logic ptw_error_at_g_st_o,
    output logic ptw_err_at_g_int_st_o,
    output logic ptw_access_exception_o,
    output logic shared_tlb_miss_o,
    output logic [CVA6Cfg.PLEN-1:0] bad_paddr_o,
    output logic [CVA6Cfg.GPLEN-1:0] bad_gpaddr_o
);

  // PMP configuration is intentionally not part of this first PTW proof.
  riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg_zero;
  logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_zero;

  assign pmpcfg_zero  = '0;
  assign pmpaddr_zero = '0;

  cva6_ptw #(
      .CVA6Cfg          (CVA6Cfg),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t),
      .dcache_req_i_t   (dcache_req_i_t),
      .dcache_req_o_t   (dcache_req_o_t),
      .HYP_EXT          (HYP_EXT)
  ) i_cva6_ptw (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .flush_i                  (flush_i),
      .ptw_active_o             (ptw_active_o),
      .walking_instr_o          (walking_instr_o),
      .ptw_error_o              (ptw_error_o),
      .ptw_error_at_g_st_o      (ptw_error_at_g_st_o),
      .ptw_err_at_g_int_st_o    (ptw_err_at_g_int_st_o),
      .ptw_access_exception_o   (ptw_access_exception_o),
      .enable_translation_i     (enable_translation_i),
      .enable_g_translation_i   (enable_g_translation_i),
      .en_ld_st_translation_i   (en_ld_st_translation_i),
      .en_ld_st_g_translation_i (en_ld_st_g_translation_i),
      .v_i                      (v_i),
      .ld_st_v_i                (ld_st_v_i),
      .hlvx_inst_i              (hlvx_inst_i),
      .lsu_is_store_i           (lsu_is_store_i),
      .req_port_i               (req_port_i),
      .req_port_o               (req_port_o),
      .shared_tlb_update_o      (shared_tlb_update_o),
      .update_vaddr_o           (update_vaddr_o),
      .asid_i                   (asid_i),
      .vs_asid_i                (vs_asid_i),
      .vmid_i                   (vmid_i),
      .shared_tlb_access_i      (shared_tlb_access_i),
      .shared_tlb_hit_i         (shared_tlb_hit_i),
      .shared_tlb_vaddr_i       (shared_tlb_vaddr_i),
      .itlb_req_i               (itlb_req_i),
      .satp_ppn_i               (satp_ppn_i),
      .vsatp_ppn_i              (vsatp_ppn_i),
      .hgatp_ppn_i              (hgatp_ppn_i),
      .mxr_i                    (mxr_i),
      .vmxr_i                   (vmxr_i),
      .mbe_i                    (mbe_i),
      .shared_tlb_miss_o        (shared_tlb_miss_o),
      .pmpcfg_i                 (pmpcfg_zero),
      .pmpaddr_i                (pmpaddr_zero),
      .bad_paddr_o              (bad_paddr_o),
      .bad_gpaddr_o             (bad_gpaddr_o)
  );

endmodule
