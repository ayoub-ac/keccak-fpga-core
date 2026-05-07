# keccak-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)](#verification)
[![FIPS-202 vectors](https://img.shields.io/badge/FIPS--202-NIST%20vectors-blue.svg)](#verification)
[![Ethereum Keccak-256](https://img.shields.io/badge/Ethereum-Keccak--256-blueviolet.svg)](#ethereum-keccak-256-vs-nist-sha3-256-the-footgun)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-brightgreen.svg)](#build--test)

A small, synthesisable Keccak / SHA-3 family IP core in SystemVerilog. One round per cycle, 25-cycle iterative Keccak-f[1600] permutation, single clock domain. Five variants behind a 3-bit mode select: **SHA3-256**, **SHA3-512**, **SHAKE128**, **SHAKE256**, **Ethereum Keccak-256**. Targets iCE40, ECP5, Xilinx 7-series, Cyclone V, and Tang Nano 9K.

The core is a clean implementation of FIPS-202 plus the original Keccak submission, verified end-to-end against NIST FIPS-202 / NIST CAVP test vectors plus a 125-message cross-check across all five modes against Python `hashlib.sha3_*` / `hashlib.shake_*` and `pycryptodome.Crypto.Hash.keccak`. End-to-end verifiable with the open-source Verilator simulator. No FPGA hardware required for the test suite.

## Why this exists

Most freely available Keccak / SHA-3 cores either ship only SHA3-256, only Keccak-256, are pipelined-only (huge LUT cost), are pre-FIPS-202 (and therefore use the original Keccak padding that is **incompatible** with SHA3 — see below), only verified against `"abc"`, or licensed under unclear terms. This core is small, dual-licensed cleanly (GPL for OSS use, commercial license for closed-source), shipped with five mode variants behind a single streaming top, NIST + Ethereum + 125 random cross-validation vectors in the testbench, SystemVerilog assertions, functional coverage, and a synthesis-comparison report across multiple toolchains.

## Ethereum Keccak-256 vs NIST SHA3-256: the footgun

This is the single biggest thing that bites every Keccak / SHA-3 implementer, so it goes prominently at the top:

> **Ethereum's `keccak256()` is NOT the same function as NIST FIPS-202 SHA3-256.**

They use the same underlying Keccak-f[1600] permutation and the same rate / capacity (1088 / 512). The only difference is the **domain separation byte** appended to the message before the trailing 1-bit of `pad10*1`:

| Variant            | Domain byte | First byte after the message tail |
|--------------------|------------:|----------------------------------:|
| SHA3-256 (FIPS-202)| `0x06`      | `0x06` then zeros, then `0x80`    |
| Ethereum Keccak-256| `0x01`      | `0x01` then zeros, then `0x80`    |

That single byte is enough to make every digest of every non-empty input differ. The two empty-input digests are the canonical sanity check:

```
SHA3-256("")             = a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a
Ethereum Keccak-256("")  = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
```

Why does Ethereum use the older variant? Because Ethereum was specified before FIPS-202 was finalised. The Ethereum yellow paper points at the original Keccak submission, which used the simpler `pad10*1` rule with no domain byte (effectively `0x01` for byte-oriented inputs). FIPS-202 added the `0x06` separator to give SHA3 its own domain. By the time FIPS-202 shipped, the Ethereum genesis block was on chain and the variant could not be changed.

**This core supports both.** Drive `mode_i = 0` for SHA3-256, `mode_i = 4` for Ethereum Keccak-256. The directed test suite includes an explicit cross-check that the two produce different digests (Test 3) so any future regression that swaps the domain byte fails the gate.

If your application is the Ethereum world (smart contracts, EVM, EIP-191, EIP-712, Solidity `keccak256()`, web3.js / ethers.js / web3.py): **`mode_i = 4`**. If your application is the FIPS world (TLS 1.3 with SHA3, post-quantum schemes like SLH-DSA / Dilithium / Falcon, NIST SP 800-185 derived functions): **`mode_i = 0`**.

## Quickstart

```bash
git clone https://github.com/ayoub-ac/keccak-fpga-core.git
cd keccak-fpga-core
make lint test            # Verilator lint + run NIST + Ethereum + random tests
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth flow. Python 3 with `pycryptodome` installed if you want to regenerate the random vectors via `make regen_vectors`.

## Architecture

```
                   +------------------+
       data_i ---->|                  |
        last_i---->|                  |---> digest_o (512 bits)
   last_bytes ---->|   keccak_top     |---> digest_bits_o (256 / 512)
       valid_i---->| (streaming top   |---> digest_valid_o
       start_i---->|  with mode sel.) |---> ready_o, busy_o
        mode_i---->|                  |
                   +-------+----------+
                           |
       +-------------------+--------------------+
       |             |                |          |
   keccak_round   keccak_padder    rate buffer  sponge
   (theta/rho/    (FIPS-202 pad    (RATE_MAX    state
    pi/chi/iota   10*1 + domain    bytes)       (1600
    combinational byte selector)                bits)
    24 rounds via
    keccak_f1600
    FSM)
```

FSM: `IDLE -> ABSORB <-> PERMUTE -> PAD_LAUNCH -> PAD_WAIT -> PERMUTE_END -> DONE -> IDLE`. The Keccak-f[1600] permutation runs 24 rounds in 24 cycles plus a 1-cycle `done` pulse; per rate-block the streaming top adds ~3 cycles of FSM overhead.

## Port table

| Signal           | Dir | Width | Description                                                                                                                            | FIPS-202 ref |
|------------------|-----|-------|----------------------------------------------------------------------------------------------------------------------------------------|--------------|
| `clk_i`          | in  | 1     | System clock. All flops sample on the rising edge.                                                                                     | -            |
| `rst_ni`         | in  | 1     | Synchronous active-low reset. Hold low ≥4 cycles before first command.                                                                 | -            |
| `mode_i`         | in  | 3     | Variant: 0 SHA3-256, 1 SHA3-512, 2 SHAKE128, 3 SHAKE256, 4 Ethereum Keccak-256. Latched at `start_i`.                                  | §6           |
| `start_i`        | in  | 1     | Pulse one cycle to begin a new hash; clears the sponge state.                                                                          | §4           |
| `data_i`         | in  | 64    | Streaming message data, byte 0 at bits `[7:0]` (LSB-first, FIPS-202 §B.1).                                                             | §B.1         |
| `valid_i`        | in  | 1     | Master asserts when `data_i` is valid. Transfer accepted on `valid_i && ready_o`.                                                       | -            |
| `last_i`         | in  | 1     | Final beat of the message. `last_bytes_i` says how many bytes are valid (0..8).                                                         | -            |
| `last_bytes_i`   | in  | 4     | 0..8. Use 0 for empty message.                                                                                                          | -            |
| `ready_o`        | out | 1     | Core ready to accept a new beat.                                                                                                        | -            |
| `digest_o`       | out | 512   | Squeezed digest. First squeezed byte at bits `[511:504]`. 256-bit modes zero-fill the low 256 bits.                                     | §4 / §6      |
| `digest_bits_o`  | out | 10    | 256 or 512.                                                                                                                             | §6           |
| `digest_valid_o` | out | 1     | Single-cycle pulse when digest is valid.                                                                                                | -            |
| `busy_o`         | out | 1     | High while a permutation or final-block flow is in flight.                                                                              | -            |

See [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md) for the full streaming protocol with timing diagrams.

## Headline numbers

Real numbers from `make synth_report` (Yosys 0.33, full streaming top):

| Target           | LUT      | FF      | BRAM | Latency / hash                  | Throughput @ Fmax     |
|------------------|---------:|--------:|-----:|---------------------------------|-----------------------|
| iCE40 UP5K       |   18,204 |  5,922  | 0    | ~25 cycles per Keccak-f[1600]   | varies by mode + Fmax |
| ECP5 LFE5UM-25   |   25,475 |  5,922  | 0    | ~25 cycles per Keccak-f[1600]   | varies                |
| Xilinx 7-series  |   10,541 |  2,959  | 0    | ~25 cycles per Keccak-f[1600]   | varies                |

Keccak-f[1600] has a 1600-bit state (25 lanes x 64 bits). The FF count is dominated by the sponge state plus the rate-block buffer (RATE_MAX = 168 bytes = 1344 bits, sized for SHAKE128). See [`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) for the full breakdown and tactics for shrinking it (drop unused modes, smaller RATE_MAX, externalise the rate buffer to BRAM).

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer plus Python 3.

```bash
make lint           # static check the RTL (round + f1600 + padder + top)
make test           # build + run NIST + Ethereum + random + edge-case tests
make synth_report   # cross-toolchain synthesis report
make regen_vectors  # regenerate tb/random_vectors.h from hashlib + pycryptodome
```

A passing run ends with `+PASS all tests passed` and exits 0.

## Verification

Three orthogonal techniques are wired into the testbench:

### Directed tests (NIST FIPS-202)

| # | Test                                  | Coverage                                           |
|---|---------------------------------------|----------------------------------------------------|
| 1 | SHA3-256(empty), SHA3-256("abc")      | FIPS-202 §A.3 examples, single-block               |
| 2 | SHA3-256(200x0xA3)                    | Multi-block (>1 rate-block)                        |
| 3 | SHA3-512(empty), SHA3-512("abc")      | FIPS-202 §A.3, smaller rate (576 bits = 72 bytes)  |
| 4 | SHAKE128(empty,32B), SHAKE128("abc",32B) | XOF with the largest rate (1344 bits = 168 bytes) |
| 5 | SHAKE256(empty,64B), SHAKE256("abc",64B) | XOF with 512-bit squeeze                         |

### Directed tests (Ethereum Keccak-256)

| # | Test                                  | Coverage                                           |
|---|---------------------------------------|----------------------------------------------------|
| 1 | `keccak256("")`                       | Canonical empty hash (`c5d2...`)                   |
| 2 | `keccak256("abc")`                    | ASCII smoke test                                   |
| 3 | `keccak256("Hello, world!")`          | Common cross-language smoke test                   |
| 4 | `keccak256(32-byte alpha+digits)`     | Single-block, well within rate                     |
| 5 | `keccak256(137x0x55)`                 | Multi-block with the Ethereum domain byte          |

### SHA3-256 vs Ethereum-Keccak-256 distinction

A dedicated test verifies that on the empty input, SHA3-256 produces `a7ffc6f8...` and Ethereum Keccak-256 produces `c5d24601...`, and that the two are different. This is the canonical regression-catching check for the domain-byte logic.

### Random cross-validation (125 messages)

25 random messages per mode times 5 modes. Lengths drawn from `{0, 1, 32, 71, 72, 135, 136, 137, 167, 168, 169}` plus 14 random lengths in [170, 2000], chosen to land on every rate boundary (SHA3-512 rate = 72, SHA3-256 / SHAKE256 / Keccak-256 rate = 136, SHAKE128 rate = 168). Cross-checked against `hashlib.sha3_*`, `hashlib.shake_*`, and `pycryptodome.Crypto.Hash.keccak`.

### SystemVerilog assertions

`tb/keccak_assertions.sv` enforces protocol invariants on every cycle of every test:

- Each Keccak-f[1600] permutation completes in exactly 25 cycles
- `digest_o` is stable while `digest_valid_o` is asserted
- The round counter never exceeds 23
- `ready_o` is low whenever `busy_o` is high (no transfer mid-permutation)
- `pad_block_valid` is a single-cycle pulse (padder emits exactly one block per launch)
- Rate-buffer fill counter never exceeds the per-mode rate

The assertions compile with both Verilator 5.x (`--assert`) and Vivado xsim. They are stripped on synthesis flows via `` `ifndef SYNTHESIS ``.

### Functional coverage

`tb/keccak_cov.sv` collects ten bins. The simulator prints a coverage summary at end-of-test:

```
---- Functional coverage ----
  [HIT ] mode_sha3_256 / mode_sha3_512 / mode_shake128 / mode_shake256 / mode_eth_k256
  [HIT ] single_block / multi_block / back_to_back / reset_mid_hash / empty_message
Coverage: 10/10 bins (100.0%)
```

A regression that drops below 100% fails the gate.

### Synthesis comparison report

`make synth_report` runs every available toolchain on the same RTL and emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side LUT/FF/BRAM table. Yosys (`synth_ice40` / `synth_ecp5` / `synth_xilinx`) is mandatory; Vivado and Quartus are detected automatically and skipped with a notice when not on `$PATH`.

## Variants

| Variant                              | Use case                                                                                    | Tier    |
|--------------------------------------|---------------------------------------------------------------------------------------------|---------|
| `rtl/keccak_round.sv`                | Combinational theta / rho / pi / chi / iota single-round update                             | GPL     |
| `rtl/keccak_f1600.sv`                | 24-round iterative Keccak-f[1600] permutation                                                | GPL     |
| `rtl/keccak_padder.sv`               | FIPS-202 `pad10*1` + domain-byte selector (SHA3 / SHAKE / Ethereum)                          | GPL     |
| `rtl/keccak_top.sv`                  | Streaming top with 3-bit mode select; supports all 5 variants behind a single port surface  | GPL     |
| `vhdl_wrapper/keccak_top_vhdl.vhd`   | VHDL-2008 entity wrapping the SV streaming top for VHDL-only designs                         | All     |

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source projects. If your product links this RTL or its compiled bitstream, your project must also be GPL-3.0+.
- **Commercial license** for closed-source products. Email the maintainer to discuss tiers and pricing. See [`LICENSE.md`](LICENSE.md) for the legal text and an FAQ.

If unsure which applies, read `LICENSE.md` or open an issue.

## Repository layout

```
rtl/                     RTL sources
  keccak_round.sv          combinational theta/rho/pi/chi/iota
  keccak_f1600.sv          24-round iterative permutation FSM
  keccak_padder.sv         FIPS-202 pad10*1 + domain-byte selector
  keccak_top.sv            streaming top with 3-bit mode select
tb/                      testbench
  sim_main.cpp             C++ harness, NIST + Ethereum + 125 random vectors
  keccak_top_tb.sv         DUT wrapper + assertion + coverage instantiation
  keccak_assertions.sv     SVA properties
  keccak_cov.sv            functional coverage collector
  nist_vectors.sv          FIPS-202 vectors as a SV package (non-Verilator sims)
  eth_vectors.sv           Ethereum Keccak-256 vectors as a SV package
  random_vectors.h         generated cross-validation vectors (hashlib + pycryptodome)
  gen_random_vectors.py    regenerates random_vectors.h
vhdl_wrapper/            VHDL-2008 wrapper for mixed-language designs
scripts/                 helper scripts (synth_report.sh, vhdl_cosim.sh)
Makefile                 build / lint / sim / synth / synth_report / vhdl-test
```

## Contributing

Bug reports and patches welcome. Process:

1. File an issue first for non-trivial changes.
2. Fork, branch, and run `make lint test synth_report` locally.
3. Open a pull request with a description of what changed and why.
4. CI runs the full test suite plus `synth_report`; both must be green.

## Citation

```bibtex
@misc{keccak-fpga-core,
  title  = {{keccak-fpga-core}: a small dual-licensed Keccak / SHA-3 family IP core in SystemVerilog with Ethereum Keccak-256 support},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/keccak-fpga-core}}
}
```

## References

- NIST FIPS-202, *SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions*, August 2015.
- G. Bertoni, J. Daemen, M. Peeters, G. Van Assche, *The Keccak reference*, version 3.0, January 2011.
- Ethereum Yellow Paper, Appendix A, *Hash Functions* (defines KEC as the original Keccak with `0x01` domain byte).
- NIST CAVP, *SHA Test Vectors for Hashing Byte-Oriented Messages*, <https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program>.
- G. Bertoni, J. Daemen, M. Peeters, G. Van Assche, *Keccak implementation overview*, 2012 (FPGA architecture references).

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
