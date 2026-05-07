// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Keccak / SHA-3 sponge padder (helper module).
//
// Reference: NIST FIPS-202 §5.1 (the multi-rate padding rule pad10*1) and
//            §6.1-§6.3 (domain separation bytes for SHA3-* and SHAKE).
//            Ethereum's Keccak-256 follows the original Keccak submission
//            (no domain byte before the final 1-bit) - it is *not*
//            FIPS-202 SHA3-256 with a relabel; the padding differs.
//
// The "pad10*1" rule says: given a rate r (in bits) and message length L
// (in bits), append a single 1-bit, then the smallest non-negative number
// of 0-bits, then a final 1-bit, such that the total padded length is a
// multiple of r. A *domain byte* is XORed into the first padded byte; its
// low bits encode the leading 1-bit plus the function-specific separator.
//
//   SHA3-224 / SHA3-256 / SHA3-384 / SHA3-512: domain byte = 0x06
//                                              (binary: 0000_0110;
//                                               two-bit separator "01"
//                                               then the leading "1" of
//                                               pad10*1 = bits "011" LSB
//                                               first, padded with zeros
//                                               to byte 0x06)
//   SHAKE128 / SHAKE256:                       domain byte = 0x1f
//                                              (separator "1111" plus
//                                               leading "1" = bits
//                                               "11111" LSB first = 0x1f)
//   Ethereum Keccak-256 (NOT SHA3-256):        domain byte = 0x01
//                                              (no separator, just the
//                                               leading "1" of pad10*1)
//
// The trailing 1-bit lands at the most-significant bit of the last byte of
// the rate block, which is byte 0x80.
//
// Scope of this helper:
//   * Caller provides one tail chunk (length 0..(rate/8 - 1) bytes) plus
//     the rate (in bytes) and the function-specific domain byte.
//   * The padder produces one or two rate-sized output blocks ready to
//     absorb. One block is enough when the tail length leaves at least
//     one byte for the trailing 0x80 (i.e. tail < rate_bytes - 1, or
//     tail == rate_bytes - 1 with domain == 0x80, but in that special
//     case the same byte holds both the leading and trailing 1-bit so
//     it is OR'd to 0x86 / 0x9f / 0x81).
//   * Output rate is up to RATE_MAX bits = 1344 bits = 168 bytes (the
//     largest of any FIPS-202 variant, used by SHAKE128).
//
// This module is intentionally combinational (one shot, latched on
// start_i). The streaming top drives this once at end-of-message.

module keccak_padder #(
  parameter int RATE_MAX_BYTES = 168    // SHAKE128 has the largest rate
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic                         start_i,
  input  logic [RATE_MAX_BYTES*8-1:0]  tail_i,        // up to RATE_MAX_BYTES bytes
  input  logic [7:0]                   tail_len_i,    // 0..(rate-1) bytes
  input  logic [7:0]                   rate_bytes_i,  // 72/104/136/168
  input  logic [7:0]                   domain_byte_i, // 0x06 / 0x1f / 0x01
  output logic [RATE_MAX_BYTES*8-1:0]  block_o,
  output logic                         block_valid_o,
  output logic                         done_o
);

  typedef enum logic [1:0] {
    P_IDLE  = 2'd0,
    P_EMIT  = 2'd1,
    P_DONE  = 2'd2
  } state_e;

  state_e state_q, state_d;
  logic [RATE_MAX_BYTES*8-1:0] block_q, block_d;
  logic                        valid_q, valid_d;
  logic                        done_q,  done_d;

  // Build the padded block by combining three masks:
  //   1) tail content kept for byte indices [0 .. tail_len - 1]
  //   2) domain byte placed at byte index = tail_len
  //   3) 0x80 ORed into byte index = rate_bytes - 1
  //
  // Block layout: byte 0 is bits [7:0], byte 1 is bits [15:8], ...
  // matches FIPS-202 §3.1.2 / B.1 LSB-first-within-each-lane.
  //
  // Implementation note: we compute the block in three passes - mask the
  // tail (cheap because tail_i is already a valid bit-vector), then OR in
  // shifted domain / trailing bytes. Avoids expensive nested for-loops
  // that explode during synthesis.
  function automatic logic [RATE_MAX_BYTES*8-1:0]
      build_block(input logic [RATE_MAX_BYTES*8-1:0] tail,
                  input logic [7:0]                  tail_len,
                  input logic [7:0]                  rate_bytes,
                  input logic [7:0]                  domain_byte);
    logic [RATE_MAX_BYTES*8-1:0] blk;
    logic [RATE_MAX_BYTES*8-1:0] tail_mask;
    int tlen_i;
    int rbytes_i;
    int domain_shift;
    int trailing_shift;
    tlen_i         = {24'd0, tail_len};
    rbytes_i       = {24'd0, rate_bytes};
    domain_shift   = 8 * tlen_i;
    trailing_shift = 8 * (rbytes_i - 1);

    // Mask of all-ones for byte indices [0 .. tail_len - 1].
    // ({RATE_MAX_BYTES{8'hFF}}) is RATE_MAX_BYTES*8 bits all ones; shift it
    // right by (RATE_MAX_BYTES - tlen) * 8 so only the low 8*tlen bits
    // remain set. When tlen == 0, the shift produces an all-zero mask.
    tail_mask = {RATE_MAX_BYTES{8'hFF}} >> ((RATE_MAX_BYTES - tlen_i) * 8);
    blk = tail & tail_mask;

    // Place domain byte at byte index tail_len.
    blk = blk | ({{(RATE_MAX_BYTES*8 - 8){1'b0}}, domain_byte} << domain_shift);
    // OR 0x80 into byte index rate_bytes - 1. If trailing_shift ==
    // domain_shift the two land in the same byte and the OR naturally
    // combines them (0x06 | 0x80 = 0x86, etc.).
    blk = blk | ({{(RATE_MAX_BYTES*8 - 8){1'b0}}, 8'h80} << trailing_shift);

    build_block = blk;
  endfunction

  always_comb begin
    state_d = state_q;
    block_d = block_q;
    valid_d = 1'b0;
    done_d  = 1'b0;
    case (state_q)
      P_IDLE: begin
        if (start_i) begin
          block_d = build_block(tail_i, tail_len_i, rate_bytes_i,
                                domain_byte_i);
          state_d = P_EMIT;
        end
      end
      P_EMIT: begin
        valid_d = 1'b1;
        state_d = P_DONE;
      end
      P_DONE: begin
        done_d  = 1'b1;
        state_d = P_IDLE;
      end
      default: state_d = P_IDLE;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= P_IDLE;
      block_q <= '0;
      valid_q <= 1'b0;
      done_q  <= 1'b0;
    end else begin
      state_q <= state_d;
      block_q <= block_d;
      valid_q <= valid_d;
      done_q  <= done_d;
    end
  end

  assign block_o       = block_q;
  assign block_valid_o = valid_q;
  assign done_o        = done_q;

endmodule
