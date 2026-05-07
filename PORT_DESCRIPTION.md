# Port description

This document is the contract for `keccak_top`. Bit widths, polarity, timing, and the streaming protocol.

## Module declaration

```systemverilog
module keccak_top (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [2:0]   mode_i,
  input  logic         start_i,
  input  logic [63:0]  data_i,
  input  logic         valid_i,
  input  logic         last_i,
  input  logic [3:0]   last_bytes_i,
  output logic         ready_o,
  output logic [511:0] digest_o,
  output logic [9:0]   digest_bits_o,
  output logic         digest_valid_o,
  output logic         busy_o
);
```

## Pin-by-pin

| Signal           | Dir | Width | Description |
|------------------|-----|-------|-------------|
| `clk_i`          | in  | 1     | System clock. All flops sample on the rising edge. |
| `rst_ni`         | in  | 1     | Synchronous, active-low reset. Hold low for >= 4 clocks before first command. |
| `mode_i`         | in  | 3     | Variant select (latched at `start_i`). 0 = SHA3-256, 1 = SHA3-512, 2 = SHAKE128, 3 = SHAKE256, 4 = Ethereum Keccak-256. |
| `start_i`        | in  | 1     | Pulse for one cycle to begin a new hash. The sponge state is cleared and `mode_i` is latched. |
| `data_i`         | in  | 64    | Streaming message data, 8 bytes per beat. Byte 0 of the message is at bits `[7:0]`, byte 7 at `[63:56]` (LSB-first within each 64-bit lane, matching FIPS-202 §B.1). |
| `valid_i`        | in  | 1     | Master asserts when `data_i` is valid. Transfer accepted on `valid_i && ready_o`. |
| `last_i`         | in  | 1     | Asserted on the final beat of a message. `last_bytes_i` indicates how many bytes of `data_i` are valid. |
| `last_bytes_i`   | in  | 4     | Valid bytes in the final beat (0..8). Use 0 for an empty message (with `last_i=1` and any `data_i`). |
| `ready_o`        | out | 1     | Core is ready to accept a new beat. `valid_i && ready_o` = transfer accepted. |
| `digest_o`       | out | 512   | Squeezed digest. For 256-bit modes (SHA3-256, SHAKE128, ETH-Keccak-256) the digest occupies bits `[511:256]` and the low 256 bits are zero. For 512-bit modes (SHA3-512, SHAKE256) the full 512 bits are populated. The first squeezed byte lives at bits `[511:504]`. |
| `digest_bits_o`  | out | 10    | Number of valid digest bits (256 or 512), reflecting the latched mode. |
| `digest_valid_o` | out | 1     | Pulses high for one cycle when the squeezed digest is valid on `digest_o`. |
| `busy_o`         | out | 1     | High while a permutation or final-block flow is in flight. |

## Handshake

- The master pulses `start_i` for one cycle with the desired `mode_i`. The DUT clears the sponge state and `ready_o` rises.
- The master streams the message in 8-byte beats. On every beat with `valid_i && ready_o`, 1..8 bytes of `data_i` are absorbed into the rate buffer.
- The final beat asserts `last_i` together with `last_bytes_i` (0..8). For an empty message, drive `last_i = 1` and `last_bytes_i = 0`.
- After the last beat, the DUT runs the closing permutation(s) and pulses `digest_valid_o` for one cycle. `digest_o` reflects the final digest from the cycle of `digest_valid_o` until the next `start_i`.

### Input handshake (master -> core)

```
clk         _|‾|_|‾|_|‾|_|‾|_
ready_o    1   1   1   0   ...   (drops while a permutation runs)
valid_i    0   1   1   0   ...
data_i     -   D   D   -
last_i     -   0   1   -          (1 on the final beat)
last_bytes -   8   N   -          (N = bytes in final beat, 0..8)

           ^ here the master drives data and valid_i; ready_o is also high,
             so the beat is accepted on this rising edge. The core lowers
             ready_o while the rate buffer is being absorbed and the
             permutation runs.
```

### Output (core -> master)

```
clk             _|‾|_|‾|_|‾|_|‾|_
digest_valid_o 0   1   0   ...
digest_o       -   D   D   -      (D is the digest; stable from the cycle
                                   digest_valid_o pulses until the next
                                   start_i)
```

`digest_valid_o` is a single-cycle pulse, not a held flag. `digest_o` is held until the next `start_i`.

## Driving a hash

Typical full sequence:

1. Reset the core (`rst_ni = 0` for >= 4 clocks, then `rst_ni = 1`).
2. Drive `mode_i` and pulse `start_i` for one cycle.
3. Wait for `ready_o`.
4. Stream the message in 8-byte beats. On each beat: drive `data_i`, `valid_i = 1`, `last_i = 0` for non-final beats.
5. On the final beat: drive remaining bytes (1..8) on `data_i` low bits, set `valid_i = 1`, `last_i = 1`, `last_bytes_i = remaining_bytes`.
6. For an empty message, send only step 5 with `last_bytes_i = 0`.
7. Wait for `digest_valid_o`. Read `digest_o`.

## Timing

- **Per Keccak-f[1600] permutation**: 25 cycles (24 round cycles + 1 done pulse cycle).
- **Per rate block**: ~25 + ~3 cycles of FSM overhead (absorb / permute boundary handling). Streaming throughput is gated by the master's beat rate; the core absorbs at one beat per cycle until the rate buffer fills.
- **Tail latency**: a final partial-block message takes ~25 cycles (padder) + 25 cycles (closing permutation) + 1 cycle (digest_valid_o pulse).
- For an N-byte message at a steady streaming rate, total cycles are dominated by ceil(N / rate) * 25 plus ~3 cycles of overhead per permutation.

## Reset

- `rst_ni` is **synchronous**, **active-low**.
- Drive `rst_ni = 0` for at least four `clk_i` rising edges before the first command.
- During reset all output signals are low, all internal state is cleared. The previously running hash is wiped — issue a fresh `start_i` on the next command.

## Endianness clarification

- Byte 0 of the message lives in bits `[7:0]` of `data_i`. Byte 7 lives in bits `[63:56]`. This is FIPS-202 §B.1 LSB-first-within-each-byte.
- The first squeezed byte of the digest lives in bits `[511:504]` of `digest_o`. So the digest reads naturally as a hex string with `digest_o[511:504]` as the first byte of `0x...`.

## Mode select details

| `mode_i` | Variant            | Rate (bits) | Capacity (bits) | Output bits | Domain byte |
|----------|--------------------|------------:|----------------:|------------:|------------:|
| 0        | SHA3-256           | 1088        | 512             | 256         | `0x06`      |
| 1        | SHA3-512           | 576         | 1024            | 512         | `0x06`      |
| 2        | SHAKE128           | 1344        | 256             | 256 (fixed) | `0x1f`      |
| 3        | SHAKE256           | 1088        | 512             | 512 (fixed) | `0x1f`      |
| 4        | Ethereum Keccak-256| 1088        | 512             | 256         | `0x01`      |

The Ethereum Keccak-256 variant (`mode_i = 4`) implements the **original** Keccak submission, NOT FIPS-202 SHA3-256. The only difference is the domain separation byte (`0x01` vs `0x06`), but it is enough to make the digests of any non-empty input differ. See the README "Ethereum vs SHA3-256" section for why this matters and which one your application needs.

## Clock domain

Single clock domain. `clk_i` clocks every flop in the design. If your system is multi-clock, instantiate this core in its own domain and use a CDC FIFO on `data_i` / `digest_o`.

## Synthesis attributes

The core uses no vendor-specific attributes. It synthesizes cleanly with Yosys (`synth_ice40`, `synth_ecp5`, `synth_xilinx`) and with Vivado (default flow).
