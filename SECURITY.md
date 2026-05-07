# Security model

This document describes what `keccak_top` is designed to defend against, what it is NOT designed to defend against, and how to evaluate the claims.

If you need a side-channel-resistant hash core for a real product, read this whole document and decide whether the threat model matches your deployment. Don't trust marketing copy; trust the threat model and your own evaluation.

## What is protected

### 1. Constant-time execution

Keccak-f[1600] (FIPS-202) has no data-dependent branches. The `keccak_f1600` permutation runs exactly 24 round cycles per call regardless of state content. The streaming top runs `ceil(message_bytes / rate_bytes)` permutations during absorption plus one closing permutation; the per-block schedule is fixed at 25 cycles + ~3 cycles of FSM overhead.

**What this protects**: timing attacks that observe completion latency to infer key or message bits. There is no path through the design that takes a different number of cycles depending on data values.

### 2. Bounded round count

The internal `round_q` counter is verified by the `p_round_bound` SVA assertion to never exceed 23. This is checked on every cycle of every test in the regression. Any FSM bug that allowed a runaway round counter would trip the assertion before reaching the output.

### 3. Mode isolation

The `mode_i` register is latched at the cycle of `start_i` and stable for the duration of the hash. Mid-hash mode changes on the input pin do not affect the in-flight computation. This prevents accidental cross-domain mixing (e.g. starting in SHA3-256 mode and finishing under Ethereum Keccak-256 padding).

### 4. Domain separation correctness

The padder XORs the FIPS-202 §6 domain byte (`0x06` for SHA3-*, `0x1f` for SHAKE) or the original Keccak `0x01` byte (Ethereum mode) into the first byte after the message tail. This is the standard "multi-rate padding" `pad10*1` rule, which prevents trivial collisions between different SHA-3 variants on the same input. The directed test suite includes a dedicated check that SHA3-256("") != Keccak-256("") (Test 3) to catch any regression that swaps domain bytes.

## What is NOT covered (be honest)

This list is deliberately exhaustive so purchasers can evaluate fit:

- **Differential power analysis (DPA)** on the round update: the 1600-bit sponge state is unmasked. A power attacker measuring leakage at the FF-update boundary can mount standard CPA / DPA against intermediate values. Mitigation requires Boolean / arithmetic sharing of the state (typically TI / DOM masking schemes from the literature); not implemented.
- **Electromagnetic (EM) analysis** and **template attacks**: not specifically countered. There is no power-balancing, no differential routing, no constant-Hamming-weight encoding.
- **Fault injection** on the round counter, sponge state, or rate buffer: a flipped bit can corrupt the digest in ways that may or may not be detectable depending on where the fault lands. No duplicated-counter / parity-protected register implementation is shipped.
- **Cache / micro-architectural side channels**: not applicable (this is RTL, not software), but if you place this core into a system with a shared bus or shared memory, those channels can leak.
- **Length-extension on raw SHA3 / Keccak**: the sponge construction is length-extension resistant by design (because the capacity is unreachable from the rate side). This is a strict improvement over SHA-2. However, you still need an authenticated mode (HMAC, KMAC, AEAD) for keyed-MAC use cases — raw hashing is not authentication.
- **Invasive attacks** (decap, microprobing) are entirely out of scope.

If your deployment threat model includes any of the above and the rest of your system relies on hash integrity, this core is not enough on its own.

## Compliance claims

- **FIPS-202 conformance (SHA3-256, SHA3-512, SHAKE128, SHAKE256)**: yes. The RTL implements the four FIPS-202 functions exactly as specified and is verified against published NIST CAVP test vectors plus 100 random messages cross-checked against `hashlib.sha3_*` / `hashlib.shake_*`.
- **Original Keccak / Ethereum Keccak-256 conformance**: yes. The Ethereum mode produces digests bit-identical to `pycryptodome.Crypto.Hash.keccak.new(digest_bits=256)` on the test corpus, including the canonical `keccak256("")` constant `c5d24601...`.
- **NIST CAVP test certificate**: NOT obtained. The RTL passes NIST CAVP known-answer tests in simulation, but is not registered with NIST CAVP. CAVP requires a test harness running on the certified platform, which is the integrator's responsibility.
- **FIPS-140-2 / FIPS-140-3 certification**: NOT claimed. FIPS-140 is a module-level certification covering far more than the algorithm (RNG quality, key zeroization, role-based authentication, physical security, etc.) and is the responsibility of the integrator. This core implements one of the building blocks; it is not by itself a FIPS-140 cryptographic module.
- **Common Criteria**: not evaluated.

## Test methodology used to validate the security claims

The Verilator testbench runs:

1. **Functional correctness on FIPS-202 vectors**: `make test`. Includes the canonical SHA3-256 / SHA3-512 / SHAKE128 / SHAKE256 vectors from FIPS-202 §A and CAVP `*ShortMsg.rsp` files.
2. **Ethereum Keccak-256 reference vectors**: well-known fixtures (`keccak256("")`, `keccak256("abc")`, `keccak256("Hello, world!")`, etc.) cross-checked against `pycryptodome`.
3. **125 random cross-validation vectors**: 25 random messages per mode, length distribution covering empty / single-block / two-block / multi-block / rate-aligned boundaries.
4. **SHA3 vs Ethereum-Keccak distinction test**: explicit assertion that `SHA3-256("")` and `Keccak-256("")` produce different digests. This is the canonical check that the domain-byte logic is correct.
5. **SVA-enforced protocol invariants on every cycle**: see `tb/keccak_assertions.sv`. Properties include permutation latency bound, digest stability, round-counter bound, init-during-busy ignored, padder-emits-one-block, and rate-buffer fill bound.
6. **Functional coverage**: 10 bins (5 modes, single/multi-block, back-to-back, reset-mid-hash, empty message). Coverage report printed at end of `make test`.

We do NOT run experimental DPA / CPA against a real bitstream. The constant-time claim is **design intent**, derived from the fact that FIPS-202 has no data-dependent branches. If you need an experimentally-verified claim, that is a separate engagement that requires an FPGA, an oscilloscope, and a trace-collection campaign measured in days or weeks. We do not sell that as part of this tier.

## How to use the core safely

1. For any use case where you are authenticating data with a secret key, use a keyed mode (HMAC-SHA3, KMAC, or an AEAD construction) — not raw SHA3 / Keccak.
2. Hold `rst_ni` low for >=4 cycles after power-on and before the first command.
3. Wipe sensitive inputs from the master logic after use; the core does not auto-zero the rate buffer between hashes (the buffer holds residual bytes until the next `start_i` clears it).
4. For tag verification, use a constant-time MAC compare. A naive byte-by-byte memcmp leaks information.
5. **Do not confuse SHA3-256 and Ethereum Keccak-256**. They differ only in domain byte (`0x06` vs `0x01`), but they produce different digests. If your use case is Ethereum smart contracts, EVM hashing, EIP-191 / EIP-712 signatures, or any blockchain interop, you need `mode_i = 4` (Ethereum Keccak-256). If your use case is anything in the FIPS-202 / NIST hashing world (TLS 1.3 with SHA3, SP 800-185 derived functions, post-quantum signature schemes like Dilithium / Falcon / SLH-DSA), you need `mode_i = 0` (SHA3-256).

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with FIPS-202 / the original Keccak submission? Open an issue or contact the email in the README. Coordinated disclosure welcome. We do not currently offer a bug bounty.
