# CVA6 PTW Scoreboard Verification

This branch contains the current formal scoreboard milestone for the CVA6 PTW, the Page Table Walker. The goal is to verify the PTW from its public interface using a black-box scoreboard, without binding internal RTL signals such as `state_q`, `data_rvalid_q`, `data_rdata_q`, `ptw_stage_q`, or `global_mapping_q`.

## What the PTW does

The PTW is responsible for servicing a shared TLB miss. TLB means Translation Lookaside Buffer.
When the shared TLB cannot translate a virtual address, the PTW walks the page table by issuing memory requests to fetch Page Table Entries, or PTEs. Depending on the returned PTEs, the PTW either:

- produces a `shared_tlb_update_o.valid` update,
- raises `ptw_error_o` for page-fault-like errors,
- raises `ptw_access_exception_o` for PMP access exceptions,
- or drains/cancels the walk after `flush_i` or `kill_req`.

## Current verification milestone

The current scoreboard verifies the base PTW behavior using only the PTW interface. The verified scope is:

- PTW start detection through `shared_tlb_miss_o`.
- ITLB and DTLB walk tracking.
- Request/response causality.
- Bounded liveness/progress.
- Flush/kill drain behavior.
- Update data integrity for ITLB and DTLB updates.
- S-stage PTE global-bit propagation through `content.g`.

The scoreboard deliberately avoids reading internal PTW state. Its FSM uses RTL-like state names only as a readable phase model; it is not a cycle-exact copy of the RTL FSM.

## Main files

Typical project files for this milestone are:

```text
cva6_ptw.sv                         PTW RTL under verification
cva6_ptw_formal_top.sv              Formal top module
cva6_ptw_formal_pkg.sv              Formal configuration/package
cva6_ptw_scoreboard_bind_2.sv       Scoreboard bind file
run_onespin_ptw.tcl                 OneSpin/Jasper-style run script
```

## Main assumptions

This milestone focuses on the base PTW path plus S-stage global-bit behavior. Some features are intentionally constrained out:

- Big-endian PTE byte swapping is disabled with `!mbe_i`.
- HLVX special load behavior is disabled with `!hlvx_inst_i`.
- G-stage translation is disabled with `!enable_g_translation_i && !en_ld_st_g_translation_i`.
- S-stage translation is enabled with `enable_translation_i && en_ld_st_translation_i`.
- The abstract memory/cache model is constrained to eventually grant PTW requests and eventually return data.

## Main properties

The scoreboard contains these major property groups:

### Protocol sanity

- PTW never writes memory.
- A visible shared-TLB miss pulse matches the expected miss condition.
- No new clean start is accepted while the PTW is active.
- An accepted instruction walk sets `walking_instr_o` consistently.

### Liveness/progress

A clean ITLB or DTLB walk should eventually produce a visible outcome within the configured bound:

```text
shared_tlb_update_o.valid || ptw_error_o || ptw_access_exception_o
```

Flush/kill behavior is checked separately: if a walk is cancelled, the PTW must eventually drain to idle.

### Data integrity

When the PTW produces a shared-TLB update for a clean tracked walk, the scoreboard checks:

- `update_vaddr_o` matches the tracked virtual address.
- `shared_tlb_update_o.vpn` matches the tracked VPN.
- `shared_tlb_update_o.asid` matches the tracked ASID.
- `shared_tlb_update_o.vmid` matches the tracked VMID.
- `shared_tlb_update_o.content` matches the PTE returned from memory, including the expected global bit.

## Global-bit solution

The important RTL behavior is that the PTW samples every memory response into internal registers:

```systemverilog
data_rdata_q  <= endian_data;
data_rvalid_q <= req_port_i.data_rvalid;
```

But the RTL only uses the sampled PTE for global-bit accumulation when it is in `PTE_LOOKUP`:

```systemverilog
if (data_rvalid_q) begin
  if (pte.g && (ptw_stage_q == S_STAGE || !CVA6Cfg.RVH))
    global_mapping_n = 1'b1;
end
```

The final update uses:

```systemverilog
shared_tlb_update_o.content = pte | (global_mapping_q << 5);
```

The final scoreboard solution mirrors this behavior in two steps:

1. Mirror every external memory response into `eval_pte_q` and `eval_pte_valid_q`.
2. Accumulate `eval_pte_q.g` into `global_seen_q` only during the scoreboard PTE-evaluation phase.


## Current limitations / future work

The following features are not yet fully verified in this milestone:

- Full RVH / G-stage translation.
- `g_content` behavior for G-stage translation.
- PMP access-exception reachability and PMP denial/allow modeling.
- Svnapot / NAPOT 64 KiB page handling.
- Big-endian PTE byte swapping.
- HLVX special load behavior.

These should be added as separate verification milestones, but this will make the verification into a full functional prrof instead of an sbtract scoreboard
due to the necesity of implementing the intwernal signals and RTL behaviour to allow scoreboard to support these functionalities.

## Running the proof

From the formal environment, run the provided TCL script, for example:

```tcl
source run_onespin_ptw.tcl
```

Then check the assertion status. The expected current milestone result is that all base properties pass, including the ITLB and DTLB data-integrity properties with `content.g`.
