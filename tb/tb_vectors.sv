// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Regression of keccak_top against the reference vectors written by
// scripts/gen_vectors.py (hashlib and pycryptodome, independent of the RTL).
//
// For every message:
//   * the message is streamed with random idle cycles on valid_i (+gap=<percent>)
//     while mode_i is driven with random values after the start_i cycle, so
//     the result also shows that mode_i is latched at start_i;
//   * digest_o, digest_bits_o and a single digest_valid_o pulse are checked.
// Every fifth message is first aborted by a reset of 1 to 4 cycles at a random
// beat, with valid_i and start_i driven during the reset; ready_o, busy_o and
// digest_valid_o must be low from the first reset edge on, and the message is
// then hashed again from start_i.
// With +gap=0 every third message is also hashed a second time with other
// random bytes of the same length; the cycle count from start_i to
// digest_valid_o must not change (latency depends on length and mode only).
// Prints "RESULT vectors=<n> ok=<n> bad=<n> ..." and stops with $fatal on any error.
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

  int unsigned  mode, len, n_ok, n_bad, n_vec, gap_pct, dv_count, n_resets, n_timing;
  logic [511:0] exp;
  string        msg;
  byte unsigned bytes_q[$];
  longint unsigned cyc_now;

  // Cycle counter and digest_valid_o pulse counter; run_one() clears dv_count.
  /* verilator lint_off BLKSEQ */
  always @(posedge clk_i) begin
    cyc_now++;
    if (digest_valid_o) dv_count++;
  end
  /* verilator lint_on BLKSEQ */

  // Streams bytes_q as one message. abort_at >= 0 resets the core for
  // rst_cycles cycles once abort_at beats have been accepted and returns.
  // Returns the cycles from the start_i edge to digest_valid_o (0 if aborted).
  task automatic stream(input int abort_at, input int rst_cycles, output longint unsigned latency);
    int unsigned nbeats, sent, cyc, nb;
    longint unsigned t0;
    logic [63:0] w;
    latency = 0;
    @(negedge clk_i); mode_i = 3'(mode); start_i = 1'b1;
    @(negedge clk_i); start_i = 1'b0; t0 = cyc_now;
    nbeats = (len == 0) ? 1 : (len + 7) / 8;
    sent = 0;
    dv_count = 0;
    while (sent < nbeats) begin
      mode_i = 3'($urandom_range(7));
      if (abort_at >= 0 && sent == unsigned'(abort_at)) begin
        rst_ni = 1'b0; valid_i = 1'b1; start_i = 1'($urandom_range(1)); data_i = {$urandom, $urandom};
        @(posedge clk_i); #1;
        for (int k = 0; k < rst_cycles; k++) begin
          if (ready_o || busy_o || digest_valid_o) begin
            n_bad++;
            $display("FAIL outputs high during reset: ready=%0b busy=%0b dv=%0b", ready_o, busy_o, digest_valid_o);
          end
          if (k + 1 < rst_cycles) begin @(posedge clk_i); #1; end
        end
        @(negedge clk_i); rst_ni = 1'b1; valid_i = 1'b0; start_i = 1'b0;
        n_resets++;
        return;
      end
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
    while (!digest_valid_o && cyc < 4000) begin @(posedge clk_i); cyc++; end
    #1;
    latency = (cyc >= 4000) ? 0 : cyc_now - t0;
  endtask

  task automatic run_one();
    longint unsigned lat, lat2;
    bytes_q.delete();
    if (msg != "x")
      for (int unsigned i = 0; i < len; i++)
        bytes_q.push_back(8'(msg.substr(int'(2*i), int'(2*i+1)).atohex()));
    if (n_vec % 5 == 0) stream(int'($urandom_range((len + 7) / 8)), int'($urandom_range(4, 1)), lat);
    stream(-1, 0, lat);
    if (lat == 0) begin
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
    if (gap_pct == 0 && n_vec % 3 == 0) begin
      foreach (bytes_q[i]) bytes_q[i] = 8'($urandom);
      stream(-1, 0, lat2);
      n_timing++;
      if (lat2 != lat) begin
        n_bad++;
        $display("FAIL latency depends on data: mode=%0d len=%0d %0d vs %0d cycles", mode, len, lat, lat2);
      end
      repeat (3) @(posedge clk_i);
    end
  endtask

  initial begin
    string path;
    int    fd;
    if (!$value$plusargs("vec=%s", path)) path = "vectors.txt";
    if (!$value$plusargs("gap=%d", gap_pct)) gap_pct = 30;
    @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);
    while ($fscanf(fd, "%d %d %h %s", mode, len, exp, msg) == 4) begin
      run_one();
      n_vec++;
    end
    $fclose(fd);
    $display("RESULT vectors=%0d ok=%0d bad=%0d gap=%0d%% resets=%0d timing_pairs=%0d",
             n_vec, n_ok, n_bad, gap_pct, n_resets, n_timing);
    if (n_vec == 0 || n_bad != 0) $fatal(1, "VECTOR TESTS FAILED");
    $finish;
  end
endmodule
