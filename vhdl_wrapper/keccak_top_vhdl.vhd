-- SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog keccak_top module.
--
-- This entity exposes the streaming Keccak / SHA-3 top's port list in VHDL
-- syntax. The architecture instantiates the SystemVerilog module by component
-- name; mixed-language elaboration is supported natively by Vivado, Quartus,
-- ModelSim / Questa, and Aldec, and via the GHDL VHPI bridge for open
-- simulation.
--
-- Status: WRAPPER ONLY. The Keccak datapath itself remains in SystemVerilog
-- (rtl/*.sv). A native VHDL port of the datapath is listed as future work in
-- vhdl_wrapper/README.md.
--
-- I/O contract: identical to keccak_top.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-low synchronous reset.
--   * 3-bit mode select (SHA3-256 / SHA3-512 / SHAKE128 / SHAKE256 /
--     Ethereum Keccak-256).
--   * Streaming 64-bit input with valid_i / ready_o handshake plus last_i.
--   * 512-bit digest output (low bits zero for 256-bit modes).

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity keccak_top_vhdl is
  port (
    clk_i          : in  std_logic;
    rst_ni         : in  std_logic;
    mode_i         : in  std_logic_vector(2 downto 0);
    start_i        : in  std_logic;
    data_i         : in  std_logic_vector(63 downto 0);
    valid_i        : in  std_logic;
    last_i         : in  std_logic;
    last_bytes_i   : in  std_logic_vector(3 downto 0);
    ready_o        : out std_logic;
    digest_o       : out std_logic_vector(511 downto 0);
    digest_bits_o  : out std_logic_vector(9 downto 0);
    digest_valid_o : out std_logic;
    busy_o         : out std_logic
  );
end entity keccak_top_vhdl;

architecture rtl of keccak_top_vhdl is

  -- Forward declaration of the SystemVerilog component. Tools resolve this by
  -- name at elaboration; the SystemVerilog source must be added to the same
  -- compilation library (work) before the VHDL elaboration step.
  component keccak_top
    port (
      clk_i          : in  std_logic;
      rst_ni         : in  std_logic;
      mode_i         : in  std_logic_vector(2 downto 0);
      start_i        : in  std_logic;
      data_i         : in  std_logic_vector(63 downto 0);
      valid_i        : in  std_logic;
      last_i         : in  std_logic;
      last_bytes_i   : in  std_logic_vector(3 downto 0);
      ready_o        : out std_logic;
      digest_o       : out std_logic_vector(511 downto 0);
      digest_bits_o  : out std_logic_vector(9 downto 0);
      digest_valid_o : out std_logic;
      busy_o         : out std_logic
    );
  end component;

begin

  u_keccak : keccak_top
    port map (
      clk_i          => clk_i,
      rst_ni         => rst_ni,
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

end architecture rtl;
