# VHDL wrapper

`keccak_top_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `keccak_top` module under a VHDL-friendly interface. Use it
from a VHDL design that does not want to touch SystemVerilog directly.

## Status

**Wrapper only.** The Keccak datapath (theta / rho / pi / chi / iota,
sponge state, padder, mode select) lives in `rtl/*.sv` and is instantiated
as a SystemVerilog black-box. Mixed-language elaboration is supported by
every commercial simulator and synthesiser the core has been tested
against.

A pure VHDL re-implementation of the core is on the roadmap (Premium tier,
scope: parity with `rtl/keccak_top.sv` including the same testbench
checks). Until then, treat this directory as a binding layer, not as a
second implementation.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `keccak_top_vhdl.vhd` to the same
project library (`work` is fine). The toolchain resolves the SV component
automatically:

```tcl
# Vivado
read_verilog -sv {rtl/keccak_round.sv rtl/keccak_f1600.sv rtl/keccak_padder.sv rtl/keccak_top.sv}
read_vhdl -vhdl2008 vhdl_wrapper/keccak_top_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/keccak_round.sv rtl/keccak_f1600.sv rtl/keccak_padder.sv rtl/keccak_top.sv
vcom -2008 vhdl_wrapper/keccak_top_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

GHDL compiles the VHDL side, Verilator compiles the SV side, and the two are
linked through GHDL's VHPI bridge. The provided `make vhdl-test` target wraps
this; run it from the repository root:

```
make vhdl-test
```

The target is a no-op (with a notice) if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  signal clk, rstn, start_i, valid_i, last_i, ready_o : std_logic;
  signal digest_valid_o, busy_o                       : std_logic;
  signal mode_i                                       : std_logic_vector(2 downto 0);
  signal data_i                                       : std_logic_vector(63 downto 0);
  signal last_bytes_i                                 : std_logic_vector(3 downto 0);
  signal digest_o                                     : std_logic_vector(511 downto 0);
  signal digest_bits_o                                : std_logic_vector(9 downto 0);
begin
  u_keccak : entity work.keccak_top_vhdl
    port map (
      clk_i          => clk,
      rst_ni         => rstn,
      mode_i         => mode_i,
      start_i        => start_i,
      data_i         => data_i,
      valid_i        => valid_i,
      last_i         => last_i,
      last_bytes_i   => last_bytes_i,
      ready_o        => ready_o,
      digest_o       => digest_o,
      digest_bits_o  => digest_bits_o,
      digest_valid_o => digest_valid_o,
      busy_o         => busy_o
    );
end architecture;
```

## What this wrapper does NOT change

* Latency, throughput, area: identical to `keccak_top.sv`. There is no
  additional pipeline stage. 25 cycles per Keccak-f[1600] permutation
  plus padder + handshake overhead.
* Endianness: byte 0 of the message is at bits `[7:0]` of `data_i` (LSB-
  first within each lane), exactly as documented in `PORT_DESCRIPTION.md`.
  This matches FIPS-202 §B.1 bit-string conversion.
* Reset polarity: still active-low synchronous (`rst_ni`).
