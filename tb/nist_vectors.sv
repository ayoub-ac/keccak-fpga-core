// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// NIST FIPS-202 SHA-3 / SHAKE test vectors as a SystemVerilog package for
// non-Verilator simulators.
//
// Sources:
//   * NIST FIPS-202 §A.3 examples (e.g. SHA3-256 of empty)
//   * NIST CAVP test response files SHA3_256ShortMsg.rsp,
//     SHA3_512ShortMsg.rsp, SHAKE128ShortMsg.rsp, SHAKE256ShortMsg.rsp
//     (https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program)
//
// The expected digest is given as the canonical hex string. The C++ harness
// in tb/sim_main.cpp consumes equivalent vectors compiled into the binary
// (see kFipsVectors, kEthVectors); this file is the SystemVerilog equivalent
// for users who want to re-run the same vectors in Vivado xsim / Modelsim /
// Questa.

`ifndef KECCAK_NIST_VECTORS_SVH
`define KECCAK_NIST_VECTORS_SVH

package keccak_nist_vectors_pkg;

  typedef enum int {
    K_SHA3_256 = 0,
    K_SHA3_512 = 1,
    K_SHAKE128 = 2,
    K_SHAKE256 = 3,
    K_ETH_K256 = 4
  } keccak_mode_e;

  typedef struct {
    string         name;
    keccak_mode_e  mode;
    int            msg_bits;
    string         msg_hex;
    string         digest_hex;
  } keccak_vec_t;

  // SHA3-256 of empty
  // expected = a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a
  localparam keccak_vec_t kSha3_256_Empty = '{
    name:       "SHA3-256(\"\")",
    mode:       K_SHA3_256,
    msg_bits:   0,
    msg_hex:    "",
    digest_hex: "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
  };

  // SHA3-256("abc") = 3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532
  localparam keccak_vec_t kSha3_256_Abc = '{
    name:       "SHA3-256(\"abc\")",
    mode:       K_SHA3_256,
    msg_bits:   24,
    msg_hex:    "616263",
    digest_hex: "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"
  };

  // SHA3-512 of empty = a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26
  localparam keccak_vec_t kSha3_512_Empty = '{
    name:       "SHA3-512(\"\")",
    mode:       K_SHA3_512,
    msg_bits:   0,
    msg_hex:    "",
    digest_hex: "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"
  };

  // SHA3-512("abc")
  localparam keccak_vec_t kSha3_512_Abc = '{
    name:       "SHA3-512(\"abc\")",
    mode:       K_SHA3_512,
    msg_bits:   24,
    msg_hex:    "616263",
    digest_hex: "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0"
  };

  // SHAKE128 of empty (first 256 bits) = 7f9c2ba4e88f827d616045507605853e
  // (this matches CAVP SHAKE128VariableOut.rsp empty entry first 32 bytes)
  localparam keccak_vec_t kShake128_Empty = '{
    name:       "SHAKE128(\"\", 32B)",
    mode:       K_SHAKE128,
    msg_bits:   0,
    msg_hex:    "",
    digest_hex: "7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26"
  };

  // SHAKE256 of empty (first 512 bits) =
  //   46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762fd75dc4ddd8c0f200cb05019d67b592f6fc821c49479ab48640292eacb3b7c4be
  localparam keccak_vec_t kShake256_Empty = '{
    name:       "SHAKE256(\"\", 64B)",
    mode:       K_SHAKE256,
    msg_bits:   0,
    msg_hex:    "",
    digest_hex: "46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762fd75dc4ddd8c0f200cb05019d67b592f6fc821c49479ab48640292eacb3b7c4be"
  };

  // Ethereum Keccak-256 of empty =
  //   c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
  // This is the canonical "empty trie root" / "empty input" hash used in
  // Ethereum and is DIFFERENT from SHA3-256("") because the original
  // Keccak submission used domain byte 0x01, while FIPS-202 SHA3 uses 0x06.
  localparam keccak_vec_t kEthK256_Empty = '{
    name:       "ETH-Keccak-256(\"\")",
    mode:       K_ETH_K256,
    msg_bits:   0,
    msg_hex:    "",
    digest_hex: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  };

endpackage

`endif
