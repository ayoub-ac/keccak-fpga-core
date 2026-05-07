// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Functional coverage collector for keccak_top. Counts hits on the bins below
// from C++ via Verilator's --public-flat-rw, so the harness can read them at
// the end of the simulation and print a coverage percentage.
//
// Bins:
//   c_mode_sha3_256    SHA3-256 variant exercised
//   c_mode_sha3_512    SHA3-512 variant exercised
//   c_mode_shake128    SHAKE128 variant exercised
//   c_mode_shake256    SHAKE256 variant exercised
//   c_mode_eth_k256    Ethereum Keccak-256 variant exercised
//   c_single_block     a hash completed in a single rate block
//   c_multi_block      a hash spanned >= 2 rate blocks (more than one
//                      keccak_f1600 invocation during absorb)
//   c_back_to_back     two start_i'd hashes back-to-back
//   c_reset_mid_hash   reset asserted while a hash is in flight
//   c_empty_message    a hash on an empty (zero-byte) message
//
// Total: 10 bins. Coverage % = hits / 10 * 100.

module keccak_cov (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         start_i,
  input logic [2:0]   mode_i,
  input logic         valid_i,
  input logic         ready_o,
  input logic         last_i,
  input logic [3:0]   last_bytes_i,
  input logic         digest_valid_o,
  input logic         perm_start,
  input logic [2:0]   tstate_q
);

  localparam logic [2:0] MODE_SHA3_256 = 3'd0;
  localparam logic [2:0] MODE_SHA3_512 = 3'd1;
  localparam logic [2:0] MODE_SHAKE128 = 3'd2;
  localparam logic [2:0] MODE_SHAKE256 = 3'd3;
  localparam logic [2:0] MODE_ETH_K256 = 3'd4;

  localparam logic [2:0] T_IDLE = 3'd0;

  logic c_mode_sha3_256  /*verilator public*/;
  logic c_mode_sha3_512  /*verilator public*/;
  logic c_mode_shake128  /*verilator public*/;
  logic c_mode_shake256  /*verilator public*/;
  logic c_mode_eth_k256  /*verilator public*/;
  logic c_single_block   /*verilator public*/;
  logic c_multi_block    /*verilator public*/;
  logic c_back_to_back   /*verilator public*/;
  logic c_reset_mid_hash /*verilator public*/;
  logic c_empty_message  /*verilator public*/;

  // Per-hash trackers.
  logic [3:0] perm_count_q;       // permutations during this hash's absorb
  logic       hash_in_flight_q;   // a start was seen and digest not yet emitted
  logic       prev_done_q;        // for back-to-back detection

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      if (hash_in_flight_q) c_reset_mid_hash <= 1'b1;
      perm_count_q     <= 4'd0;
      hash_in_flight_q <= 1'b0;
      prev_done_q      <= 1'b0;
    end else begin
      // Mode coverage on start_i pulse.
      if (start_i) begin
        case (mode_i)
          MODE_SHA3_256: c_mode_sha3_256 <= 1'b1;
          MODE_SHA3_512: c_mode_sha3_512 <= 1'b1;
          MODE_SHAKE128: c_mode_shake128 <= 1'b1;
          MODE_SHAKE256: c_mode_shake256 <= 1'b1;
          MODE_ETH_K256: c_mode_eth_k256 <= 1'b1;
          default: ;
        endcase
        // Back-to-back: a previous hash just finished and another start
        // arrives.
        if (prev_done_q) c_back_to_back <= 1'b1;
        perm_count_q     <= 4'd0;
        hash_in_flight_q <= 1'b1;
        prev_done_q      <= 1'b0;
      end

      // Permutation count tracker.
      if (perm_start) begin
        perm_count_q <= perm_count_q + 4'd1;
      end

      // Detect "empty message": valid_i + last_i with last_bytes_i = 0.
      if (valid_i && ready_o && last_i && (last_bytes_i == 4'd0)) begin
        c_empty_message <= 1'b1;
      end

      // Classify single vs multi block on the digest pulse.
      if (digest_valid_o) begin
        // perm_count includes the final padded block's permutation, so
        // single_block = exactly 1 permutation; multi_block = 2+.
        if (perm_count_q == 4'd1) c_single_block <= 1'b1;
        else if (perm_count_q >= 4'd2) c_multi_block <= 1'b1;
        prev_done_q      <= 1'b1;
        hash_in_flight_q <= 1'b0;
      end
    end
  end

  initial begin
    c_mode_sha3_256  = 1'b0;
    c_mode_sha3_512  = 1'b0;
    c_mode_shake128  = 1'b0;
    c_mode_shake256  = 1'b0;
    c_mode_eth_k256  = 1'b0;
    c_single_block   = 1'b0;
    c_multi_block    = 1'b0;
    c_back_to_back   = 1'b0;
    c_reset_mid_hash = 1'b0;
    c_empty_message  = 1'b0;
  end

  // Reference unused signals to keep lint quiet
  wire _unused_ok = &{1'b0, tstate_q, 1'b0};

endmodule
