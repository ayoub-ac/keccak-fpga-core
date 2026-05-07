// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Keccak-f[1600] single-round combinational logic.
//
// Reference: NIST FIPS-202, "SHA-3 Standard: Permutation-Based Hash and
//            Extendable-Output Functions", August 2015, sections 3.2
//            (step mappings theta, rho, pi, chi, iota) and 3.3 (Keccak-p
//            and Keccak-f).
//
// State representation: a 5 x 5 x 64-bit "lane" state A[x,y,z]. We pack
// the lanes as a packed array of 25 lanes of 64 bits each. Indexing
// convention (FIPS-202 §3.1.2):
//
//   lane_idx(x,y) = x + 5*y     for x in 0..4, y in 0..4
//
// so a row of constant y is contiguous and column traversal steps by 5.
// Bit z of lane (x,y) is state[lane_idx(x,y)][z], with z = 0 the LSB
// (matches the standard's Bytes("01") -> bit-string mapping in §B.1).
//
// All five mappings are purely combinational; the parent permutation
// module (keccak_f1600) registers the state once per round.
//
//   theta:  C[x]    = A[x,0] xor A[x,1] xor A[x,2] xor A[x,3] xor A[x,4]
//           D[x]    = C[x-1] xor ROT(C[x+1], 1)
//           A'[x,y] = A[x,y] xor D[x]
//
//   rho:    A'[x,y] = ROT(A[x,y], r[x,y])  where r[x,y] is the FIPS-202
//                                          §3.2.2 offset table.
//
//   pi:     A'[x,y] = A[(x + 3*y) mod 5, x]
//
//   chi:    A'[x,y] = A[x,y] xor ((NOT A[x+1,y]) AND A[x+2,y])
//
//   iota:   A'[0,0] = A[0,0] xor RC[i_round]
//
// where ROT(w, n) is a 64-bit cyclic left rotation by n positions and
// RC[i] is the round-constant table from FIPS-202 §3.2.5 (passed in
// from the parent so a single round-constant ROM is shared).

module keccak_round (
  input  logic [1599:0] state_i,            // 25 lanes x 64 bits, lane li in [64*li +: 64]
  input  logic [63:0]   rc_i,               // round constant for iota
  output logic [1599:0] state_o
);

  // Internal lane-level views of the packed ports.
  logic [63:0] state_in  [0:24];
  logic [63:0] state_out [0:24];
  always_comb begin
    for (int li = 0; li < 25; li++) state_in[li] = state_i[64*li +: 64];
  end

  // ---- 64-bit cyclic left rotation ---------------------------------------
  function automatic logic [63:0] rotl(input logic [63:0] x, input int n);
    int s;
    s = n & 32'h3f;        // n mod 64
    if (s == 0) rotl = x;
    else        rotl = (x << s) | (x >> (64 - s));
  endfunction

  // ---- FIPS-202 §3.2.2 rho offsets r[x,y] --------------------------------
  // r[x,y] = ((t+1)(t+2)/2) mod 64, where t is computed iteratively in
  // §3.2.2. We pre-compute the 25-entry table.
  function automatic int rho_offset(input int x, input int y);
    case ({x[2:0], y[2:0]})
      6'b000_000: rho_offset = 0;   // (0,0)
      6'b001_000: rho_offset = 1;   // (1,0)
      6'b010_000: rho_offset = 62;  // (2,0)
      6'b011_000: rho_offset = 28;  // (3,0)
      6'b100_000: rho_offset = 27;  // (4,0)
      6'b000_001: rho_offset = 36;  // (0,1)
      6'b001_001: rho_offset = 44;  // (1,1)
      6'b010_001: rho_offset = 6;   // (2,1)
      6'b011_001: rho_offset = 55;  // (3,1)
      6'b100_001: rho_offset = 20;  // (4,1)
      6'b000_010: rho_offset = 3;   // (0,2)
      6'b001_010: rho_offset = 10;  // (1,2)
      6'b010_010: rho_offset = 43;  // (2,2)
      6'b011_010: rho_offset = 25;  // (3,2)
      6'b100_010: rho_offset = 39;  // (4,2)
      6'b000_011: rho_offset = 41;  // (0,3)
      6'b001_011: rho_offset = 45;  // (1,3)
      6'b010_011: rho_offset = 15;  // (2,3)
      6'b011_011: rho_offset = 21;  // (3,3)
      6'b100_011: rho_offset = 8;   // (4,3)
      6'b000_100: rho_offset = 18;  // (0,4)
      6'b001_100: rho_offset = 2;   // (1,4)
      6'b010_100: rho_offset = 61;  // (2,4)
      6'b011_100: rho_offset = 56;  // (3,4)
      6'b100_100: rho_offset = 14;  // (4,4)
      default:    rho_offset = 0;
    endcase
  endfunction

  // ---- theta -------------------------------------------------------------
  // C[x] = xor over y of A[x,y]; D[x] = C[x-1] xor ROT(C[x+1], 1)
  logic [63:0] C [0:4];
  logic [63:0] D [0:4];
  logic [63:0] theta_out [0:24];

  always_comb begin
    for (int x = 0; x < 5; x++) begin
      C[x] = state_in[x + 5*0] ^ state_in[x + 5*1] ^ state_in[x + 5*2]
           ^ state_in[x + 5*3] ^ state_in[x + 5*4];
    end
    for (int x = 0; x < 5; x++) begin
      D[x] = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
    end
    for (int y = 0; y < 5; y++) begin
      for (int x = 0; x < 5; x++) begin
        theta_out[x + 5*y] = state_in[x + 5*y] ^ D[x];
      end
    end
  end

  // ---- rho + pi (combined) ------------------------------------------------
  // pi:  B[y, (2x+3y) mod 5] = rho(A)[x,y]
  // i.e. the lane that lands at output position (x_out, y_out) comes from
  //      input position (x_in, y_in) where x_out = y_in,
  //      y_out = (2*x_in + 3*y_in) mod 5.
  // We build B by walking input (x_in, y_in) and writing into the
  // computed output position.
  logic [63:0] B [0:24];

  always_comb begin
    for (int i = 0; i < 25; i++) B[i] = '0;
    for (int y_in = 0; y_in < 5; y_in++) begin
      for (int x_in = 0; x_in < 5; x_in++) begin
        int x_out, y_out;
        x_out = y_in;
        y_out = (2*x_in + 3*y_in) % 5;
        B[x_out + 5*y_out] = rotl(theta_out[x_in + 5*y_in],
                                  rho_offset(x_in, y_in));
      end
    end
  end

  // ---- chi ---------------------------------------------------------------
  // A'[x,y] = B[x,y] xor ((NOT B[x+1,y]) AND B[x+2,y])
  logic [63:0] chi_out [0:24];

  always_comb begin
    for (int y = 0; y < 5; y++) begin
      for (int x = 0; x < 5; x++) begin
        chi_out[x + 5*y] = B[x + 5*y]
                         ^ ((~B[((x+1) % 5) + 5*y]) & B[((x+2) % 5) + 5*y]);
      end
    end
  end

  // ---- iota --------------------------------------------------------------
  // Only lane (0,0) is XORed with the round constant.
  always_comb begin
    for (int i = 0; i < 25; i++) state_out[i] = chi_out[i];
    state_out[0] = chi_out[0] ^ rc_i;
  end

  // Repack the lane view into the packed output.
  always_comb begin
    for (int li = 0; li < 25; li++) state_o[64*li +: 64] = state_out[li];
  end

endmodule
