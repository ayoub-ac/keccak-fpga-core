# keccak-fpga-core

[![CI](https://github.com/ayoub-ac/keccak-fpga-core/actions/workflows/ci.yml/badge.svg)](https://github.com/ayoub-ac/keccak-fpga-core/actions/workflows/ci.yml)
[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Ethereum Keccak-256](https://img.shields.io/badge/Ethereum-Keccak--256-blueviolet.svg)](#ethereum-keccak-256-vs-nist-sha3-256-the-footgun)

> **Status: verified in simulation only.** v1.1.0 matches Python `hashlib`
> (SHA3-256, SHA3-512, SHAKE128, SHAKE256) and `pycryptodome` (Ethereum
> Keccak-256) on 371 messages, including the lengths just below, at and above one,
> two and three rate blocks, with idle cycles, resets mid-hash and random `mode_i`
> changes, plus the original NIST and Ethereum directed tests. It has been
> compiled with Quartus Prime Lite for Cyclone V and with Vivado for
> Artix-7, but not run on FPGA hardware, validated under NIST CAVP/CMVP, or
> evaluated for side-channel or fault-injection resistance. It was written
> with AI assistance. No support or maintenance is provided. See
> [Verification](#verification) for what was and was not checked.

A synthesisable Keccak / SHA-3 family IP core in SystemVerilog. One round per cycle, iterative Keccak-f[1600] permutation, single clock domain. Five variants behind a 3-bit mode select: **SHA3-256**, **SHA3-512**, **SHAKE128**, **SHAKE256**, **Ethereum Keccak-256**. It needs about 13k LUT6 on Artix-7 or 8.9k ALM on Cyclone V and runs at about 122 MHz on both; it does not fit an iCE40, a Tang Nano 9K or an ECP5-25 (see [Measured numbers](#measured-numbers)).

The core implements the FIPS-202 algorithm plus the original Keccak submission, checked in simulation against independent software implementations; it is not NIST-validated. No FPGA hardware is required to run the test suite.

## Why this exists

Most freely available Keccak / SHA-3 cores either ship only SHA3-256, only Keccak-256, are pipelined-only (huge LUT cost), are pre-FIPS-202 (and therefore use the original Keccak padding that is **incompatible** with SHA3 — see below), only verified against `"abc"`, or licensed under unclear terms. This core is dual-licensed cleanly (GPL for OSS use, commercial license for closed-source), shipped with five mode variants behind a single streaming top, NIST + Ethereum + 125 random cross-validation vectors in the testbench, SystemVerilog assertions, functional coverage, and a synthesis-comparison report across multiple toolchains.

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

**This core supports both.** Drive `mode_i = 0` for SHA3-256, `mode_i = 4` for Ethereum Keccak-256. The Ethereum mode matches `pycryptodome`'s Keccak-256, the function Ethereum calls `keccak256()`, on every test message. The directed test suite also checks that the two produce different digests (Test 3).

If your application is the Ethereum world (smart contracts, EVM, EIP-191, EIP-712, Solidity `keccak256()`, web3.js / ethers.js / web3.py): **`mode_i = 4`**. If your application is the FIPS world (TLS 1.3 with SHA3, post-quantum schemes like SLH-DSA / Dilithium / Falcon, NIST SP 800-185 derived functions): **`mode_i = 0`**.

## Quickstart

```bash
git clone https://github.com/ayoub-ac/keccak-fpga-core.git
cd keccak-fpga-core
make lint test            # Verilator lint + run NIST + Ethereum + random tests
make test-vectors         # 371 messages against hashlib / pycryptodome (needs pycryptodome)
make synth_report         # SYNTH_REPORT.md: Yosys iCE40/ECP5/Xilinx (Vivado/Quartus if on PATH)
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth flow. Python 3 with `pycryptodome` for `make test-vectors` and `make regen_vectors`.

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

FSM: `IDLE -> ABSORB <-> PERMUTE -> PAD_LAUNCH -> PAD_WAIT -> PERMUTE_END -> DONE -> IDLE`. Measured in simulation: each full rate block takes rate / 8 beats plus about 25 cycles of permutation, with no overlap between absorbing and permuting, and `digest_valid_o` rises 30 cycles after the last beat (56 when the length is a multiple of the rate). See [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md#timing).

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

## Measured numbers

Yosys 0.70 (OSS CAD Suite 2026-11-01, flattened, before place and route),
Quartus Prime Lite 25.1 and Vivado 2025.2 (out of context, place and route,
register to register, 5 ns constraint, no I/O timing):

| Flow | Target | LUT | FF | Fmax |
|---|---|---|---|---|
| Yosys `synth_ice40` | iCE40 | 18252 LUT4 | 5922 | - |
| Yosys `synth_ecp5` | ECP5 | 25647 LUT4 + 9730 PFUMX/L6MUX21 | 5922 | - |
| Yosys `synth_xilinx` | Xilinx 7-series | 15600 LUT6 + 599 MUXF7/8 | 5922 | - |
| Quartus Prime Lite | Cyclone V 5CSEMA5F31C6 | 8882 ALM (28 %) | 5919 | 123.09 MHz (85 °C), 125.25 MHz (0 °C) |
| Vivado | Artix-7 xc7a35t-1 | 13149 LUT6 (63 %) | 5946 | 122.16 MHz |

- It does not fit an iCE40 UP5K or HX8K (5280 / 7680 LUT4), a Tang Nano 9K
  (8640 LUT4) or an ECP5 LFE5U-25F (24288 LUT4).
- The flip-flops are the 1600-bit state, three 1344-bit rate-size registers
  and about 290 bits of control. Two of the rate-size registers could be
  merged away; [`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) has the
  breakdown.
- At 122 MHz, SHA3-256 absorbs about 395 MB/s on long messages (136 bytes
  every 42 cycles; computed from the cycle count, not measured on hardware).

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer plus Python 3.

```bash
make lint           # static check the RTL (round + f1600 + padder + top)
make test           # build + run NIST + Ethereum + random + edge-case tests
make test-vectors   # 371 messages against hashlib / pycryptodome
make synth_report   # cross-toolchain synthesis report
make regen_vectors  # regenerate tb/random_vectors.h from hashlib + pycryptodome
```

`make test` ends a passing run with `+PASS all tests passed` and exits 0; `make test-vectors` prints `VECTOR TESTS PASSED`.

## Verification

Everything below runs in CI on every push (`.github/workflows/ci.yml`).

| Check | What it covers | Result (v1.1.0) |
|---|---|---|
| `make lint` | Verilator `-Wall` on the RTL and the testbench | clean |
| `make test` | NIST example vectors for the four FIPS-202 functions, 5 Ethereum Keccak-256 vectors, the SHA3-256 vs Keccak-256 distinction, 125 random messages cross-checked with `hashlib` / `pycryptodome`; 6 SVA properties every cycle; 10/10 coverage bins | pass |
| `make test-vectors` | 371 messages from `hashlib` / `pycryptodome`: per mode 0..17 bytes, the lengths r-9, r-8, r-2, r-1, r, r+1 and r+8 for one, two and three rate blocks r, and 40 random lengths. Run without and with 30 % idle cycles on `valid_i`; random `mode_i` after `start_i`; every fifth message first aborted by a 1 to 4 cycle reset (135 resets); 124 equal-length pairs with the same latency | 0 errors |
| `make vhdl-test` | GHDL analysis of the VHDL wrapper | pass |
| `make synth_report` | regenerated and compared with the committed `SYNTH_REPORT.md` | identical |

Quartus Prime Lite 25.1 (Cyclone V) and Vivado 2025.2 (Artix-7) compiled
the core out of context (place, route and timing, no hardware); see
[`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md). These runs are not in CI.

Not verified: FPGA hardware; place and route on ECP5; timing inside a full
design with real I/O; formal proofs (none exist); NIST CAVP/CMVP; power, EM
and fault attacks; mixed-language simulation of the VHDL wrapper; SHAKE
output longer than 64 bytes (the core squeezes one block).

The sections below describe the directed tests in `make test`.

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

A dedicated test checks that on the empty input, SHA3-256 produces `a7ffc6f8...` and Ethereum Keccak-256 produces `c5d24601...`, and that the two are different.

### Random cross-validation (125 messages)

25 random messages per mode times 5 modes. Lengths drawn from `{0, 1, 32, 71, 72, 135, 136, 137, 167, 168, 169}` plus 14 random lengths in [170, 2000], chosen to land on every rate boundary (SHA3-512 rate = 72, SHA3-256 / SHAKE256 / Keccak-256 rate = 136, SHAKE128 rate = 168). Expected digests are generated with `hashlib.sha3_*`, `hashlib.shake_*`, and `pycryptodome.Crypto.Hash.keccak`.

### SystemVerilog assertions

`tb/keccak_assertions.sv` checks protocol invariants on every cycle of `make test`:

- Each Keccak-f[1600] permutation completes in exactly 25 cycles
- `digest_o` is stable while `digest_valid_o` is asserted
- The round counter never exceeds 23
- `ready_o` is low whenever `busy_o` is high (no transfer mid-permutation)
- `pad_block_valid` is a single-cycle pulse (padder emits exactly one block per launch)
- Rate-buffer fill counter never exceeds the per-mode rate

The assertions run under Verilator 5 (`--assert`); Vivado xsim was not tried. They are stripped on synthesis flows via `` `ifndef SYNTHESIS ``.

### Functional coverage

`tb/keccak_cov.sv` collects ten bins. `make test` prints:

```
---- Functional coverage ----
  [HIT ] mode_sha3_256 / mode_sha3_512 / mode_shake128 / mode_shake256 / mode_eth_k256
  [HIT ] single_block / multi_block / back_to_back / reset_mid_hash / empty_message
Coverage: 10/10 bins (100.0%)
```

The harness fails a run that drops below 100 %.

### Synthesis comparison report

`make synth_report` runs every available toolchain on the same RTL and emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side LUT/FF/BRAM table. Yosys (`synth_ice40` / `synth_ecp5` / `synth_xilinx`) is mandatory; Vivado and Quartus are detected automatically and skipped with a notice when not on `$PATH`. The place-and-route runs use `scripts/quartus_compile.tcl` and `scripts/vivado_compile.tcl` instead.

## Variants

| Variant                              | Use case                                                                                    |
|--------------------------------------|---------------------------------------------------------------------------------------------|
| `rtl/keccak_round.sv`                | Combinational theta / rho / pi / chi / iota single-round update                             |
| `rtl/keccak_f1600.sv`                | 24-round iterative Keccak-f[1600] permutation                                                |
| `rtl/keccak_padder.sv`               | FIPS-202 `pad10*1` + domain-byte selector (SHA3 / SHAKE / Ethereum)                          |
| `rtl/keccak_top.sv`                  | Streaming top with 3-bit mode select; all 5 variants behind a single port surface |
| `vhdl_wrapper/keccak_top_vhdl.vhd`   | VHDL-2008 entity wrapping the SV streaming top for VHDL-only designs                         |

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source projects. If your product links this RTL or its compiled bitstream, your project must also be GPL-3.0+.
- **Commercial license** for closed-source products. Commercial licenses are available on request: open a GitHub issue titled 'Commercial license request'. Do not post confidential details in the issue. Any commercial license is provided as is, without warranty, support or maintenance. This core is verified in simulation only (see README). See [`LICENSE.md`](LICENSE.md) for the license text.

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
  tb_vectors.sv            reference-vector regression (make test-vectors)
  keccak_top_tb.sv         DUT wrapper + assertion + coverage instantiation
  keccak_assertions.sv     SVA properties
  keccak_cov.sv            functional coverage collector
  nist_vectors.sv          FIPS-202 vectors as a SV package (non-Verilator sims)
  eth_vectors.sv           Ethereum Keccak-256 vectors as a SV package
  random_vectors.h         generated cross-validation vectors (hashlib + pycryptodome)
  gen_random_vectors.py    regenerates random_vectors.h
vhdl_wrapper/            VHDL-2008 wrapper for mixed-language designs
scripts/                 synth_report.sh, vhdl_cosim.sh, gen_vectors.py,
                         quartus_compile.tcl, vivado_compile.tcl
.github/                 CI workflow
Makefile                 build / lint / sim / test-vectors / synth / synth_report / vhdl-test
```

## Contributing

Bug reports and patches welcome. Process:

1. File an issue first for non-trivial changes.
2. Fork, branch, and run `make lint test test-vectors synth_report` locally.
3. Open a pull request with a description of what changed and why.
4. CI runs the same checks on the pull request.

## Citation

```bibtex
@misc{keccak-fpga-core,
  title  = {{keccak-fpga-core}: a dual-licensed Keccak / SHA-3 family IP core in SystemVerilog with Ethereum Keccak-256 support},
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
