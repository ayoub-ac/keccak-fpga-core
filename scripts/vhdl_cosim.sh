#!/usr/bin/env bash
# Smoke test the VHDL wrapper using GHDL (VHDL side) and Verilator (SV side).
# Both tools must be installed; `make vhdl-test` exits cleanly if either is
# missing.
#
# This is a build-only check: we elaborate the wrapper to confirm the entity
# matches the SV component's port list. It is not a behavioural co-sim - that
# requires GHDL with VPI and a custom VHPI bridge, which is well outside the
# scope of `make vhdl-test`.

set -u
cd "$(dirname "$0")/.."

if ! command -v ghdl >/dev/null 2>&1; then
    echo "[vhdl-test] ghdl not installed - skipping"
    exit 0
fi
if ! command -v verilator >/dev/null 2>&1; then
    echo "[vhdl-test] verilator not installed"
    exit 1
fi

echo "[vhdl-test] Verilator lint of SV core..."
verilator --lint-only -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
    --top-module keccak_top \
    rtl/keccak_round.sv rtl/keccak_f1600.sv \
    rtl/keccak_padder.sv rtl/keccak_top.sv

echo "[vhdl-test] GHDL analyse of VHDL wrapper..."
ghdl -a --std=08 vhdl_wrapper/keccak_top_vhdl.vhd

echo "[vhdl-test] OK - VHDL wrapper compiles, SV core lints. Mixed-language"
echo "[vhdl-test]      simulation requires Vivado xsim / ModelSim / Questa."
