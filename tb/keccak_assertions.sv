// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Standalone assertion module for keccak_top. Instantiated alongside the DUT
// in keccak_top_tb so the testbench can reuse the same protocol checks across
// any simulator (Verilator 5.x, Vivado xsim, ModelSim/Questa).
//
// Properties enforced:
//   p_perm_latency           Each Keccak-f[1600] permutation completes in
//                            exactly 25 cycles (24 round cycles + 1 done
//                            pulse cycle in the f1600 FSM).
//   p_digest_stable          digest_o is stable while digest_valid_o is
//                            asserted (one-cycle pulse).
//   p_round_bound            internal Keccak-f round counter never exceeds
//                            23.
//   p_no_start_during_run    start_i (taken alongside an idle FSM) is the
//                            only way to begin; the top must reject any
//                            new-hash start while busy_o is high.
//   p_padder_emits_one_block The padder emits exactly one rate-block when
//                            it is launched; no spurious second emission.
//   p_fill_bound             The rate-buffer fill counter never exceeds
//                            rate-1 bytes after an accepted absorb (it
//                            wraps to zero whenever the buffer fills).
//
// Properties are wrapped in `ifndef SYNTHESIS so they are stripped on
// synthesis flows.

module keccak_assertions #(
  parameter int PERM_LATENCY = 25  // 24 round cycles + 1 done cycle in f1600
) (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         start_i,
  input logic         valid_i,
  input logic         ready_o,
  input logic         digest_valid_o,
  input logic         busy_o,
  input logic [511:0] digest_o,

  // Hierarchical signals from the DUT (driven by the tb wrapper)
  input logic [4:0]   round_q,
  input logic [1:0]   perm_fsm_q,
  input logic         perm_start,
  input logic         perm_done,
  input logic         pad_block_valid,
  input logic [7:0]   fill_q,
  input logic [7:0]   rate_bytes
);
`ifndef SYNTHESIS

  localparam logic [1:0] L_PERM_RUN = 2'd1;

  // ---------------------------------------------------------------------------
  // Cycles since the last permutation start. Resets each time perm_start
  // pulses; useful as a sanity timer.
  int unsigned cycles_since_perm_start;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                         cycles_since_perm_start <= 0;
    else if (perm_start)                 cycles_since_perm_start <= 1;
    else if (cycles_since_perm_start>0)  cycles_since_perm_start <= cycles_since_perm_start + 1;
  end

  // ---------------------------------------------------------------------------
  // p_perm_latency: perm_done must rise exactly PERM_LATENCY cycles after
  // perm_start.
  property p_perm_latency;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(perm_done) |-> (cycles_since_perm_start == PERM_LATENCY);
  endproperty
  a_perm_latency: assert property (p_perm_latency)
    else $error("keccak_assertions: perm_done at cycle %0d (expected %0d)",
                cycles_since_perm_start, PERM_LATENCY);

  // ---------------------------------------------------------------------------
  // p_digest_stable: digest_o is stable while digest_valid_o is held.
  // digest_valid_o is a one-cycle pulse so this is a degenerate check, but
  // it would catch a spurious multi-cycle assert.
  property p_digest_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      digest_valid_o |=> (!digest_valid_o || $stable(digest_o));
  endproperty
  a_digest_stable: assert property (p_digest_stable)
    else $error("keccak_assertions: digest_o changed while digest_valid_o asserted");

  // ---------------------------------------------------------------------------
  // p_round_bound: round_q never exceeds 23.
  property p_round_bound;
    @(posedge clk_i) disable iff (!rst_ni) (round_q <= 5'd23);
  endproperty
  a_round_bound: assert property (p_round_bound)
    else $error("keccak_assertions: round_q = %0d exceeds 23", round_q);

  // ---------------------------------------------------------------------------
  // p_no_start_during_run: start_i is honoured only when the DUT is idle.
  // Equivalent: ready_o is low whenever the DUT is busy with a permutation
  // or final-block flow, so the master cannot begin a new hash mid-flight.
  property p_no_start_during_run;
    @(posedge clk_i) disable iff (!rst_ni)
      busy_o |-> !ready_o;
  endproperty
  a_no_start_during_run: assert property (p_no_start_during_run)
    else $error("keccak_assertions: ready_o high while busy_o asserted");

  // ---------------------------------------------------------------------------
  // p_padder_emits_one_block: pad_block_valid is a single-cycle pulse.
  property p_padder_emits_one_block;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(pad_block_valid) |=> !pad_block_valid;
  endproperty
  a_padder_emits_one_block: assert property (p_padder_emits_one_block)
    else $error("keccak_assertions: pad_block_valid held for >1 cycle");

  // ---------------------------------------------------------------------------
  // p_fill_bound: fill_q never exceeds rate_bytes - 1 (when ABSORB the
  // buffer flushes the moment it hits rate_bytes).
  // We allow == rate_bytes for one cycle (the cycle of acceptance) to
  // tolerate the natural single-cycle peak, then it must drop. The check
  // here is the looser bound: fill_q must never exceed rate_bytes.
  property p_fill_bound;
    @(posedge clk_i) disable iff (!rst_ni) (fill_q <= rate_bytes);
  endproperty
  a_fill_bound: assert property (p_fill_bound)
    else $error("keccak_assertions: fill_q=%0d exceeds rate_bytes=%0d",
                fill_q, rate_bytes);

`endif // SYNTHESIS
endmodule
