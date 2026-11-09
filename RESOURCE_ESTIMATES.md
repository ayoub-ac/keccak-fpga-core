# Resources and timing

All numbers below were measured on the v1.1.0 RTL with the OSS CAD Suite
2026-11-01 build (Yosys 0.70), Quartus Prime Lite 25.1std.0 build 1129 and
Vivado ML Standard 2025.2 (Linux). Yosys counts are flattened and taken
before place and route. nextpnr and Diamond were not run.

## Synthesis (Yosys)

`make synth_report` writes [`SYNTH_REPORT.md`](SYNTH_REPORT.md), which CI
regenerates and compares on every push.

| Target | LUT | FF | Other |
|---|---|---|---|
| iCE40 (`synth_ice40`) | 18252 LUT4 | 5922 | 0 block RAM |
| ECP5 (`synth_ecp5 -abc9`) | 25647 LUT4 | 5922 | 9730 PFUMX / L6MUX21 |
| Xilinx 7-series (`synth_xilinx -flatten`) | 15600 LUT6 | 5922 | 599 MUXF7 / MUXF8 |

| Device | Capacity | Result |
|---|---|---|
| iCE40 UP5K / HX8K | 5280 / 7680 LUT4 | does not fit |
| Gowin GW1NR-9 (Tang Nano 9K) | 8640 LUT4 | does not fit (Yosys count for iCE40 LUT4: 18252) |
| ECP5 LFE5U-25F | 24288 LUT4 | does not fit |
| ECP5 LFE5U-45F / 85F | 43848 / 83640 LUT4 | not placed |
| Cyclone V 5CSEMA5F31C6 | 32070 ALM | places at 28 % (Quartus) |
| Artix-7 xc7a35t | 20800 LUT6 | places at 63 % of the LUTs (Vivado) |

## What uses the area

The 5922 flip-flops are, per module (Yosys, before flattening):

| Register | Bits | Module |
|---|---|---|
| Keccak-f[1600] state | 1600 | `keccak_f1600` (1605 with the round counter) |
| Rate buffer (`buf_q`) | 1344 | `keccak_top` |
| Final block (`finalblk_q`) | 1344 | `keccak_top` |
| Padded block (`block_q`) | 1344 | `keccak_padder` |
| FSM, counters, mode latch, handshake | about 290 | all three |

The three 1344-bit registers are each sized for the largest rate (SHAKE128,
168 bytes). The padder output and the final-block register hold the same
block one after the other, and the rate buffer could be absorbed lane by
lane instead of block by block; merging them would save up to about 2700
flip-flops. No such variant is in this repository.

The LUTs are the round function (theta, chi and iota over 1600 bits, rho
and pi are wiring) plus the absorb XOR and the multiplexers that select the
rate per mode.

## Place and route (Quartus Prime Lite)

Cyclone V 5CSEMA5F31C6 (the DE1-SoC device), full compile (analysis and
synthesis, fitter, timing analyser), 200 MHz clock constraint on `clk_i`.
Every port except `clk_i` is a virtual pin, so the numbers cover the core
alone; `clk_i` sits on an ordinary pin and uses non-dedicated clock routing.
Fmax is register to register from the timing analyser, for the slow 1100 mV
85 °C and 0 °C models. No block RAM or DSP blocks are used. The result was
reproduced by an identical second run.

| Core | ALM | Registers | Fmax 85 °C | Fmax 0 °C |
|---|---|---|---|---|
| `keccak_top` | 8882 (28 %) | 5919 | 123.09 MHz | 125.25 MHz |

The 200 MHz constraint is not met. Reproduce from an empty directory with
`quartus_sh -t <repo>/scripts/quartus_compile.tcl <repo>/rtl keccak_top`
(the device and the clock period are optional third and fourth arguments).

## Place and route (Vivado)

Artix-7 xc7a35tcsg324-1, speed grade -1, out-of-context synthesis,
`opt_design`, `place_design` and `route_design` with default directives,
5 ns clock constraint on `clk_i`, no I/O constraints. Fmax is
1000 / (5 - WNS) from the routed design, register to register. Out of
context the clock source is not known (`HD.CLK_SRC` is unset), so clock skew
is not estimated; inside a full design the result can differ. No block RAM
or DSP is used. The result was reproduced by an identical second run.

| Core | LUT | FF | Slices | WNS | Fmax |
|---|---|---|---|---|---|
| `keccak_top` | 13149 (63 %) | 5946 | 3367 (41 %) | -3.186 ns | 122.16 MHz |

Reproduce from an empty directory with
`vivado -mode batch -source <repo>/scripts/vivado_compile.tcl -tclargs <repo>/rtl keccak_top`
(the part and the clock period are optional third and fourth arguments).

## Throughput

Cycle counts are measured in simulation (see
[`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md#timing)); the MB/s figures are
computed from them at 122 MHz, the Artix-7 result above, for long messages
streamed at one beat per cycle. Nothing was measured on hardware.

| Mode | Rate | Cycles per block | Bytes per cycle | At 122 MHz |
|---|---|---|---|---|
| SHA3-256, SHAKE256, Keccak-256 | 136 B | 42 (17 beats + 25) | 3.24 | about 395 MB/s |
| SHA3-512 | 72 B | 34 (9 beats + 25) | 2.12 | about 258 MB/s |
| SHAKE128 | 168 B | 46 (21 beats + 25) | 3.65 | about 445 MB/s |

Absorbing and permuting do not overlap, so a design that streams faster than
this has to hold `valid_i` while `ready_o` is low.

## Power

Not measured or estimated. Use the vendor power estimator for your device
with your clock and toggle rates.
