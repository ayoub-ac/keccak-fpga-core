// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Regression of keccak_top against the reference vectors written by
// scripts/gen_vectors.py (hashlib and pycryptodome, independent of the RTL).
// Each message is streamed with random idle cycles on valid_i (+gap=<percent>).
// Checks digest_o, digest_bits_o and that digest_valid_o pulses exactly once.
// Prints "RESULT vectors=<n> ok=<n> bad=<n>" and stops with $fatal on any error.
module tb_vectors;
  logic clk_i, rst_ni;
  initial begin clk_i = 1'b0; rst_ni = 1'b0; end
  always #5 clk_i = ~clk_i;

  logic [2:0]   mode_i = '0;
  logic         start_i = 1'b0, valid_i = 1'b0, last_i = 1'b0;
  logic [63:0]  data_i = '0;
  logic [3:0]   last_bytes_i = '0;
  logic         ready_o, digest_valid_o, busy_o;
  logic [511:0] digest_o;
  logic [9:0]   digest_bits_o;

  keccak_top dut (.*);

  int unsigned  mode, len, n_ok, n_bad, n_vec, gap_pct, dv_count;
  logic [511:0] exp;
  string        msg;
  byte unsigned bytes_q[$];

  // Counts digest_valid_o pulses for the message in flight; run_one() clears it.
  /* verilator lint_off BLKSEQ */
  always @(posedge clk_i) if (digest_valid_o) dv_count++;
  /* verilator lint_on BLKSEQ */

  task automatic run_one();
    int unsigned nbeats, sent, cyc, nb;
    logic [63:0] w;
    bytes_q.delete();
    if (msg != "x")
      for (int unsigned i = 0; i < len; i++)
        bytes_q.push_back(8'(msg.substr(int'(2*i), int'(2*i+1)).atohex()));
    @(negedge clk_i); mode_i = 3'(mode); start_i = 1'b1;
    @(negedge clk_i); start_i = 1'b0;
    nbeats = (len == 0) ? 1 : (len + 7) / 8;
    sent = 0;
    dv_count = 0;
    while (sent < nbeats) begin
      if ($urandom_range(99) < gap_pct) begin
        @(negedge clk_i);
        continue;
      end
      nb = (sent == nbeats - 1) ? (len - 8 * sent) : 8;
      w = '0;
      for (int unsigned j = 0; j < nb; j++) w[8*j +: 8] = bytes_q[8*sent + j];
      data_i = w; valid_i = 1'b1; last_i = (sent == nbeats - 1); last_bytes_i = 4'(nb);
      @(posedge clk_i);
      if (ready_o) sent++;
      @(negedge clk_i);
      valid_i = 1'b0; last_i = 1'b0;
    end
    cyc = 0;
    while (!digest_valid_o && cyc < 2000) begin @(posedge clk_i); cyc++; end
    #1;
    if (cyc >= 2000) begin
      n_bad++;
      $display("FAIL timeout mode=%0d len=%0d", mode, len);
    end else if (digest_o !== exp || digest_bits_o != ((mode inside {1, 2, 3}) ? 10'd512 : 10'd256)) begin
      n_bad++;
      $display("FAIL mode=%0d len=%0d bits=%0d\n  got %h\n  exp %h", mode, len, digest_bits_o, digest_o, exp);
    end else n_ok++;
    repeat (3) @(posedge clk_i);
    if (dv_count != 1) begin
      n_bad++;
      $display("FAIL digest_valid_o pulsed %0d times mode=%0d len=%0d", dv_count, mode, len);
    end
  endtask

  initial begin
    string path;
    int    fd;
    if (!$value$plusargs("vec=%s", path)) path = "vectors.txt";
    if (!$value$plusargs("gap=%d", gap_pct)) gap_pct = 30;
    repeat (6) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    while ($fscanf(fd, "%d %d %h %s", mode, len, exp, msg) == 4) begin
      n_vec++;
      run_one();
    end
    $fclose(fd);
    $display("RESULT vectors=%0d ok=%0d bad=%0d gap=%0d%%", n_vec, n_ok, n_bad, gap_pct);
    if (n_vec == 0 || n_bad != 0) $fatal(1, "VECTOR TESTS FAILED");
    $finish;
  end
endmodule
