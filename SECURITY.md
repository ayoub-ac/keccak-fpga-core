# Security model

This document describes what `keccak_top` is designed to defend against, what it is NOT designed to defend against, and how to evaluate the claims.

If you need a side-channel-resistant hash core for a real product, read this whole document and decide whether the threat model matches your deployment. Don't trust marketing copy; trust the threat model and your own evaluation.

## What is intended to be protected (not evaluated)

### 1. Constant-time execution

Keccak-f[1600] (FIPS-202) has no data-dependent branches, and the `keccak_f1600` permutation runs a fixed number of round cycles. In simulation the number of cycles from `start_i` to `digest_valid_o` depends only on the mode and the message length: `tb/tb_vectors.sv` hashes 124 messages a second time with other bytes of the same length and gets the same cycle count every time. See [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md#timing) for the cycle counts. Power and electromagnetic leakage are a different matter (see below).

**What this protects against**: timing attacks that observe completion latency to infer key or message bits. Only latency at the ports was checked, in simulation.

### 2. Bounded round count

The `p_round_bound` SVA assertion checks that the internal `round_q` counter never exceeds 23 on every cycle of `make test` (Verilator `--assert`). A runaway round counter would stop the test.

### 3. Mode isolation

`mode_i` is latched at the cycle of `start_i`. `tb/tb_vectors.sv` drives random values on `mode_i` for the rest of every hash, and every digest still matches the mode given at `start_i`. This prevents accidental cross-domain mixing (e.g. starting in SHA3-256 mode and finishing under Ethereum Keccak-256 padding).

### 4. Domain separation correctness

The padder XORs the FIPS-202 §6 domain byte (`0x06` for SHA3-*, `0x1f` for SHAKE) or the original Keccak `0x01` byte (Ethereum mode) into the first byte after the message tail. This is the standard "multi-rate padding" `pad10*1` rule, which prevents trivial collisions between different SHA-3 variants on the same input. The directed test suite checks that SHA3-256("") != Keccak-256("") (Test 3), and the reference-vector regression compares every mode against an independent implementation.

## What is NOT covered (be honest)

This list is deliberately exhaustive so users can evaluate fit:

- **Differential power analysis (DPA)** on the round update: the 1600-bit sponge state is unmasked. A power attacker measuring leakage at the FF-update boundary can mount standard CPA / DPA against intermediate values. Mitigation requires Boolean / arithmetic sharing of the state (typically TI / DOM masking schemes from the literature); not implemented.
- **Electromagnetic (EM) analysis** and **template attacks**: not specifically countered. There is no power-balancing, no differential routing, no constant-Hamming-weight encoding.
- **Fault injection** on the round counter, sponge state, or rate buffer: a flipped bit can corrupt the digest in ways that may or may not be detectable depending on where the fault lands. No duplicated-counter / parity-protected register implementation is shipped.
- **Cache / micro-architectural side channels**: not applicable (this is RTL, not software), but if you place this core into a system with a shared bus or shared memory, those channels can leak.
- **Length-extension on raw SHA3 / Keccak**: the sponge construction is length-extension resistant by design (because the capacity is unreachable from the rate side). This is a strict improvement over SHA-2. However, you still need an authenticated mode (HMAC, KMAC, AEAD) for keyed-MAC use cases — raw hashing is not authentication.
- **Invasive attacks** (decap, microprobing) are entirely out of scope.

If your deployment threat model includes any of the above and the rest of your system relies on hash integrity, this core is not enough on its own.

## Compliance claims

- **FIPS-202 conformance (SHA3-256, SHA3-512, SHAKE128, SHAKE256)**: not validated by NIST. In simulation the core matches the NIST example digests (empty, "abc", 200 x 0xA3) and Python `hashlib` (OpenSSL) on 371 messages per run of `make test-vectors`, with SHAKE squeezing 64 bytes.
- **Original Keccak / Ethereum Keccak-256 conformance**: not validated by any authority. In simulation the Ethereum mode matches `pycryptodome.Crypto.Hash.keccak.new(digest_bits=256)` on the same corpus, including the canonical `keccak256("")` constant `c5d24601...`.
- **NIST CAVP test certificate**: NOT obtained. The RTL is not registered with NIST CAVP. CAVP requires a test harness running on the certified platform, which is the integrator's responsibility.
- **FIPS-140-2 / FIPS-140-3 certification**: NOT claimed. FIPS-140 is a module-level certification covering far more than the algorithm (RNG quality, key zeroization, role-based authentication, physical security, etc.) and is the responsibility of the integrator. This core implements one of the building blocks; it is not by itself a FIPS-140 cryptographic module.
- **Common Criteria**: not evaluated.

## Test methodology used to validate the security claims

All of the checks below run in CI on every push (`.github/workflows/ci.yml`).

1. **Functional correctness on NIST example vectors**: `make test`. The NIST example messages (empty, "abc", 200 x 0xA3) for SHA3-256 / SHA3-512 / SHAKE128 / SHAKE256. `tb/nist_vectors.sv` quotes CAVP `*ShortMsg.rsp` entries for other simulators; the Verilator harness does not use it.
2. **Ethereum Keccak-256 reference vectors**: well-known fixtures (`keccak256("")`, `keccak256("abc")`, `keccak256("Hello, world!")`, etc.) cross-checked against `pycryptodome`.
3. **125 random cross-validation vectors** (`make test`): 25 random messages per mode, length distribution covering empty / single-block / two-block / multi-block / rate-aligned boundaries.
4. **SHA3 vs Ethereum-Keccak distinction test**: explicit assertion that `SHA3-256("")` and `Keccak-256("")` produce different digests. This is the canonical check that the domain-byte logic is correct.
5. **SVA protocol invariants, checked on every cycle of `make test`**: see `tb/keccak_assertions.sv`. Properties include permutation latency bound, digest stability, round-counter bound, init-during-busy ignored, padder-emits-one-block, and rate-buffer fill bound.
6. **Functional coverage**: 10 bins (5 modes, single/multi-block, back-to-back, reset-mid-hash, empty message). Coverage report printed at end of `make test`; all 10 are hit.
7. **Reference-vector regression** (`make test-vectors`): 371 messages against `hashlib` / `pycryptodome`, including the lengths just below, at and above one, two and three rate blocks, with idle cycles, resets mid-hash, random `mode_i` after `start_i`, and the data-independent latency check.

We do NOT run experimental DPA / CPA against a real bitstream. The constant-time claim covers latency at the ports in simulation only. An experimentally verified claim would require an FPGA, an oscilloscope, and a trace-collection campaign measured in days or weeks; none has been done.

## How to use the core safely

1. For any use case where you are authenticating data with a secret key, use a keyed mode (HMAC-SHA3, KMAC, or an AEAD construction) — not raw SHA3 / Keccak.
2. Hold `rst_ni` low for at least one rising clock edge after power-on and before the first command.
3. Wipe sensitive inputs from the master logic after use; the core does not auto-zero the rate buffer between hashes (the buffer holds residual bytes until the next `start_i` clears it).
4. For tag verification, use a constant-time MAC compare. A naive byte-by-byte memcmp leaks information.
5. **Do not confuse SHA3-256 and Ethereum Keccak-256**. They differ only in domain byte (`0x06` vs `0x01`), but they produce different digests. If your use case is Ethereum smart contracts, EVM hashing, EIP-191 / EIP-712 signatures, or any blockchain interop, you need `mode_i = 4` (Ethereum Keccak-256). If your use case is anything in the FIPS-202 / NIST hashing world (TLS 1.3 with SHA3, SP 800-185 derived functions, post-quantum signature schemes like Dilithium / Falcon / SLH-DSA), you need `mode_i = 0` (SHA3-256).

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with FIPS-202 / the original Keccak submission? Open a GitHub issue; do not post confidential details in it. Coordinated disclosure welcome. We do not currently offer a bug bounty.
