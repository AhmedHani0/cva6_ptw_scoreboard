// cva6_ptw_scoreboard_bind_v4_rtl_names.sv
// -----------------------------------------------------------------------------
// Direct-bind black-box scoreboard for standalone CVA6 PTW verification.
//
// Version 4: no internal PTW signals, but scoreboard state names mirror the RTL
// PTW FSM names for readability.
//
// Important limitation:
//   This checker does not read the RTL internal state_q, data_rvalid_q, or
//   data_rdata_q. Therefore the scoreboard FSM is not a copied RTL FSM. It is a
//   black-box phase model whose state names correspond to the RTL states.
//
// RTL PTW states mirrored here:
//   IDLE
//   WAIT_GRANT
//   PTE_LOOKUP
//   WAIT_RVALID
//   PROPAGATE_ERROR
//   PROPAGATE_ACCESS_ERROR
//   KILL_REQ
//   LATENCY
//
// Main properties:
//   1. Liveness/progress under bounded memory fairness.
//   2. Data integrity: the PTE returned by the data cache is the PTE forwarded
//      to the shared TLB update packet, with ITLB and DTLB versions.
//   3. No accepted/outstanding PTW request -> no PTW response.
//   4. No two ITLB/DTLB private misses is not a PTW-local property. The PTW
//      receives one serialized request plus itlb_req_i. The PTW-local equivalent
//      checked here is: no second accepted PTW start while a request is outstanding.
// -----------------------------------------------------------------------------

module cva6_ptw_scoreboard_bind
  import cva6_ptw_formal_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input logic flush_i,

    input logic ptw_active_o,
    input logic walking_instr_o,
    input logic ptw_error_o,
    input logic ptw_access_exception_o,
    input logic shared_tlb_miss_o,

    input logic enable_translation_i,
    input logic enable_g_translation_i,
    input logic en_ld_st_translation_i,
    input logic en_ld_st_g_translation_i,
    input logic v_i,
    input logic ld_st_v_i,
    input logic hlvx_inst_i,
    input logic lsu_is_store_i,
    input logic mbe_i,

    input dcache_req_o_t req_port_i,
    input dcache_req_i_t req_port_o,

    input tlb_update_cva6_t shared_tlb_update_o,
    input logic [CVA6Cfg.VLEN-1:0] update_vaddr_o,

    input logic [CVA6Cfg.ASID_WIDTH-1:0] asid_i,
    input logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_i,
    input logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_i,

    input logic                    shared_tlb_access_i,
    input logic                    shared_tlb_hit_i,
    input logic [CVA6Cfg.VLEN-1:0] shared_tlb_vaddr_i,
    input logic                    itlb_req_i
);

  localparam int unsigned VPN_LEN = CVA6Cfg.VpnLen;
  localparam int unsigned PTW_MAX_FLUSH_HIGH_LAT = 4;
  localparam int unsigned PTW_MAX_DRAIN_LAT =
    PTW_MAX_GRANT_LAT + PTW_MAX_RVALID_LAT + 8;

  // Use RTL state names, prefixed with SB_ to avoid name collisions.
  typedef enum logic [2:0] {
    SB_IDLE,
    SB_WAIT_GRANT,
    SB_PTE_LOOKUP,
    SB_WAIT_RVALID,
    SB_PROPAGATE_ERROR,
    SB_PROPAGATE_ACCESS_ERROR,
    SB_KILL_REQ,
    SB_LATENCY
  } sb_state_e;

  sb_state_e sb_state_q;

  // ---------------------------------------------------------------------------
  // Basic helpers.
  // ---------------------------------------------------------------------------
  function automatic logic [VPN_LEN-1:0] vpn_from_vaddr(
      input logic [CVA6Cfg.VLEN-1:0] vaddr
  );
    vpn_from_vaddr = vaddr[VPN_LEN+11:12];
  endfunction

  function automatic pte_cva6_t pte_from_cache_data(
      input logic [CVA6Cfg.XLEN-1:0] data
  );
    pte_from_cache_data = pte_cva6_t'(data);
  endfunction

  function automatic logic pte_has_no_invalid_encoding(input pte_cva6_t pte);
    pte_has_no_invalid_encoding =
        pte.v &&
        !(!pte.r && pte.w) &&
        !(|pte.reserved) &&
        !pte.n;
  endfunction
  
  // The RTL can OR an earlier global mapping into the final update content.g.
  // Therefore compare all fields directly except g, and compare g to the
  function automatic logic pte_content_matches_except_global(
      input pte_cva6_t dut_pte,
      input pte_cva6_t mem_pte
  );
    pte_content_matches_except_global =
        (dut_pte.n        == mem_pte.n) &&
        (dut_pte.reserved == mem_pte.reserved) &&
        (dut_pte.ppn      == mem_pte.ppn) &&
        (dut_pte.rsw      == mem_pte.rsw) &&
        (dut_pte.d        == mem_pte.d) &&
        (dut_pte.a        == mem_pte.a) &&
        (dut_pte.u        == mem_pte.u) &&
        (dut_pte.x        == mem_pte.x) &&
        (dut_pte.w        == mem_pte.w) &&
        (dut_pte.r        == mem_pte.r) &&
        (dut_pte.v        == mem_pte.v);
  endfunction

  wire translation_context_enabled;
  assign translation_context_enabled =
      ((enable_translation_i | enable_g_translation_i) ||
       (en_ld_st_translation_i || en_ld_st_g_translation_i) ||
       !CVA6Cfg.RVH);

  // PTW input-side miss condition while the RTL registered FSM is idle.
  wire expected_miss_pulse;
  assign expected_miss_pulse =
      !ptw_active_o &&
      translation_context_enabled &&
      shared_tlb_access_i &&
      !shared_tlb_hit_i;

  wire raw_start_walk;
  wire clean_start_walk;
  wire start_itlb_walk;
  wire start_dtlb_walk;
  wire ptw_response;

  // PTW saw a miss, even if flush kills it.
  assign raw_start_walk =
      shared_tlb_miss_o;
  // PTW saw a miss and it was not flushed in the same cycle.
  assign clean_start_walk =
      shared_tlb_miss_o && !flush_i;

  //clean starts used for normal liveness and data-integrity.
  assign start_itlb_walk =
      clean_start_walk && itlb_req_i;
  //clean starts used for normal liveness and data-integrity.
  assign start_dtlb_walk =
      clean_start_walk && !itlb_req_i;

  assign ptw_response =
      shared_tlb_update_o.valid ||
      ptw_error_o ||
      ptw_access_exception_o;

  pte_cva6_t dcache_pte_now;
  assign dcache_pte_now = pte_from_cache_data(req_port_i.data_rdata);

  // ---------------------------------------------------------------------------
  // Tracked request identity and black-box PTE response mirror.
  // ---------------------------------------------------------------------------
  logic raw_req_outstanding_q;
  logic tracked_valid_q;
  logic tracked_is_itlb_q;
  logic tracked_store_q;
  logic [CVA6Cfg.VLEN-1:0] tracked_vaddr_q;
  logic [VPN_LEN-1:0] tracked_vpn_q;
  logic [CVA6Cfg.ASID_WIDTH-1:0] tracked_asid_q;
  logic [CVA6Cfg.VMID_WIDTH-1:0] tracked_vmid_q;

  // One-cycle delayed mirror of external data-cache response.
  // External cache response at cycle N:
  //   req_port_i.data_rvalid = 1, req_port_i.data_rdata = PTE
  // Evaluation cycle at cycle N+1:
  //   eval_pte_valid_q = 1, eval_pte_q = captured PTE
  // This mirrors the RTL internal data_rvalid_q/data_rdata_q without binding them.
  pte_cva6_t eval_pte_q;
  logic eval_pte_valid_q;
  logic killed_q;

  wire [CVA6Cfg.ASID_WIDTH-1:0] selected_asid;
  assign selected_asid = itlb_req_i ? (v_i ? vs_asid_i : asid_i)
                                   : (ld_st_v_i ? vs_asid_i : asid_i);

// ---------------------------------------------------------------------------
// Scoreboard FSM with RTL-equivalent state names.
//
// Important separation:
//   raw_req_outstanding_q:
//     Tracks any PTW request seen by the RTL, even if immediately flushed.
//     Used for: "no request -> no response".
//
//   tracked_valid_q / killed_q:
//     Tracks only clean non-flushed normal walks.
//     Used for: data integrity and normal liveness.
// ---------------------------------------------------------------------------
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) begin
    sb_state_q             <= SB_IDLE;
    raw_req_outstanding_q  <= 1'b0;

    tracked_valid_q        <= 1'b0;
    tracked_is_itlb_q      <= 1'b0;
    tracked_store_q        <= 1'b0;
    tracked_vaddr_q        <= '0;
    tracked_vpn_q          <= '0;
    tracked_asid_q         <= '0;
    tracked_vmid_q         <= '0;

    eval_pte_q             <= '0;
    eval_pte_valid_q       <= 1'b0;

    killed_q               <= 1'b0;

  end else begin
    eval_pte_valid_q <= 1'b0;

    if (raw_start_walk) begin
      raw_req_outstanding_q <= 1'b1;
    end else if (!ptw_active_o && !ptw_response) begin
      raw_req_outstanding_q <= 1'b0;
    end

    // Highest priority: RTL accepted a clean new walk.
    if (clean_start_walk) begin
      tracked_valid_q   <= 1'b1;
      tracked_is_itlb_q <= itlb_req_i;
      tracked_store_q   <= lsu_is_store_i;
      tracked_vaddr_q   <= shared_tlb_vaddr_i;
      tracked_vpn_q     <= vpn_from_vaddr(shared_tlb_vaddr_i);
      tracked_asid_q    <= selected_asid;
      tracked_vmid_q    <= CVA6Cfg.RVH ? vmid_i : '0;

      eval_pte_q        <= '0;
      eval_pte_valid_q  <= 1'b0;

      killed_q          <= 1'b0;
      sb_state_q        <= SB_WAIT_GRANT;

    end else if (raw_start_walk && flush_i) begin
      tracked_valid_q   <= 1'b0;
      eval_pte_valid_q  <= 1'b0;
      killed_q          <= 1'b1;
      sb_state_q        <= SB_LATENCY;

    end else begin
      if (tracked_valid_q && ptw_active_o && flush_i) begin
        killed_q <= 1'b1;
      end
      unique case (sb_state_q)
        // ---------------------------------------------------------------------
        // RTL IDLE
        // ---------------------------------------------------------------------
        SB_IDLE: begin
          tracked_valid_q <= 1'b0;
          killed_q        <= 1'b0;
          
          if (raw_start_walk && flush_i) begin
            // RTL can pulse shared_tlb_miss_o while flush_i is high.
            // This is a raw request, but not a clean data-integrity transaction.
            // In the RTL, this behaves like an immediately cancelled speculative
            // walk and can go through LATENCY before returning to IDLE.
            tracked_valid_q <= 1'b0;
            killed_q        <= 1'b1;
            sb_state_q      <= SB_LATENCY;
          end
        end
        // ---------------------------------------------------------------------
        // RTL WAIT_GRANT
        // ---------------------------------------------------------------------
        SB_WAIT_GRANT: begin
          if (flush_i) begin
            killed_q <= 1'b1;
          end

          if (req_port_o.data_req && req_port_i.data_gnt) begin
            if (flush_i || killed_q) begin
              sb_state_q <= SB_KILL_REQ;
            end else begin
              sb_state_q <= SB_PTE_LOOKUP;
            end
          end
        end
        // ---------------------------------------------------------------------
        // RTL KILL_REQ
        // ---------------------------------------------------------------------
        SB_KILL_REQ: begin
          killed_q   <= 1'b1;
          sb_state_q <= SB_WAIT_RVALID;
        end
        // ---------------------------------------------------------------------
        // RTL WAIT_RVALID
        //
        // This is only the killed/drain path. We wait for the external memory
        // response, then allow the checker to drain through LATENCY.
        // ---------------------------------------------------------------------
        SB_WAIT_RVALID: begin
          killed_q <= 1'b1;

          if (req_port_i.data_rvalid) begin
            sb_state_q <= SB_LATENCY;
          end else if (!ptw_active_o) begin
            // Defensive escape: if RTL is already idle, the drain is done.
            sb_state_q       <= SB_IDLE;
            tracked_valid_q  <= 1'b0;
            killed_q         <= 1'b0;
          end
        end
        // ---------------------------------------------------------------------
        // RTL PTE_LOOKUP
        //
        // External req_port_i.data_rvalid is seen one cycle before the RTL uses
        // the registered data. The scoreboard captures the PTE and pulses
        // eval_pte_valid_q on the next cycle.
        // ---------------------------------------------------------------------
        SB_PTE_LOOKUP: begin
          if (flush_i || req_port_o.kill_req || killed_q) begin
            killed_q   <= 1'b1;
            sb_state_q <= SB_WAIT_RVALID;

          end else if (eval_pte_valid_q) begin
            // This cycle corresponds to RTL PTE_LOOKUP with internal
            // data_rvalid_q == 1.
            //
            // In this cycle, the RTL may:
            //   - produce shared_tlb_update_o.valid,
            //   - move to PROPAGATE_ERROR,
            //   - move to PROPAGATE_ACCESS_ERROR,
            //   - issue next-level request,
            //   - or go to LATENCY.
            //
            // Without internal state_d, we move to LATENCY and route based on
            // visible outputs/requests.
            sb_state_q <= SB_LATENCY;

          end else if (req_port_i.data_rvalid) begin
            eval_pte_q       <= dcache_pte_now;
            eval_pte_valid_q <= 1'b1;
            sb_state_q       <= SB_PTE_LOOKUP;
          end
        end
        // ---------------------------------------------------------------------
        // RTL PROPAGATE_ERROR
        // ---------------------------------------------------------------------
        SB_PROPAGATE_ERROR: begin
          sb_state_q <= SB_LATENCY;
        end
        // ---------------------------------------------------------------------
        // RTL PROPAGATE_ACCESS_ERROR
        // ---------------------------------------------------------------------
        SB_PROPAGATE_ACCESS_ERROR: begin
          sb_state_q <= SB_LATENCY;
        end
        // ---------------------------------------------------------------------
        // RTL LATENCY
        //
        // RTL LATENCY normally returns to IDLE. In the black-box checker, this
        // state also routes visible outcomes after PTE_LOOKUP evaluation.
        // ---------------------------------------------------------------------
        SB_LATENCY: begin
          if (ptw_error_o) begin
            sb_state_q <= SB_PROPAGATE_ERROR;
          end else if (ptw_access_exception_o) begin
            sb_state_q <= SB_PROPAGATE_ACCESS_ERROR;
          end else if (flush_i || req_port_o.kill_req) begin
            killed_q <= 1'b1;
            // If a memory request has already been killed, wait for its response.
            // Otherwise just remain in LATENCY until the real PTW goes idle.
            if (req_port_o.kill_req) begin
              sb_state_q <= SB_WAIT_RVALID;
            end else begin
              sb_state_q <= SB_LATENCY;
            end
          end else if (req_port_o.data_req && req_port_i.data_gnt) begin
            // Next-level page-table request with same-cycle grant.
            sb_state_q <= SB_PTE_LOOKUP;
          end else if (req_port_o.data_req) begin
            // Next-level page-table request, waiting for grant.
            sb_state_q <= SB_WAIT_GRANT;
          end else if (!ptw_active_o) begin
            // Real RTL is idle. Now the scoreboard may clear the clean tracking.
            sb_state_q       <= SB_IDLE;
            tracked_valid_q  <= 1'b0;
            killed_q         <= 1'b0;
            // raw_req_outstanding_q is cleared by the global logic above when
            // !ptw_active_o && !ptw_response.
          end
        end
        default: begin
          sb_state_q <= SB_IDLE;
        end

      endcase
    end
  end
end
  // ---------------------------------------------------------------------------
  // Environment assumptions for the compact PTW proof.
  // ---------------------------------------------------------------------------

  // Initial methodology version: do not verify Big-Endian PTE byte swapping.
  a_ptw_base_little_endian: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !mbe_i
  );

  // Initial methodology version: avoid HLVX special load behavior.
  a_ptw_base_no_hlvx: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !hlvx_inst_i
  );

  // Memory fairness: every PTW request is granted within a bounded number of cycles.
  a_mem_eventually_grants: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req |-> ##[0:PTW_MAX_GRANT_LAT] req_port_i.data_gnt
  );

  // Memory fairness: every tagged request eventually returns data.
  a_mem_eventually_returns: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.tag_valid |-> ##[1:PTW_MAX_RVALID_LAT] req_port_i.data_rvalid
  );

  // Keep the abstract memory protocol simple: no grant without request.
  a_mem_grant_only_when_requested: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_i.data_gnt |-> req_port_o.data_req
  );

  
  a_flush_eventually_deasserts: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    flush_i |-> ##[0:PTW_MAX_FLUSH_HIGH_LAT] !flush_i
  );

  // Step 1 of RVH/global-bit verification:
  // RVH may be enabled in the config, but G-stage translation is disabled.
  // This lets us verify S-stage global-bit propagation first.
  a_step1_no_g_stage_translation: assume property (
    @(posedge clk_i) disable iff (!rst_ni)
    !enable_g_translation_i && !en_ld_st_g_translation_i
  );
  // ---------------------------------------------------------------------------
  // Protocol sanity properties.
  // ---------------------------------------------------------------------------

  p_ptw_never_writes_memory: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.data_req |-> !req_port_o.data_we
  );

  p_shared_miss_pulse_matches_expected_miss: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    expected_miss_pulse |-> shared_tlb_miss_o
  );

  p_no_accepted_start_while_active: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    ptw_active_o |-> !shared_tlb_miss_o
  );

  p_accepted_start_sets_walking_instr: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    clean_start_walk |=> (walking_instr_o == $past(itlb_req_i))
  );

  // no second accepted PTW request while one is outstanding.
  p_no_clean_start_while_ptw_active: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    ptw_active_o |-> !clean_start_walk
  );

  // ---------------------------------------------------------------------------
  // Property 1: liveness/progress.
  // ---------------------------------------------------------------------------

  p_itlb_liveness_progress: assert property (
    @(posedge clk_i) disable iff (!rst_ni || flush_i)
    start_itlb_walk |->
      ##[1:PTW_MAX_WALK_LAT]
      (!ptw_active_o || ptw_response)
  );

  p_dtlb_liveness_progress: assert property (
    @(posedge clk_i) disable iff (!rst_ni || flush_i)
    start_dtlb_walk |->
      ##[1:PTW_MAX_WALK_LAT]
      (!ptw_active_o || ptw_response)
  );

  p_flush_or_kill_eventually_drains: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    (raw_req_outstanding_q && ptw_active_o && (flush_i || req_port_o.kill_req)) |->
      ##[1:PTW_MAX_DRAIN_LAT] !ptw_active_o
  );

  p_kill_request_does_not_forward_update_same_cycle: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    req_port_o.kill_req |-> !shared_tlb_update_o.valid
  );

  // ---------------------------------------------------------------------------
  // Property 2: data integrity.
  //
  // If the PTW produces a shared-TLB update for a clean tracked TLB walk,
  // then the update must match the PTE captured from the data-cache response.
  // It proves that whenever the RTL decides to update, it forwards the correct
  // returned PTE/context.
  // ---------------------------------------------------------------------------
  p_itlb_update_matches_dcache_pte: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    shared_tlb_update_o.valid &&
    tracked_valid_q &&
    tracked_is_itlb_q &&
    eval_pte_valid_q &&
    !killed_q
    |->
      (update_vaddr_o == tracked_vaddr_q) &&
      (shared_tlb_update_o.vpn  == tracked_vpn_q) &&
      (shared_tlb_update_o.asid == tracked_asid_q) &&
      (shared_tlb_update_o.vmid == tracked_vmid_q) &&
      pte_content_matches_except_global(
        shared_tlb_update_o.content,
        eval_pte_q
      ) &&
      (shared_tlb_update_o.g_content == '0)
  );

  p_dtlb_update_matches_dcache_pte: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    shared_tlb_update_o.valid &&
    tracked_valid_q &&
    !tracked_is_itlb_q &&
    eval_pte_valid_q &&
    !killed_q
    |->
      (update_vaddr_o == tracked_vaddr_q) &&
      (shared_tlb_update_o.vpn  == tracked_vpn_q) &&
      (shared_tlb_update_o.asid == tracked_asid_q) &&
      (shared_tlb_update_o.vmid == tracked_vmid_q) &&
      pte_content_matches_except_global(
        shared_tlb_update_o.content,
        eval_pte_q
      ) &&
      (shared_tlb_update_o.g_content == '0)
  );

  // ---------------------------------------------------------------------------
  // Property 3: no accepted/outstanding request -> no response.
  // ---------------------------------------------------------------------------

  p_no_response_without_raw_request: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    (!raw_req_outstanding_q && !raw_start_walk) |->
      !ptw_response
  );

  p_response_requires_raw_request: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    ptw_response |->
      (raw_req_outstanding_q || raw_start_walk)
  );

  // ---------------------------------------------------------------------------
  // Covers
  // ---------------------------------------------------------------------------

  c_itlb_start_to_update: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    start_itlb_walk
    ##[1:PTW_MAX_WALK_LAT]
    shared_tlb_update_o.valid
  );

  c_dtlb_start_to_update: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    start_dtlb_walk
    ##[1:PTW_MAX_WALK_LAT]
    shared_tlb_update_o.valid
  );

  c_start_to_error: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    clean_start_walk
    ##[1:PTW_MAX_WALK_LAT]
    ptw_error_o
  );

  c_flush_kill_seen: cover property (
    @(posedge clk_i) disable iff (!rst_ni)
    raw_req_outstanding_q && ptw_active_o && flush_i
    ##[1:PTW_MAX_WALK_LAT]
    !ptw_active_o
  );

endmodule

bind cva6_ptw cva6_ptw_scoreboard_bind i_cva6_ptw_scoreboard_bind (
    .clk_i(clk_i),
    .rst_ni(rst_ni),

    .flush_i(flush_i),

    .ptw_active_o(ptw_active_o),
    .walking_instr_o(walking_instr_o),
    .ptw_error_o(ptw_error_o),
    .ptw_access_exception_o(ptw_access_exception_o),
    .shared_tlb_miss_o(shared_tlb_miss_o),

    .enable_translation_i(enable_translation_i),
    .enable_g_translation_i(enable_g_translation_i),
    .en_ld_st_translation_i(en_ld_st_translation_i),
    .en_ld_st_g_translation_i(en_ld_st_g_translation_i),
    .v_i(v_i),
    .ld_st_v_i(ld_st_v_i),
    .hlvx_inst_i(hlvx_inst_i),
    .lsu_is_store_i(lsu_is_store_i),
    .mbe_i(mbe_i),

    .req_port_i(req_port_i),
    .req_port_o(req_port_o),

    .shared_tlb_update_o(shared_tlb_update_o),
    .update_vaddr_o(update_vaddr_o),

    .asid_i(asid_i),
    .vs_asid_i(vs_asid_i),
    .vmid_i(vmid_i),

    .shared_tlb_access_i(shared_tlb_access_i),
    .shared_tlb_hit_i(shared_tlb_hit_i),
    .shared_tlb_vaddr_i(shared_tlb_vaddr_i),
    .itlb_req_i(itlb_req_i)
);
