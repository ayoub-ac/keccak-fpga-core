// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Verilator C++ harness for keccak_top.
//
// Drives FIPS-202 SHA-3 / SHAKE NIST test vectors plus Ethereum Keccak-256
// reference vectors plus 125 random cross-validation vectors against the
// DUT and verifies digest correctness, multi-block streaming, reset-mid-
// hash recovery, and back-to-back hashing across all five modes.
//
// Build: see Makefile (`make sim` or `make test`).
// Output: prints "+PASS" or "+FAIL <reason>" so the Makefile can grep.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vkeccak_top_tb.h"
#include "Vkeccak_top_tb___024root.h"
#include "Vkeccak_top_tb_keccak_top_tb.h"
#include "Vkeccak_top_tb_keccak_cov.h"
#include "random_vectors.h"

// ---------------------------------------------------------------------------
// Mode constants (must match keccak_top.sv)
// ---------------------------------------------------------------------------
constexpr int M_SHA3_256 = 0;
constexpr int M_SHA3_512 = 1;
constexpr int M_SHAKE128 = 2;
constexpr int M_SHAKE256 = 3;
constexpr int M_ETH_K256 = 4;

// ---------------------------------------------------------------------------
// Simulation primitives
// ---------------------------------------------------------------------------
static vluint64_t g_time = 0;
static int g_failures = 0;

static void tick(Vkeccak_top_tb* dut) {
    dut->clk_i = 0;
    dut->eval();
    g_time++;
    dut->clk_i = 1;
    dut->eval();
    g_time++;
}

static void reset(Vkeccak_top_tb* dut) {
    dut->rst_ni       = 0;
    dut->mode_i       = 0;
    dut->start_i      = 0;
    dut->valid_i      = 0;
    dut->last_i       = 0;
    dut->last_bytes_i = 0;
    dut->data_i       = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

// digest_o is 512 bits, exposed as uint32_t[16] with word[0] = bits [31:0].
// Bytes are placed MSB-first: the first squeezed byte lives at bit
// [511:504] of digest_o, which is word[15] bits [31:24].
static std::string digest_to_hex(const uint32_t* port_words, int n_bytes) {
    char buf[129];
    if (n_bytes > 64) n_bytes = 64;
    for (int byte = 0; byte < n_bytes; byte++) {
        int bit_hi = 511 - 8*byte;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        unsigned b = (port_words[word] >> shift) & 0xff;
        std::snprintf(buf + 2*byte, 3, "%02x", b);
    }
    buf[2*n_bytes] = 0;
    return std::string(buf);
}

// ---------------------------------------------------------------------------
// Drive a hash through the DUT.
// ---------------------------------------------------------------------------
static std::string run_msg(Vkeccak_top_tb* dut,
                           int mode,
                           const uint8_t* msg, size_t msg_len,
                           int digest_bytes,
                           const char* label,
                           int max_cycles = 200000) {
    // Pulse start_i for one cycle to begin a new hash. mode_i must be
    // stable on the pulse cycle.
    int waited = 0;
    while (!dut->ready_o) {
        // ready_o goes high after the first start (in T_ABSORB).
        if (waited == 0) {
            dut->mode_i  = static_cast<uint8_t>(mode);
            dut->start_i = 1;
            tick(dut);
            dut->start_i = 0;
        }
        tick(dut);
        if (++waited > max_cycles) {
            std::fprintf(stderr, "[%s] timeout waiting for ready_o\n", label);
            g_failures++;
            return "";
        }
    }

    // Stream the message in 8-byte chunks. The last chunk asserts last_i
    // with last_bytes_i = remaining bytes (0 for empty message).
    size_t pos = 0;
    while (true) {
        size_t remain = msg_len - pos;
        bool   is_last;
        size_t chunk;
        if (remain == 0) {
            // empty or just past the end: emit one last_i with zero bytes
            // (or, if pos > 0 and pos == msg_len, we already sent the last
            // chunk below)
            is_last = true;
            chunk   = 0;
        } else if (remain <= 8) {
            is_last = true;
            chunk   = remain;
        } else {
            is_last = false;
            chunk   = 8;
        }

        // Wait for ready_o.
        int w = 0;
        while (!dut->ready_o) {
            tick(dut);
            if (++w > max_cycles) {
                std::fprintf(stderr, "[%s] timeout mid-stream at pos=%zu\n",
                             label, pos);
                g_failures++;
                return "";
            }
        }

        // Pack `chunk` bytes into data_i, byte 0 -> bits [7:0].
        uint64_t word = 0;
        for (size_t k = 0; k < chunk; k++) {
            word |= static_cast<uint64_t>(msg[pos + k]) << (8 * k);
        }
        dut->data_i       = word;
        dut->valid_i      = 1;
        dut->last_i       = is_last ? 1 : 0;
        dut->last_bytes_i = static_cast<uint8_t>(chunk);
        tick(dut);
        dut->valid_i      = 0;
        dut->last_i       = 0;
        dut->last_bytes_i = 0;
        dut->data_i       = 0;

        pos += chunk;
        if (is_last) break;
    }

    // Wait for digest_valid_o.
    int w = 0;
    while (!dut->digest_valid_o) {
        tick(dut);
        if (++w > max_cycles) {
            std::fprintf(stderr, "[%s] timeout waiting for digest_valid_o\n",
                         label);
            g_failures++;
            return "";
        }
    }

    std::string digest_hex = digest_to_hex(dut->digest_o, digest_bytes);
    tick(dut);   // consume the one-cycle pulse
    return digest_hex;
}

// ---------------------------------------------------------------------------
// Hex parsing helper
// ---------------------------------------------------------------------------
static std::vector<uint8_t> hex_to_bytes(const char* hex) {
    std::vector<uint8_t> out;
    if (!hex) return out;
    size_t len = std::strlen(hex);
    out.reserve(len / 2);
    for (size_t i = 0; i + 1 < len; i += 2) {
        unsigned v;
        if (std::sscanf(hex + i, "%2x", &v) != 1) {
            std::fprintf(stderr, "bad hex byte at %zu in '%s'\n", i, hex);
            return out;
        }
        out.push_back(static_cast<uint8_t>(v));
    }
    return out;
}

static int digest_bytes_for_mode(int mode) {
    switch (mode) {
        case M_SHA3_256: return 32;
        case M_SHA3_512: return 64;
        case M_SHAKE128: return 32;   // fixed 256-bit squeeze
        case M_SHAKE256: return 64;   // fixed 512-bit squeeze
        case M_ETH_K256: return 32;
        default:         return 32;
    }
}

static const char* mode_name(int mode) {
    switch (mode) {
        case M_SHA3_256: return "SHA3-256";
        case M_SHA3_512: return "SHA3-512";
        case M_SHAKE128: return "SHAKE128";
        case M_SHAKE256: return "SHAKE256";
        case M_ETH_K256: return "ETH-Keccak-256";
        default:         return "?";
    }
}

// ---------------------------------------------------------------------------
// NIST FIPS-202 directed vectors (SHA-3 + SHAKE)
// ---------------------------------------------------------------------------
struct NistVec {
    const char* name;
    int         mode;
    const char* msg_ascii;   // if non-null, take ascii bytes; else use msg_hex
    const char* msg_hex;
    const char* digest_hex;
};

static const NistVec kFipsVectors[] = {
    {"FIPS-202 SHA3-256(empty)",     M_SHA3_256, "", nullptr,
        "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"},
    {"FIPS-202 SHA3-256(\"abc\")",   M_SHA3_256, "abc", nullptr,
        "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"},
    // 200-bit message all 0xa3 - tests two rate blocks (200 bits = 25 bytes)
    {"FIPS-202 SHA3-256(200x0xA3)",  M_SHA3_256, nullptr,
        "a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3",
        "62c5cfa81950c757191e6a7ae15b13760361e2575d8029c1ec6687217a4bdef0"},
    {"FIPS-202 SHA3-512(empty)",     M_SHA3_512, "", nullptr,
        "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"},
    {"FIPS-202 SHA3-512(\"abc\")",   M_SHA3_512, "abc", nullptr,
        "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0"},
    {"FIPS-202 SHAKE128(empty,32B)", M_SHAKE128, "", nullptr,
        "7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26"},
    {"FIPS-202 SHAKE128(\"abc\",32B)", M_SHAKE128, "abc", nullptr,
        "5881092dd818bf5cf8a3ddb793fbcba74097d5c526a6d35f97b83351940f2cc8"},
    {"FIPS-202 SHAKE256(empty,64B)", M_SHAKE256, "", nullptr,
        "46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762fd75dc4ddd8c0f200cb05019d67b592f6fc821c49479ab48640292eacb3b7c4be"},
    {"FIPS-202 SHAKE256(\"abc\",64B)", M_SHAKE256, "abc", nullptr,
        "483366601360a8771c6863080cc4114d8db44530f8f1e1ee4f94ea37e78b5739d5a15bef186a5386c75744c0527e1faa9f8726e462a12a4feb06bd8801e751e4"},
};
static constexpr int kNumFips = sizeof(kFipsVectors) / sizeof(kFipsVectors[0]);

// ---------------------------------------------------------------------------
// Ethereum Keccak-256 directed vectors
// ---------------------------------------------------------------------------
struct EthVec {
    const char* name;
    const char* msg_ascii;
    const char* msg_hex;
    const char* digest_hex;
};

static const EthVec kEthVectors[] = {
    {"keccak256(\"\")",            "", nullptr,
        "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"},
    {"keccak256(\"abc\")",         "abc", nullptr,
        "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"},
    {"keccak256(\"Hello, world!\")", "Hello, world!", nullptr,
        "b6e16d27ac5ab427a7f68900ac5559ce272dc6c37c82b3e052246c82244c50e4"},
    {"keccak256(32-byte alpha+digits)", "abcdefghijklmnopqrstuvwxyz123456", nullptr,
        "b3eae197a287fc6713806f1bab91dffee8c3445e8cc629b7cb0b1a2efdbcf93b"},
    // 137 bytes - one byte over the SHA3-256 / Keccak-256 rate (136),
    // exercises the multi-block path with the Ethereum domain byte.
    // 137 bytes of 0x55 = 274 hex chars (4 * 64 + 18).
    {"keccak256(137x0x55)",        nullptr,
        "5555555555555555555555555555555555555555555555555555555555555555"
        "5555555555555555555555555555555555555555555555555555555555555555"
        "5555555555555555555555555555555555555555555555555555555555555555"
        "5555555555555555555555555555555555555555555555555555555555555555"
        "555555555555555555",
        "51cea202c3f33cbf8f407211b468f8d180b3cf378203dd36ee2243ee3a86afd4"},
};
static constexpr int kNumEth = sizeof(kEthVectors) / sizeof(kEthVectors[0]);

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------
static void test_fips_vectors(Vkeccak_top_tb* dut) {
    std::printf("---- Test 1: FIPS-202 SHA-3 / SHAKE NIST vectors ----\n");
    for (int i = 0; i < kNumFips; i++) {
        const NistVec& v = kFipsVectors[i];
        std::vector<uint8_t> msg;
        size_t msg_len;
        if (v.msg_ascii != nullptr) {
            msg.assign(v.msg_ascii, v.msg_ascii + std::strlen(v.msg_ascii));
            msg_len = msg.size();
        } else {
            msg = hex_to_bytes(v.msg_hex);
            msg_len = msg.size();
        }
        int n = digest_bytes_for_mode(v.mode);
        std::string got = run_msg(dut, v.mode, msg.data(), msg_len, n, v.name);
        if (got == v.digest_hex) {
            std::printf("  [PASS] %s\n", v.name);
        } else {
            std::printf("  [FAIL] %s\n", v.name);
            std::printf("         expected %s\n", v.digest_hex);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }
}

static void test_eth_vectors(Vkeccak_top_tb* dut) {
    std::printf("---- Test 2: Ethereum Keccak-256 reference vectors ----\n");
    for (int i = 0; i < kNumEth; i++) {
        const EthVec& v = kEthVectors[i];
        std::vector<uint8_t> msg;
        if (v.msg_ascii != nullptr) {
            msg.assign(v.msg_ascii, v.msg_ascii + std::strlen(v.msg_ascii));
        } else {
            msg = hex_to_bytes(v.msg_hex);
        }
        std::string got = run_msg(dut, M_ETH_K256,
                                  msg.data(), msg.size(), 32, v.name);
        if (got == v.digest_hex) {
            std::printf("  [PASS] %s\n", v.name);
        } else {
            std::printf("  [FAIL] %s\n", v.name);
            std::printf("         expected %s\n", v.digest_hex);
            std::printf("         got      %s\n", got.c_str());
            g_failures++;
        }
    }
}

static void test_sha3_vs_eth_distinction(Vkeccak_top_tb* dut) {
    // Sanity: SHA3-256("") and Ethereum Keccak-256("") MUST differ. This
    // catches the canonical "domain byte 0x06 vs 0x01" footgun.
    std::printf("---- Test 3: SHA3-256 vs Ethereum-Keccak-256 distinction ----\n");
    const uint8_t empty[1] = {0};
    std::string sha3 = run_msg(dut, M_SHA3_256, empty, 0, 32, "sha3-empty");
    std::string eth  = run_msg(dut, M_ETH_K256, empty, 0, 32, "eth-empty");
    const char* sha3_exp = "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a";
    const char* eth_exp  = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
    if (sha3 == sha3_exp && eth == eth_exp && sha3 != eth) {
        std::printf("  [PASS] SHA3-256 != ETH-Keccak-256 on empty input (domain byte 0x06 vs 0x01)\n");
    } else {
        std::printf("  [FAIL] SHA3 vs ETH distinction broken\n");
        std::printf("         sha3 got %s exp %s\n", sha3.c_str(), sha3_exp);
        std::printf("         eth  got %s exp %s\n", eth.c_str(), eth_exp);
        g_failures++;
    }
}

static void test_random_vectors(Vkeccak_top_tb* dut) {
    std::printf("---- Test 4: Cross-validation against hashlib + pycryptodome (%zu random) ----\n",
                kRandomVectorCount);
    int passes = 0;
    int fails  = 0;
    int per_mode_ok[5] = {0, 0, 0, 0, 0};
    int per_mode_total[5] = {0, 0, 0, 0, 0};
    for (size_t i = 0; i < kRandomVectorCount; i++) {
        const RandomVec& v = kRandomVectors[i];
        per_mode_total[v.mode]++;
        std::string got = run_msg(dut, v.mode, v.msg, v.msg_len,
                                  static_cast<int>(v.digest_bytes), "random");
        if (got == v.digest_hex) {
            passes++;
            per_mode_ok[v.mode]++;
        } else {
            fails++;
            if (fails <= 3) {
                std::printf("  [FAIL] random #%zu mode=%s len=%zu\n",
                            i, mode_name(v.mode), v.msg_len);
                std::printf("         expected %s\n", v.digest_hex);
                std::printf("         got      %s\n", got.c_str());
            }
        }
    }
    for (int m = 0; m < 5; m++) {
        if (per_mode_total[m] > 0) {
            std::printf("  %s: %d / %d\n",
                        mode_name(m), per_mode_ok[m], per_mode_total[m]);
        }
    }
    std::printf("  random total: %d / %zu pass\n", passes, kRandomVectorCount);
    if (fails > 0) g_failures += fails;
}

static void test_back_to_back(Vkeccak_top_tb* dut) {
    std::printf("---- Test 5: Back-to-back hashing (different modes) ----\n");
    // SHA3-256("abc") then ETH-Keccak-256("abc") then SHA3-512("abc")
    const char* m = "abc";
    auto* msg = reinterpret_cast<const uint8_t*>(m);
    std::string g1 = run_msg(dut, M_SHA3_256, msg, 3, 32, "b2b sha3-256");
    std::string g2 = run_msg(dut, M_ETH_K256, msg, 3, 32, "b2b eth-k256");
    std::string g3 = run_msg(dut, M_SHA3_512, msg, 3, 64, "b2b sha3-512");
    bool ok = (g1 == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532")
           && (g2 == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
           && (g3 == "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0");
    if (ok) {
        std::printf("  [PASS] back-to-back across SHA3-256, ETH-Keccak-256, SHA3-512\n");
    } else {
        std::printf("  [FAIL] back-to-back\n");
        std::printf("         sha3-256: %s\n", g1.c_str());
        std::printf("         eth-k256: %s\n", g2.c_str());
        std::printf("         sha3-512: %s\n", g3.c_str());
        g_failures++;
    }
}

static void test_reset_mid_hash(Vkeccak_top_tb* dut) {
    std::printf("---- Test 6: Reset mid-hash, then re-hash cleanly ----\n");
    // Begin a long hash, then issue reset partway. After reset, run a known
    // "abc" SHA3-256 and verify.
    dut->mode_i  = M_SHA3_256;
    dut->start_i = 1;
    tick(dut);
    dut->start_i = 0;
    // feed a few words then reset
    for (int i = 0; i < 5; i++) {
        while (!dut->ready_o) tick(dut);
        dut->data_i  = 0xdeadbeefcafef00dULL;
        dut->valid_i = 1;
        dut->last_i  = 0;
        dut->last_bytes_i = 0;
        tick(dut);
        dut->valid_i = 0;
    }
    reset(dut);

    // Now run "abc"
    const char* m = "abc";
    std::string got = run_msg(dut, M_SHA3_256,
                              reinterpret_cast<const uint8_t*>(m), 3, 32,
                              "post-reset abc");
    const char* expected =
        "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
    if (got == expected) {
        std::printf("  [PASS] post-reset hash correct\n");
    } else {
        std::printf("  [FAIL] post-reset SHA3-256(\"abc\")\n");
        std::printf("         expected %s\n", expected);
        std::printf("         got      %s\n", got.c_str());
        g_failures++;
    }
}

// ---------------------------------------------------------------------------
// Functional coverage report
// ---------------------------------------------------------------------------
static void report_coverage(const Vkeccak_top_tb* dut) {
    auto* cov = dut->rootp->keccak_top_tb->u_cov;
    struct Bin { const char* name; uint8_t hit; };
    Bin bins[] = {
        {"mode_sha3_256",  cov->c_mode_sha3_256},
        {"mode_sha3_512",  cov->c_mode_sha3_512},
        {"mode_shake128",  cov->c_mode_shake128},
        {"mode_shake256",  cov->c_mode_shake256},
        {"mode_eth_k256",  cov->c_mode_eth_k256},
        {"single_block",   cov->c_single_block},
        {"multi_block",    cov->c_multi_block},
        {"back_to_back",   cov->c_back_to_back},
        {"reset_mid_hash", cov->c_reset_mid_hash},
        {"empty_message",  cov->c_empty_message},
    };
    int total = sizeof(bins) / sizeof(bins[0]);
    int hit = 0;
    std::printf("\n---- Functional coverage ----\n");
    for (int i = 0; i < total; i++) {
        std::printf("  [%s] %-15s\n", bins[i].hit ? "HIT " : "MISS",
                    bins[i].name);
        if (bins[i].hit) hit++;
    }
    std::printf("Coverage: %d/%d bins (%.1f%%)\n",
                hit, total, 100.0 * hit / total);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vkeccak_top_tb* dut = new Vkeccak_top_tb();
    reset(dut);

    test_fips_vectors(dut);
    test_eth_vectors(dut);
    test_sha3_vs_eth_distinction(dut);
    test_back_to_back(dut);
    test_reset_mid_hash(dut);
    test_random_vectors(dut);

    report_coverage(dut);

    if (g_failures == 0) {
        std::printf("+PASS all tests passed\n");
        delete dut;
        return 0;
    } else {
        std::printf("+FAIL %d failures\n", g_failures);
        delete dut;
        return 1;
    }
}
