# Changelog

## 1.1.0 (unreleased)

A check of the initial release against an independent reference found the
digests correct in all five modes and the defects below.

### Fixed

- `keccak_top`: `absorb_block_packed()` indexed the 21-lane rate buffer
  with lanes 21 to 24. Simulation was not affected, but Quartus Prime
  stopped at elaboration (error 10232), so the core did not compile there.
- `make lint` and `make test` did not build on Verilator 5.05x
  (multi-driven coverage flags, `VlWide` port in the C++ harness).
- `make synth_report` wrote 0 LUT / 0 FF with current Yosys and counted
  only the top level on Xilinx; `make clean` deleted the committed
  `SYNTH_REPORT.md`.

### Added

- `make test-vectors`: 371 messages in all five modes against Python
  `hashlib` and `pycryptodome`, including the lengths just below, at and
  above one, two and three rate blocks, with idle cycles, resets of 1 to 4
  cycles mid-hash, random `mode_i` after `start_i`, and a check that
  latency does not depend on the message contents.
- GitHub Actions CI running lint, the directed tests, the VHDL wrapper
  analysis, the reference-vector regression and a check that
  `make synth_report` reproduces `SYNTH_REPORT.md`.
- `scripts/quartus_compile.tcl` and `scripts/vivado_compile.tcl`:
  out-of-context Quartus Prime and Vivado compiles; `RESOURCE_ESTIMATES.md`
  lists the Cyclone V and Artix-7 results.

### Documentation

- Measured area replaces the estimates. The core needs about 18k LUT4 on
  iCE40 and 26k LUT4 on ECP5, so it does not fit an iCE40 or a Tang Nano
  9K, which the documentation listed as targets. It holds 5922 flip-flops:
  the 1600-bit state, three 1344-bit rate-size registers and control.
- Measured latency replaces the design-intent cycle counts: 30 cycles from
  the last beat to `digest_valid_o` (56 when the length is a multiple of the
  rate), and rate / 8 beats plus about 25 cycles per full block.
- One reset cycle is enough; the four-cycle requirement is removed.
- SHAKE128 squeezes 512 bits; the mode table said 256.
