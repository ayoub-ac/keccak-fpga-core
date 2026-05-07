// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Keccak-f[1600] iterative permutation (24 rounds, one round per cycle).
//
// Reference: NIST FIPS-202 §3.4 (specification of Keccak-p[1600, 24]) and
//            §3.2 (step mappings). Keccak-f[1600] = Keccak-p[1600, 24].
//
// Architecture:
//   * The 1600-bit state is held as 25 lanes of 64 bits each (FIPS-202
//     §3.1.2 lane(x,y) packing convention; see keccak_round.sv for the
//     lane indexing details).
//   * One round per cycle, 24 rounds per permutation. The round-index
//     register (round_q) selects the round constant RC[i_r] from a
//     small ROM and feeds the combinational keccak_round module.
//   * Round constants RC[0..23] are the FIPS-202 §3.2.5 / Appendix A
//     values; the table is pre-computed below as 64-bit literals.
//
// Handshake (master <-> module):
//   * start_i (single-cycle pulse, with state_i valid) loads state_i into
//     the internal register and begins the 24-round permutation.
//   * busy_o is high while the permutation runs.
//   * done_o pulses for one cycle when the permutation completes;
//     state_o is the post-permutation state and is held until the next
//     start_i.
//
// Reset: rst_ni is active-low synchronous. After reset all state is zero
//        and busy_o is low.

module keccak_f1600 (
  input  logic           clk_i,
  input  logic           rst_ni,
  input  logic           start_i,
  input  logic [1599:0]  state_i,        // 25 lanes x 64 bits

  output logic           busy_o,
  output logic           done_o,
  output logic [1599:0]  state_o
);

  // Internal lane-level views of the packed ports.
  logic [63:0] state_in_lanes [0:24];
  always_comb begin
    for (int li = 0; li < 25; li++) state_in_lanes[li] = state_i[64*li +: 64];
  end

  // ---- FIPS-202 §3.2.5 / Appendix A round constants RC[0..23] -----------
  function automatic logic [63:0] keccak_rc(input logic [4:0] i);
    case (i)
      5'd0:  keccak_rc = 64'h0000000000000001;
      5'd1:  keccak_rc = 64'h0000000000008082;
      5'd2:  keccak_rc = 64'h800000000000808a;
      5'd3:  keccak_rc = 64'h8000000080008000;
      5'd4:  keccak_rc = 64'h000000000000808b;
      5'd5:  keccak_rc = 64'h0000000080000001;
      5'd6:  keccak_rc = 64'h8000000080008081;
      5'd7:  keccak_rc = 64'h8000000000008009;
      5'd8:  keccak_rc = 64'h000000000000008a;
      5'd9:  keccak_rc = 64'h0000000000000088;
      5'd10: keccak_rc = 64'h0000000080008009;
      5'd11: keccak_rc = 64'h000000008000000a;
      5'd12: keccak_rc = 64'h000000008000808b;
      5'd13: keccak_rc = 64'h800000000000008b;
      5'd14: keccak_rc = 64'h8000000000008089;
      5'd15: keccak_rc = 64'h8000000000008003;
      5'd16: keccak_rc = 64'h8000000000008002;
      5'd17: keccak_rc = 64'h8000000000000080;
      5'd18: keccak_rc = 64'h000000000000800a;
      5'd19: keccak_rc = 64'h800000008000000a;
      5'd20: keccak_rc = 64'h8000000080008081;
      5'd21: keccak_rc = 64'h8000000000008080;
      5'd22: keccak_rc = 64'h0000000080000001;
      5'd23: keccak_rc = 64'h8000000080008008;
      default: keccak_rc = 64'h0;
    endcase
  endfunction

  // ---- FSM ---------------------------------------------------------------
  typedef enum logic [1:0] {
    F_IDLE = 2'd0,
    F_RUN  = 2'd1,
    F_DONE = 2'd2
  } state_e;

  state_e      fsm_q, fsm_d;
  logic [4:0]  round_q, round_d;          // 0..23 (need 5 bits)
  logic [63:0] st_q   [0:24];
  logic [63:0] st_d   [0:24];

  // ---- combinational round update ---------------------------------------
  logic [63:0]   rc_now;
  logic [1599:0] st_q_packed;
  logic [1599:0] round_out_packed;
  logic [63:0]   round_out [0:24];

  assign rc_now = keccak_rc(round_q);

  always_comb begin
    for (int li = 0; li < 25; li++) st_q_packed[64*li +: 64] = st_q[li];
  end

  keccak_round u_round (
    .state_i (st_q_packed),
    .rc_i    (rc_now),
    .state_o (round_out_packed)
  );

  always_comb begin
    for (int li = 0; li < 25; li++) round_out[li] = round_out_packed[64*li +: 64];
  end

  // ---- next-state logic --------------------------------------------------
  always_comb begin
    fsm_d   = fsm_q;
    round_d = round_q;
    for (int i = 0; i < 25; i++) st_d[i] = st_q[i];

    case (fsm_q)
      F_IDLE: begin
        if (start_i) begin
          for (int i = 0; i < 25; i++) st_d[i] = state_in_lanes[i];
          round_d = 5'd0;
          fsm_d   = F_RUN;
        end
      end

      F_RUN: begin
        for (int i = 0; i < 25; i++) st_d[i] = round_out[i];
        if (round_q == 5'd23) begin
          fsm_d = F_DONE;
        end else begin
          round_d = round_q + 5'd1;
        end
      end

      F_DONE: begin
        // hold state, pulse done_o for one cycle, return to idle
        fsm_d = F_IDLE;
      end

      default: fsm_d = F_IDLE;
    endcase
  end

  // ---- registers ---------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      fsm_q   <= F_IDLE;
      round_q <= 5'd0;
      for (int i = 0; i < 25; i++) st_q[i] <= 64'd0;
    end else begin
      fsm_q   <= fsm_d;
      round_q <= round_d;
      for (int i = 0; i < 25; i++) st_q[i] <= st_d[i];
    end
  end

  // ---- outputs -----------------------------------------------------------
  assign busy_o = (fsm_q == F_RUN);
  assign done_o = (fsm_q == F_DONE);

  always_comb begin
    for (int li = 0; li < 25; li++) state_o[64*li +: 64] = st_q[li];
  end

endmodule
