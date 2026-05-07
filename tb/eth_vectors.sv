// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Ethereum Keccak-256 reference test vectors as a SystemVerilog package.
//
// These vectors are well-known fixtures in the Ethereum ecosystem and are
// reproducible by `pycryptodome.Crypto.Hash.keccak.new(digest_bits=256)`
// or `web3.utils.keccak256` against the same input bytes.
//
// CRITICAL: Ethereum Keccak-256 is NOT the same as NIST SHA3-256. The
// padding domain byte differs (0x01 vs 0x06), so the digest of any
// non-empty input differs. Verifying the empty hash alone is enough to
// distinguish them (kEthK256_Empty vs kSha3_256_Empty in nist_vectors.sv).

`ifndef KECCAK_ETH_VECTORS_SVH
`define KECCAK_ETH_VECTORS_SVH

package keccak_eth_vectors_pkg;

  typedef struct {
    string name;
    string msg_hex;     // empty string for "" input
    string digest_hex;
  } eth_vec_t;

  // 1. Empty input. Famous Ethereum constant ("hash of nothing").
  localparam eth_vec_t kEthEmpty = '{
    name:       "keccak256(\"\")",
    msg_hex:    "",
    digest_hex: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
  };

  // 2. ASCII "abc"
  localparam eth_vec_t kEthAbc = '{
    name:       "keccak256(\"abc\")",
    msg_hex:    "616263",
    digest_hex: "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
  };

  // 3. "Hello, world!" - common smoke test
  localparam eth_vec_t kEthHelloWorld = '{
    name:       "keccak256(\"Hello, world!\")",
    msg_hex:    "48656c6c6f2c20776f726c6421",
    digest_hex: "b6e16d27ac5ab427a7f68900ac5559ce272dc6c37c82b3e052246c82244c50e4"
  };

  // 4. The 32-byte input "abcdefghijklmnopqrstuvwxyz123456" (one rate
  // block of nothing, well within the 136-byte SHA3-256 / Keccak-256 rate)
  localparam eth_vec_t kEthAlpha = '{
    name:       "keccak256(\"abcdefghijklmnopqrstuvwxyz123456\")",
    msg_hex:    "6162636465666768696a6b6c6d6e6f707172737475767778797a313233343536",
    digest_hex: "b3eae197a287fc6713806f1bab91dffee8c3445e8cc629b7cb0b1a2efdbcf93b"
  };

endpackage

`endif
