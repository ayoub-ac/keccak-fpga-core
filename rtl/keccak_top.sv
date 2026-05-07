// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Keccak / SHA-3 streaming top with mode select.
//
// Reference: NIST FIPS-202, "SHA-3 Standard", §4 (sponge construction),
//            §6 (SHA-3 hash and XOF specifications), §B.1 (bit-string
//            conversion conventions). Ethereum's Keccak-256 follows the
//            *original* Keccak submission (ETH yellow paper, Appendix A);
//            see notes in keccak_padder.sv.
//
// Variants supported (mode_i select):
//   3'd0  SHA3-256             rate = 1088 bits = 136 bytes, dom = 0x06,
//                              squeeze = 256 bits
//   3'd1  SHA3-512             rate = 576 bits = 72 bytes,   dom = 0x06,
//                              squeeze = 512 bits
//   3'd2  SHAKE128             rate = 1344 bits = 168 bytes, dom = 0x1f,
//                              squeeze = up to 512 bits (fixed by this top)
//   3'd3  SHAKE256             rate = 1088 bits = 136 bytes, dom = 0x1f,
//                              squeeze = up to 512 bits (fixed by this top)
//   3'd4  Ethereum Keccak-256  rate = 1088 bits = 136 bytes, dom = 0x01,
//                              squeeze = 256 bits
//
// Architecture:
//   * Caller streams the message in 64-bit (8-byte) chunks. valid_i +
//     ready_o handshake. Bytes 0..7 of the current chunk live in
//     bits [7:0] .. [63:56] of data_i (LSB-first within each lane, per
//     FIPS-202 §B.1). last_i marks the final chunk; last_bytes_i counts
//     valid bytes within that final chunk (1..8). For an empty message,
//     drive last_i with last_bytes_i = 0.
//   * The top accumulates bytes into a 168-byte rate buffer (RATE_MAX);
//     when the buffer is full it XORs the buffer's first rate-byte prefix
//     into the sponge state and triggers Keccak-f[1600].
//   * On last_i the top pads the partial buffer per the mode-specific
//     padding rule (FIPS-202 §5.1 + the mode's domain byte) and absorbs
//     the final block.
//   * The top then squeezes the digest from the state's first
//     squeeze-bytes prefix and pulses digest_valid_o for one cycle.
//     For SHAKE variants we squeeze 512 bits (one rate-block worth);
//     longer squeezes are out of scope for this top (the underlying
//     keccak_f1600 supports them via repeated invocation, but this top
//     wraps a fixed 256/512-bit output).
//
// Reset: rst_ni is active-low synchronous. After reset all state is zero
//        and ready_o is high; mode_i must be stable when start_i pulses.

module keccak_top (
  input  logic         clk_i,
  input  logic         rst_ni,

  // ---- mode + start --------------------------------------------------
  input  logic [2:0]   mode_i,        // see header
  input  logic         start_i,       // pulse to begin a new hash

  // ---- input stream --------------------------------------------------
  input  logic [63:0]  data_i,
  input  logic         valid_i,
  input  logic         last_i,
  input  logic [3:0]   last_bytes_i,  // 0..8, valid bytes in last word
  output logic         ready_o,

  // ---- output --------------------------------------------------------
  output logic [511:0] digest_o,      // up to 512 bits; 256-bit hashes
                                      // place the digest in bits [511:256]
                                      // (most-significant) and zero the
                                      // low 256 bits. SHA3-512 and SHAKE
                                      // (squeeze 512 bits) fill all 512.
  output logic [9:0]   digest_bits_o, // 256 or 512
  output logic         digest_valid_o,
  output logic         busy_o
);

  // ---------------------------------------------------------------------
  // Mode -> (rate_bytes, domain_byte, squeeze_bits) lookup
  // ---------------------------------------------------------------------
  localparam logic [2:0] M_SHA3_256 = 3'd0;
  localparam logic [2:0] M_SHA3_512 = 3'd1;
  localparam logic [2:0] M_SHAKE128 = 3'd2;
  localparam logic [2:0] M_SHAKE256 = 3'd3;
  localparam logic [2:0] M_ETH_K256 = 3'd4;

  localparam int RATE_MAX = 168;   // SHAKE128, in bytes

  function automatic logic [7:0] rate_for(input logic [2:0] m);
    case (m)
      M_SHA3_256: rate_for = 8'd136;   // 1088/8
      M_SHA3_512: rate_for = 8'd72;    //  576/8
      M_SHAKE128: rate_for = 8'd168;   // 1344/8
      M_SHAKE256: rate_for = 8'd136;
      M_ETH_K256: rate_for = 8'd136;
      default:    rate_for = 8'd136;
    endcase
  endfunction

  function automatic logic [7:0] domain_for(input logic [2:0] m);
    case (m)
      M_SHA3_256: domain_for = 8'h06;
      M_SHA3_512: domain_for = 8'h06;
      M_SHAKE128: domain_for = 8'h1f;
      M_SHAKE256: domain_for = 8'h1f;
      M_ETH_K256: domain_for = 8'h01;
      default:    domain_for = 8'h06;
    endcase
  endfunction

  function automatic logic [9:0] squeeze_for(input logic [2:0] m);
    case (m)
      M_SHA3_256: squeeze_for = 10'd256;
      M_SHA3_512: squeeze_for = 10'd512;
      M_SHAKE128: squeeze_for = 10'd512;
      M_SHAKE256: squeeze_for = 10'd512;
      M_ETH_K256: squeeze_for = 10'd256;
      default:    squeeze_for = 10'd256;
    endcase
  endfunction

  // ---------------------------------------------------------------------
  // FSM
  // ---------------------------------------------------------------------
  typedef enum logic [2:0] {
    T_IDLE        = 3'd0,
    T_ABSORB      = 3'd1,   // streaming bytes into rate buffer
    T_PERMUTE     = 3'd2,   // Keccak-f[1600] running on a full rate block
    T_PAD_LAUNCH  = 3'd3,   // start the padder for the tail
    T_PAD_WAIT    = 3'd4,   // wait for padder to produce final block
    T_PERMUTE_END = 3'd5,   // permute on the padded final block
    T_DONE        = 3'd6
  } tstate_e;

  tstate_e tstate_q, tstate_d;

  // Sponge state: 25 lanes of 64 bits. We use a 1600-bit packed register
  // to keep the connection to keccak_f1600 simple.
  logic [63:0] sponge_q [0:24];
  logic [63:0] sponge_d [0:24];

  // Rate accumulation buffer (RATE_MAX bytes) and byte fill counter.
  logic [RATE_MAX*8-1:0] buf_q;
  logic [RATE_MAX*8-1:0] buf_d;
  logic [7:0]            fill_q, fill_d;     // bytes currently in buf

  // Sticky flag: master has signalled last_i but we have not finished the
  // padding pass yet (set on the cycle last_i is accepted; cleared on
  // entering T_DONE).
  logic last_pending_q, last_pending_d;

  // Mode latched at start_i (so mid-hash mode changes do not corrupt).
  logic [2:0] mode_q, mode_d;

  // Permutation control
  logic          perm_start;
  logic          perm_busy;
  logic          perm_done;
  logic [63:0]   perm_state_in  [0:24];
  logic [63:0]   perm_state_out [0:24];
  logic [1599:0] perm_state_in_packed;
  logic [1599:0] perm_state_out_packed;
  always_comb begin
    for (int li = 0; li < 25; li++)
      perm_state_in_packed[64*li +: 64] = perm_state_in[li];
  end
  always_comb begin
    for (int li = 0; li < 25; li++)
      perm_state_out[li] = perm_state_out_packed[64*li +: 64];
  end

  // Padder
  logic                       pad_start;
  logic [RATE_MAX*8-1:0]      pad_block;
  logic                       pad_block_valid;
  logic                       pad_done;
  logic [RATE_MAX*8-1:0]      pad_tail;
  logic [7:0]                 pad_tail_len;

  // Latched padder output for the final-block absorb
  logic [RATE_MAX*8-1:0]      finalblk_q, finalblk_d;

  // ---------------------------------------------------------------------
  // Instantiations
  // ---------------------------------------------------------------------
  keccak_f1600 u_perm (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .start_i (perm_start),
    .state_i (perm_state_in_packed),
    .busy_o  (perm_busy),
    .done_o  (perm_done),
    .state_o (perm_state_out_packed)
  );

  keccak_padder #(.RATE_MAX_BYTES(RATE_MAX)) u_pad (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .start_i       (pad_start),
    .tail_i        (pad_tail),
    .tail_len_i    (pad_tail_len),
    .rate_bytes_i  (rate_for(mode_q)),
    .domain_byte_i (domain_for(mode_q)),
    .block_o       (pad_block),
    .block_valid_o (pad_block_valid),
    .done_o        (pad_done)
  );

  // ---------------------------------------------------------------------
  // Combinational helpers
  // ---------------------------------------------------------------------
  // Compute the lane-by-lane XOR of the first rate_bytes of `blk` against
  // sponge state `st_in_packed` (1600-bit packed, lane li in [64*li +: 64]),
  // returning the new state in the same packed form. Rate is always a
  // multiple of 8 bytes (lane-aligned) for every FIPS-202 variant.
  //
  // FIPS-202 §B.1 byte->bit ordering: byte i of the input lands at bits
  // [8*i +: 8] of the packed buffer; byte 8*li + k of the buffer lands
  // in bits [8*k +: 8] of lane li. So the lane li is exactly the 64-bit
  // slice of `blk` at [64*li +: 64] when both share the LSB-first
  // convention. We therefore lift one big mask: zero every lane that is
  // not within rate, XOR the result against the state.
  function automatic logic [1599:0] absorb_block_packed(
      input  logic [RATE_MAX*8-1:0]  blk,
      input  logic [7:0]             rate_bytes,
      input  logic [1599:0]          st_in_packed);
    int lanes;
    int rate_bytes_i;
    logic [1599:0] absorb_data;
    rate_bytes_i = {24'd0, rate_bytes};
    lanes = rate_bytes_i / 8;
    // Build a 1600-bit absorb_data that is the first `lanes` lanes of `blk`
    // and zero in the top (25 - lanes) lanes. XOR that against the state.
    // FIPS-202 §B.1 byte ordering: byte j of the buffer is at bits
    // [8*j +: 8]; lane li takes bytes [8*li .. 8*li+7], i.e. bits
    // [64*li +: 64], which matches the packed sponge layout exactly.
    absorb_data = {1600{1'b0}};
    for (int li = 0; li < 25; li++) begin
      if (li < lanes) absorb_data[64*li +: 64] = blk[64*li +: 64];
    end
    absorb_block_packed = st_in_packed ^ absorb_data;
  endfunction

  // Pack the first `n_bytes` of the sponge state into `out` (low byte
  // first into bits [7:0]). Used to build digest_o.
  // Takes the sponge as a packed 1600-bit vector (lane li in [64*li +: 64]).
  function automatic logic [511:0]
      squeeze_state(input logic [1599:0] st_packed,
                    input int            n_bytes);
    logic [511:0] tmp;
    int li, lk;
    tmp = '0;
    for (int byte_idx = 0; byte_idx < 64; byte_idx++) begin
      if (byte_idx < n_bytes) begin
        li = byte_idx / 8;
        lk = byte_idx % 8;
        for (int b = 0; b < 8; b++) begin
          // Place byte at bits [511 - 8*byte_idx -: 8] (most-significant
          // first), so digest_o reads naturally as a hex string with the
          // first squeezed byte at the top.
          tmp[511 - 8*byte_idx + b - 7] = st_packed[64*li + 8*lk + b];
        end
      end
    end
    squeeze_state = tmp;
  endfunction

  // ---------------------------------------------------------------------
  // FSM next-state logic + handshake
  // ---------------------------------------------------------------------
  // Default outputs
  logic [3:0]            n_bytes;
  int                    n_bytes_i;
  int                    fill_q_i;
  logic [63:0]           bytes_mask;
  logic [63:0]           valid_data;
  logic [RATE_MAX*8-1:0] shifted;
  logic [1599:0]         sponge_q_packed_now;
  logic [1599:0]         absorbed_packed_d;
  always_comb begin
    for (int li = 0; li < 25; li++)
      sponge_q_packed_now[64*li +: 64] = sponge_q[li];
  end
  always_comb begin
    absorbed_packed_d = sponge_q_packed_now;
    n_bytes_i      = 0;
    fill_q_i       = 0;
    bytes_mask     = '0;
    valid_data     = '0;
    shifted        = '0;
    tstate_d       = tstate_q;
    mode_d         = mode_q;
    fill_d         = fill_q;
    buf_d          = buf_q;
    finalblk_d     = finalblk_q;
    last_pending_d = last_pending_q;
    for (int i = 0; i < 25; i++) begin
      sponge_d[i] = sponge_q[i];
      perm_state_in[i] = sponge_q[i];
    end

    perm_start      = 1'b0;
    pad_start       = 1'b0;
    pad_tail        = '0;
    pad_tail_len    = 8'd0;
    n_bytes         = 4'd0;

    case (tstate_q)
      // -----------------------------------------------------------------
      T_IDLE: begin
        if (start_i) begin
          mode_d = mode_i;
          for (int i = 0; i < 25; i++) sponge_d[i] = 64'd0;
          buf_d          = '0;
          fill_d         = 8'd0;
          last_pending_d = 1'b0;
          tstate_d = T_ABSORB;
        end
      end

      // -----------------------------------------------------------------
      T_ABSORB: begin
        if (last_pending_q) begin
          // Returning here after a rate-aligned final absorb. Fall straight
          // through to padding without consuming another master beat.
          tstate_d = T_PAD_LAUNCH;
        end else if (valid_i) begin
          // Determine how many bytes from data_i go into the buffer.
          if (last_i) begin
            n_bytes = last_bytes_i;
          end else begin
            n_bytes = 4'd8;
          end

          // Place bytes at positions [fill_q .. fill_q + n_bytes - 1].
          // Build a 64-bit "valid bytes" mask from n_bytes (1<<(n_bytes*8) - 1
          // expressed as a byte-wise shift), AND it against data_i, then
          // shift the masked data left by fill_q*8 and OR into buf_d. This
          // replaces an O(64) bitselwrite chain (one per output bit) with a
          // single barrel-shift, which both Verilator and Yosys handle in
          // constant time.
          fill_q_i  = {24'd0, fill_q};
          n_bytes_i = {28'd0, n_bytes};
          // Mask of low n_bytes bytes (8 bits each). For n_bytes==0, mask
          // is zero; for n_bytes==8, mask is all-ones.
          bytes_mask = (n_bytes_i == 0) ? 64'd0
                                        : (64'hFFFF_FFFF_FFFF_FFFF >> (8 * (8 - n_bytes_i)));
          valid_data = data_i & bytes_mask;
          shifted    = {{(RATE_MAX*8 - 64){1'b0}}, valid_data} << (8 * fill_q_i);
          buf_d      = buf_q | shifted;
          fill_d = fill_q + {4'd0, n_bytes};

          // Decide what to do next. Three cases:
          //   * Not last and buffer hits rate: absorb + permute, clear buf.
          //   * Last and buffer hits rate exactly: absorb + permute, clear
          //     buf, then on return run a padding-only block (last_pending).
          //   * Last and buffer < rate: go pad.
          if (last_i && (fill_q + {4'd0, n_bytes}) >= rate_for(mode_q)) begin
            // Edge case: message length is a multiple of the rate. The
            // last user bytes fill the block exactly; we still need a
            // following padding-only block per FIPS-202 §5.1.
            absorbed_packed_d = absorb_block_packed(buf_d, rate_for(mode_q), sponge_q_packed_now);
            for (int li = 0; li < 25; li++) sponge_d[li] = absorbed_packed_d[64*li +: 64];
            for (int i = 0; i < 25; i++) perm_state_in[i] = sponge_d[i];
            perm_start     = 1'b1;
            buf_d          = '0;
            fill_d         = 8'd0;
            last_pending_d = 1'b1;
            tstate_d       = T_PERMUTE;
          end else if (last_i) begin
            // Tail of the message - go pad (tail length = fill_d).
            tstate_d = T_PAD_LAUNCH;
          end else if ((fill_q + {4'd0, n_bytes}) >= rate_for(mode_q)) begin
            // Buffer is exactly full: absorb + permute, clear buffer.
            absorbed_packed_d = absorb_block_packed(buf_d, rate_for(mode_q), sponge_q_packed_now);
            for (int li = 0; li < 25; li++) sponge_d[li] = absorbed_packed_d[64*li +: 64];
            for (int i = 0; i < 25; i++) perm_state_in[i] = sponge_d[i];
            perm_start = 1'b1;
            buf_d      = '0;
            fill_d     = 8'd0;
            tstate_d   = T_PERMUTE;
          end
        end
      end

      // -----------------------------------------------------------------
      T_PERMUTE: begin
        // Wait for the permutation to produce its result, then capture
        // it into the sponge state and continue absorbing.
        if (perm_done) begin
          for (int i = 0; i < 25; i++) sponge_d[i] = perm_state_out[i];
          tstate_d = T_ABSORB;
        end
      end

      // -----------------------------------------------------------------
      T_PAD_LAUNCH: begin
        // Drive the padder once with the current buffer contents.
        pad_start      = 1'b1;
        pad_tail       = buf_q;
        pad_tail_len   = fill_q;
        last_pending_d = 1'b0;
        tstate_d       = T_PAD_WAIT;
      end

      // -----------------------------------------------------------------
      T_PAD_WAIT: begin
        pad_tail     = buf_q;
        pad_tail_len = fill_q;
        if (pad_block_valid) begin
          // Capture the padded block, absorb + permute it.
          finalblk_d = pad_block;
          absorbed_packed_d = absorb_block_packed(pad_block, rate_for(mode_q), sponge_q_packed_now);
          for (int li = 0; li < 25; li++) sponge_d[li] = absorbed_packed_d[64*li +: 64];
          for (int i = 0; i < 25; i++) perm_state_in[i] = sponge_d[i];
          perm_start = 1'b1;
          tstate_d   = T_PERMUTE_END;
        end
      end

      // -----------------------------------------------------------------
      T_PERMUTE_END: begin
        if (perm_done) begin
          for (int i = 0; i < 25; i++) sponge_d[i] = perm_state_out[i];
          tstate_d = T_DONE;
        end
      end

      // -----------------------------------------------------------------
      T_DONE: begin
        // Pulse digest_valid_o for one cycle, return to idle.
        tstate_d = T_IDLE;
      end

      default: tstate_d = T_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tstate_q       <= T_IDLE;
      mode_q         <= 3'd0;
      buf_q          <= '0;
      fill_q         <= 8'd0;
      finalblk_q     <= '0;
      last_pending_q <= 1'b0;
      for (int i = 0; i < 25; i++) sponge_q[i] <= 64'd0;
    end else begin
      tstate_q       <= tstate_d;
      mode_q         <= mode_d;
      buf_q          <= buf_d;
      fill_q         <= fill_d;
      finalblk_q     <= finalblk_d;
      last_pending_q <= last_pending_d;
      for (int i = 0; i < 25; i++) sponge_q[i] <= sponge_d[i];
    end
  end

  // ---------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------
  assign ready_o        = (tstate_q == T_ABSORB) && !last_pending_q;
  assign digest_valid_o = (tstate_q == T_DONE);
  assign busy_o         = (tstate_q != T_IDLE) && (tstate_q != T_ABSORB);
  assign digest_bits_o  = squeeze_for(mode_q);

  // Pack squeezed bytes into digest_o. For 256-bit modes the low 256
  // bits of digest_o are zero; for 512-bit modes the full 512 bits are
  // populated.
  always_comb begin
    if (digest_bits_o == 10'd256) begin
      digest_o = squeeze_state(sponge_q_packed_now, 32);
    end else begin
      digest_o = squeeze_state(sponge_q_packed_now, 64);
    end
  end

endmodule
