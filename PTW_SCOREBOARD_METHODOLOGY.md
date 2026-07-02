# CVA6 PTW Scoreboard Verification Methodology

## Verification target

The CVA6 PTW, or Page Table Walker, is verified as a transaction controller rather than as a storage array. The private TLB and shared TLB scoreboards tracked stored translations. The PTW scoreboard tracks a miss transaction: a serialized shared-TLB miss enters the PTW, the PTW requests one or more Page Table Entries from the data cache, and the PTW eventually produces either a shared-TLB update, a PTW page fault, a PMP access exception, or a flushed/killed completion.

## First compact proof scope

The first proof target intentionally keeps the environment small:

- RVH, the RISC-V Hypervisor extension, is disabled.
- Svnapot, naturally aligned power-of-two page support, is disabled.
- PMP, Physical Memory Protection, functionality is not verified; the checker assumes PTW memory access is allowed.
- Big-endian PTE byte swapping is not verified; the checker assumes little-endian mode.
- The PTW receives a serialized miss stream from the shared TLB.

This makes the main data-integrity rule simple: for a legal leaf PTE returned by the data cache, the PTW must forward the same PTE in `shared_tlb_update_o.content`.

## Main PTW RTL behavior

The PTW starts from the shared-TLB miss side:

```systemverilog
shared_tlb_access_i && !shared_tlb_hit_i
```

It latches the missed virtual address, request side, ASID, and VMID context. It then issues a data-cache read for a page-table entry through `req_port_o`. The data cache accepts the request with `req_port_i.data_gnt` and later returns PTE data with `req_port_i.data_rvalid` and `req_port_i.data_rdata`.

The RTL states are:

- `IDLE`: no active walk.
- `WAIT_GRANT`: request a PTE from the data cache.
- `PTE_LOOKUP`: consume returned PTE data.
- `PROPAGATE_ERROR`: raise a page-fault style PTW error.
- `PROPAGATE_ACCESS_ERROR`: raise a PMP/access exception.
- `KILL_REQ`: kill a granted request after flush.
- `WAIT_RVALID`: drain the memory response after a flush/kill.
- `LATENCY`: one-cycle cleanup before returning to idle.

## Compact scoreboard FSM

The abstract scoreboard uses five states:

- `SB_IDLE`: no tracked PTW request.
- `SB_WAIT_GRANT`: a miss was tracked and the scoreboard waits for cache grant.
- `SB_WAIT_RVALID`: a cache request was granted and the scoreboard waits for returned PTE data.
- `SB_RETURNED`: returned PTE data has been captured; if it is a legal leaf, it must be forwarded to the shared TLB.
- `SB_KILLED`: a flush/kill interrupted the walk; the scoreboard waits until the PTW drains and becomes inactive.

## Property set

### 1. Liveness / progress

Under bounded memory fairness assumptions, a PTW transaction must make progress. A started walk must eventually reach one of the following conditions:

- `shared_tlb_update_o.valid`, meaning the PTW produced a successful update;
- `ptw_error_o`, meaning the PTW detected an invalid page-table walk result;
- `ptw_access_exception_o`, meaning access was denied by PMP or memory protection;
- `!ptw_active_o`, meaning the PTW drained or returned to idle, especially after flush/kill.

### 2. Data integrity

For an instruction-side walk, if the data cache returns a legal executable leaf PTE, then the PTW must forward the same PTE to the shared TLB:

```text
tracked ITLB miss + returned legal instruction leaf PTE
  -> shared_tlb_update_o.valid
  -> shared_tlb_update_o.content == returned PTE
  -> update_vaddr_o, vpn, asid, vmid match the tracked request
```

For a data-side walk, if the data cache returns a legal readable leaf PTE, and for stores also writable and dirty, then the same rule holds:

```text
tracked DTLB miss + returned legal data leaf PTE
  -> shared_tlb_update_o.valid
  -> shared_tlb_update_o.content == returned PTE
  -> update_vaddr_o, vpn, asid, vmid match the tracked request
```

### 3. No response without request

The scoreboard FSM tracks whether a PTW transaction exists. While idle and without a new start, the PTW must not emit a shared-TLB update, PTW error, or access exception.

### 4. Serialized PTW request boundary

The standalone PTW scoreboard does not include a "no simultaneous ITLB and DTLB miss" checker, because the PTW does not see separate ITLB-miss and DTLB-miss inputs. The PTW sees only one serialized shared-TLB miss request plus the one-bit source indicator `itlb_req_i`. Therefore, the PTW-level proof tracks one accepted request at a time and checks that `walking_instr_o` stays consistent with the tracked request side.

A separate integration-level checker can later be added at the MMU/shared-TLB boundary if both raw ITLB and DTLB miss signals are visible there.

## Extension roadmap

1. Prove the base PTW environment elaborates and all simple protocol checks pass.
2. Prove liveness under bounded data-cache fairness.
3. Prove ITLB data integrity for legal leaf PTEs.
4. Prove DTLB data integrity for legal leaf PTEs.
5. Add invalid PTE and error-path properties.
6. Add pointer PTE and multi-level page-table walk properties.
7. Add flush/kill corner cases.
8. Add PMP denial behavior as a separate proof group.
9. Re-enable Svnapot and add NAPOT-specific content-matching rules.
10. Re-enable RVH and split the data-integrity rules into `content` and `g_content` for S/VS-stage and G-stage translation.
11. Move from standalone PTW to MMU integration, proving that PTW updates are consumed correctly by the shared TLB and then forwarded to the corresponding private TLB.
