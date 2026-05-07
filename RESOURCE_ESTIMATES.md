# Resource estimates

Numbers below are from Yosys 0.33 generic synthesis (`make synth` / `make synth_report`). They are pre-place-and-route, so the vendor flow (nextpnr / Vivado / Diamond) will usually pack tighter, especially on iCE40 where SB_LUT4 + carry chains pack across boundaries that Yosys does not, and on Xilinx where Vivado fuses small LUTs into LUT6 + LUT6_2. Run `make synth_report` for authoritative numbers on your toolchain version.

## What dominates the area

Keccak-f[1600] is a wide algorithm: the sponge state is **1600 bits** (25 lanes x 64 bits). The streaming top in this repo carries:

- **Sponge state**       1600 FFs  (25 lanes x 64 bits)
- **Rate-block buffer**  1344 FFs  (RATE_MAX = 168 bytes = SHAKE128 rate)
- **Final-block buffer** 1344 FFs  (latched padder output; can be merged with rate buffer in a future revision to save area)
- **Round counter**         5 FFs
- **FSM / mode latch**     ~10 FFs
- **Misc.**                ~30 FFs

Total ~4.3k FFs. The combinational logic per round is dominated by the theta XORs (5x 5-input + 5x 2-input over 64 bits = ~700 LUT-equivalents) plus chi (25x 3-input AND-XOR over 64 bits = ~1600 LUT-equivalents) plus the rho rotations (no logic on FPGA — fixed wiring). Iota's round-constant ROM is small. Total round update is roughly 2.5k LUT-equivalents on a 4-LUT architecture, before the surrounding control / mux / mode-select logic.

These numbers are commensurate with the published Keccak FPGA literature for a "basic" iterative implementation:

- Bertoni et al., **Keccak implementation overview**, 2012: cite ~1.6k slices on Virtex-5 for the same iterative architecture.
- Akin et al., **Efficient hardware implementations of high throughput SHA-3 candidates in keystream generation**, 2010: cite 2-3k slices range on Virtex-5 for various unrolling levels.
- Pessl & Hutter, **Pushing the limits of SHA-3 hardware**, 2012: cite 1.3-2.0k slices on different FPGAs depending on architecture.

A slice is roughly 4 LUTs + 8 FFs, so 1.6k slices ~ 6.4k LUTs / 12.8k FFs. Our numbers post-Yosys generic-synth are upper-bounded by these figures.

## What you can do to shrink it

- **Use a smaller `RATE_MAX`** (parameter on the `keccak_padder`). If you only need SHA3-256 or SHA3-512, set `RATE_MAX_BYTES` to the largest rate you actually use (136 or 72 respectively). This cuts the rate buffer + final-block buffer by ~30-50%.
- **Drop unused modes**: the streaming top supports five variants. If your application is "Ethereum Keccak-256 only" or "SHA3-256 only", strip the mode-select muxes and the unused domain bytes for a small but non-trivial LUT win.
- **Externalise the rate buffer to BRAM**: with `(* ram_style = "block" *)` (Vivado) or `(* ram_style = "distributed" *)` (Yosys / Lattice), the rate buffer can drop into a small block RAM, reclaiming ~1.3k FFs at the cost of ~1 BRAM. Available in the Premium tier.

## What you can do to push throughput

- **Unrolled / parallel variant** (Premium): unroll 2 or 4 rounds per cycle to halve / quarter the per-block latency. Useful for blockchain mining, very high-throughput TLS / KMAC, or high-frequency derived-function squeezing.
- **Rate-buffer streaming absorb**: instead of buffering an entire rate-block before kicking off the permutation, absorb partial blocks lane-by-lane as they arrive. Reduces tail latency by up to one rate's worth of cycles.

## Frequency

- iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints: ~30-50 MHz typical (the chi 3-AND-XOR tree is the long path; on a 4-LUT-only fabric this fans out across multiple LUT levels).
- ECP5: ~80-120 MHz typical.
- Artix-7 -1 speed grade: ~150-200 MHz typical, ~250 MHz with effort and timing constraints. Vivado tends to push retiming through the chi tree automatically.

The combinational path is dominated by the round update: theta-> rho-> pi (free wires) -> chi -> iota. Pipelining one stage between theta and chi is the obvious throughput knob; it lives in the Premium pipelined variant.

## Power

Ballpark: 10-25 mW dynamic on iCE40 UP5K at 50 MHz, depending on data activity. Static power is dominated by the FPGA itself.

## How to reproduce

```bash
make synth          # all three Yosys targets
make synth_report   # writes SYNTH_REPORT.md with current numbers
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and `synth_xilinx` and dumps statistics in `synth_*.log`. The stats line at the bottom tells you cell counts per primitive.

For end-to-end place-and-route numbers (post-PnR LUT counts and timing), run the vendor flow:

- iCE40 / ECP5: nextpnr-ice40 / nextpnr-ecp5 with Yosys output (open toolchain).
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
