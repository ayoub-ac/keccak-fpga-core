// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Top-level testbench wrapper for keccak_top. Stimulus is driven from the C++
// harness (tb/sim_main.cpp); this module re-exports the DUT ports and binds:
//   * tb/keccak_assertions.sv  -- SVA protocol checks
//   * tb/keccak_cov.sv         -- functional coverage collector

module keccak_top_tb (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [2:0]   mode_i,
  input  logic         start_i,
  input  logic [63:0]  data_i,
  input  logic         valid_i,
  input  logic         last_i,
  input  logic [3:0]   last_bytes_i,
  output logic         ready_o,
  output logic [511:0] digest_o,
  output logic [9:0]   digest_bits_o,
  output logic         digest_valid_o,
  output logic         busy_o
);

  keccak_top u_dut (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .mode_i         (mode_i),
    .start_i        (start_i),
    .data_i         (data_i),
    .valid_i        (valid_i),
    .last_i         (last_i),
    .last_bytes_i   (last_bytes_i),
    .ready_o        (ready_o),
    .digest_o       (digest_o),
    .digest_bits_o  (digest_bits_o),
    .digest_valid_o (digest_valid_o),
    .busy_o         (busy_o)
  );

  // Hierarchical references into the DUT for assertion / coverage observation.
  wire [4:0] dut_round_q   = u_dut.u_perm.round_q;
  wire [1:0] dut_perm_fsm  = u_dut.u_perm.fsm_q;
  wire       dut_perm_st   = u_dut.perm_start;
  wire       dut_perm_done = u_dut.perm_done;
  wire       dut_pad_valid = u_dut.pad_block_valid;
  wire [7:0] dut_fill_q    = u_dut.fill_q;
  wire [2:0] dut_tstate_q  = u_dut.tstate_q;
  // Effective rate at the moment - read combinationally from the mode_q
  // register inside the DUT via the rate_for() function image.
  wire [7:0] dut_rate_bytes;
  assign dut_rate_bytes =
      (u_dut.mode_q == 3'd0) ? 8'd136 :   // SHA3-256
      (u_dut.mode_q == 3'd1) ? 8'd72  :   // SHA3-512
      (u_dut.mode_q == 3'd2) ? 8'd168 :   // SHAKE128
      (u_dut.mode_q == 3'd3) ? 8'd136 :   // SHAKE256
                               8'd136;    // ETH-Keccak-256 / default

  keccak_assertions u_assert (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .start_i         (start_i),
    .valid_i         (valid_i),
    .ready_o         (ready_o),
    .digest_valid_o  (digest_valid_o),
    .busy_o          (busy_o),
    .digest_o        (digest_o),
    .round_q         (dut_round_q),
    .perm_fsm_q      (dut_perm_fsm),
    .perm_start      (dut_perm_st),
    .perm_done       (dut_perm_done),
    .pad_block_valid (dut_pad_valid),
    .fill_q          (dut_fill_q),
    .rate_bytes      (dut_rate_bytes)
  );

  keccak_cov u_cov (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (start_i),
    .mode_i         (mode_i),
    .valid_i        (valid_i),
    .ready_o        (ready_o),
    .last_i         (last_i),
    .last_bytes_i   (last_bytes_i),
    .digest_valid_o (digest_valid_o),
    .perm_start     (dut_perm_st),
    .tstate_q       (dut_tstate_q)
  );

endmodule
