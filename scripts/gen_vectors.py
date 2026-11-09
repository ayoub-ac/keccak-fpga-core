# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
"""Write reference vectors for tb/tb_vectors.sv.

One line per message: <mode> <length> <digest, 128 hex> <message hex, or 'x' when empty>.
SHA3-256/512 and SHAKE128/256 come from Python hashlib (OpenSSL), Ethereum
Keccak-256 from pycryptodome; neither depends on the RTL.

The digest follows the port contract of keccak_top: first output byte at
digest_o[511:504], 256-bit modes zero the low 256 bits, SHAKE modes squeeze
64 bytes. For every mode the lengths cover 0..17 bytes, the bytes around 1, 2
and 3 rate blocks (r-9, r-8, r-2, r-1, r, r+1, r+8) and 40 random lengths below
4 rate blocks. At r-1 the domain bits and the final pad bit share one byte.

    python3 scripts/gen_vectors.py OUT [SEED]
"""
import hashlib
import random
import sys

from Crypto.Hash import keccak

RATE = {0: 136, 1: 72, 2: 168, 3: 136, 4: 136}  # bytes, FIPS 202 Table 3


def digest(mode, msg):
    if mode == 0:
        d = hashlib.sha3_256(msg).digest() + bytes(32)
    elif mode == 1:
        d = hashlib.sha3_512(msg).digest()
    elif mode == 2:
        d = hashlib.shake_128(msg).digest(64)
    elif mode == 3:
        d = hashlib.shake_256(msg).digest(64)
    else:
        d = keccak.new(digest_bits=256, data=msg).digest() + bytes(32)
    return d.hex()


def lengths(rate, rng):
    edge = set(range(18))
    for k in (1, 2, 3):
        edge |= {k * rate + d for d in (-9, -8, -2, -1, 0, 1, 8)}
    edge |= {rng.randrange(0, 4 * rate) for _ in range(40)}
    return sorted(edge)


def main(path, seed):
    rng = random.Random(seed)
    lines = []
    for mode, rate in RATE.items():
        for n in lengths(rate, rng):
            msg = bytes(rng.randrange(256) for _ in range(n))
            lines.append(f"{mode} {n} {digest(mode, msg)} {msg.hex() or 'x'}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{len(lines)} vectors -> {path}")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 1)
