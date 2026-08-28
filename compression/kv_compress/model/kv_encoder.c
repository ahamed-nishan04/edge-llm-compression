/* =============================================================================
 * kv_encoder.c
 * Golden reference for the REAL-TIME KV-cache compressor.
 *
 * Mirrors the decompression pipeline's stages in reverse:
 *   decompress: entropy_decode -> LZ_reconstruct -> desparse -> dequant
 *   compress:   quantize -> (sparsify, bypassed for KV -- see note)      -> LZ77_match -> entropy_encode
 *
 * Why quantize-only, no sparsify: the decompression README already treats
 * KV-cache tiles as dense (desparse bypassed) -- this mirrors that. If a
 * later revision prunes KV entries too, add a sparsify() stage here
 * producing the same {idx,v0,v1} triples desparse_unit.sv expects, and
 * flip desparse_en at decode time for KV tiles.
 *
 * WHY THIS IS A BATCH (BUFFER-THEN-ENCODE) DESIGN, NOT STREAMING:
 * tANS/FSE encoding is inherently a BACKWARD pass over the symbol
 * sequence -- the state chain is computed last-symbol-first, then the
 * bitstream is emitted in the resulting reversed order (see fse_codec.c's
 * header comment for the full derivation). There is no way to emit
 * compressed bits for symbol i without already knowing the encode state
 * that resulted from processing symbols i+1..n-1. So a real-time
 * "compress as tokens arrive" design is not possible for this entropy
 * stage; the achievable real-time design is: finish the K/V tile in SRAM
 * (already required anyway -- attention needs the whole tile written
 * before it's read back), LZ-match it, then run ONE backward encode pass
 * over the resulting token sequence. Latency budget for that backward
 * pass is TILE_SIZE_BYTES cycles-ish in hardware (one state-transition
 * per token, table-driven, same cost class as the decoder) -- see
 * rtl/tans_encoder.sv for the hardware version of this same batch design.
 * ============================================================================= */

#include "fse_codec.c"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#define ESCAPE_SYMBOL 256
#define MIN_MATCH_LEN 4
#define MAX_TILE_BYTES 4096

/* ---------------- Stage 1: quantize (INT8, uniform scale/zero) -------- */
static int quantize_int8(const float *raw, int n, float scale, int8_t zero,
                          uint8_t *out) {
    for (int i = 0; i < n; i++) {
        int q = (int)roundf(raw[i] / scale) + zero;
        if (q < 0) q = 0;
        if (q > 255) q = 255;
        out[i] = (uint8_t)q;
    }
    return n;
}

/* ---------------- Stage 2: greedy LZ77 match finder -------------------
 * Exhaustive O(n^2) search -- fine for reference-model / small-tile use;
 * a real-time hardware match finder would use a hash table over
 * MIN_MATCH_LEN-byte windows (see rtl/lz_match_finder.sv) to make this
 * O(n) at the cost of missing some matches a full search would find. */
static int lz77_match(const uint8_t *data, int n,
                       const uint8_t *dict, int dictLen,
                       int *tokens, int *tokenLen) {
    int tc = 0;
    int i = 0;
    while (i < n) {
        int bestLen = 0, bestOff = 0;

        /* search in-tile history [0, i) */
        for (int j = 0; j < i; j++) {
            int len = 0;
            while (i + len < n && data[j + len] == data[i + len] && len < 255) len++;
            if (len > bestLen) { bestLen = len; bestOff = i - j; }
        }
        /* search dictionary (addressed as offset >= n, matching the
         * decoder's convention: dict_addr = offset - TILE_SIZE_BYTES) */
        for (int j = 0; j < dictLen; j++) {
            int len = 0;
            while (i + len < n && dict[j + len] == data[i + len] && len < 255) len++;
            if (len > bestLen) { bestLen = len; bestOff = n - j; /* offset >= n */ }
        }

        if (bestLen >= MIN_MATCH_LEN) {
            tokens[tc++] = ESCAPE_SYMBOL;
            tokens[tc++] = (bestOff >> 8) & 0xFF;
            tokens[tc++] = bestOff & 0xFF;
            tokens[tc++] = bestLen;
            i += bestLen;
        } else {
            tokens[tc++] = data[i];
            i += 1;
        }
    }
    *tokenLen = tc;
    return tc;
}

/* ---------------- Stage 3: power-of-2 frequency table construction ----
 * See header derivation: tableLog = ceil(log2(nbSymbols)); remaining =
 * (1<<tableLog) - nbSymbols is ALWAYS < nbSymbols, so giving the
 * `remaining` most-frequent symbols freq=2 (everyone else freq=1) always
 * sums EXACTLY to tableSize in one pass -- simple, always terminates,
 * always exact. Real Zstd's FSE gets more compression via a finer
 * (non-power-of-2-per-symbol) allocation; this is the deliberately
 * simplified version documented in fse_codec.c's header. */
static int build_freq_table(const int *tokens, int tokenLen,
                             int *symbolValue, int *freq, int *nbSymbolsOut) {
    int count[512]; memset(count, 0, sizeof(count));
    int seen[512]; memset(seen, 0, sizeof(seen));
    for (int i = 0; i < tokenLen; i++) count[tokens[i]]++;

    int nbSymbols = 0;
    int symList[512], cntList[512];
    for (int s = 0; s < 512; s++) {
        if (count[s] > 0) {
            symList[nbSymbols] = s;
            cntList[nbSymbols] = count[s];
            nbSymbols++;
        }
    }

    int tableLog = 0;
    while ((1 << tableLog) < nbSymbols) tableLog++;
    if (tableLog == 0) tableLog = 1; /* need at least 2 states even for 1 symbol */
    int tableSize = 1 << tableLog;
    int remaining = tableSize - nbSymbols;

    /* sort symList/cntList by cntList descending (simple insertion sort,
     * nbSymbols is small for a per-tile alphabet) */
    for (int a = 1; a < nbSymbols; a++) {
        int cs = symList[a], cc = cntList[a];
        int b = a - 1;
        while (b >= 0 && cntList[b] < cc) {
            symList[b+1] = symList[b]; cntList[b+1] = cntList[b]; b--;
        }
        symList[b+1] = cs; cntList[b+1] = cc;
    }

    for (int s = 0; s < nbSymbols; s++) {
        symbolValue[s] = symList[s];
        freq[s] = (s < remaining) ? 2 : 1;
    }
    *nbSymbolsOut = nbSymbols;
    return tableLog;
}

/* ---------------- Full pipeline: quantize -> LZ77 -> FSE encode ------- */
typedef struct {
    uint8_t compressed[MAX_TILE_BYTES * 2];
    int compressedBytes;
    int initState;
    FseTable table;
    int tokens[MAX_TILE_BYTES * 4];
    int tokenLen;
} KvCompressedTile;

int kv_compress_tile(const float *raw, int n, float scale, int8_t zero,
                      const uint8_t *dict, int dictLen,
                      KvCompressedTile *out) {
    uint8_t quantized[MAX_TILE_BYTES];
    quantize_int8(raw, n, scale, zero, quantized);

    lz77_match(quantized, n, dict, dictLen, out->tokens, &out->tokenLen);

    int symbolValue[512], freq[512], nbSymbols;
    int tableLog = build_freq_table(out->tokens, out->tokenLen,
                                     symbolValue, freq, &nbSymbols);
    fse_build_table(&out->table, symbolValue, freq, nbSymbols, tableLog);

    out->initState = fse_encode(&out->table, out->tokens, out->tokenLen,
                                 out->compressed, sizeof(out->compressed),
                                 &out->compressedBytes);
    return out->compressedBytes;
}

#ifdef KV_ENCODER_SELFTEST
/* Round-trip self-test: encode a synthetic KV tile, decode it back
 * (entropy decode -> LZ reconstruct, mirroring the RTL/decompress side
 * exactly), and verify we recover the original quantized bytes. */
static int lz_reconstruct_ref(const int *tokens, int n, const uint8_t *dict,
                               int dictLen, uint8_t *out) {
    int op = 0;
    for (int i = 0; i < n; ) {
        if (tokens[i] == ESCAPE_SYMBOL) {
            int off = (tokens[i+1] << 8) | tokens[i+2];
            int len = tokens[i+3];
            for (int k = 0; k < len; k++) {
                out[op] = (off >= op + 1 && (op - off) < 0)
                          ? dict[dictLen - (off - op)]   /* dictionary ref */
                          : out[op - off];
                op++;
            }
            i += 4;
        } else {
            out[op++] = (uint8_t)tokens[i++];
        }
    }
    return op;
}

int main(void) {
    /* Synthetic KV tile: 16 fp32 values with a repeating pattern so the
     * LZ matcher has something real to find. */
    float raw[16] = {
        1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f,
        1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f,   /* repeats [0..5] -- real match */
        7.0f, 8.0f, 9.0f, 10.0f
    };
    int n = 16;
    float scale = 1.0f; int8_t zero = 0;
    uint8_t dict[8] = {0,0,0,0,0,0,0,0}; /* empty/unused dictionary for this test */

    KvCompressedTile out;
    int compBytes = kv_compress_tile(raw, n, scale, zero, dict, 0, &out);

    printf("Quantized+LZ token count: %d, compressed to %d bytes (init_state=%d)\n",
           out.tokenLen, compBytes, out.initState);
    printf("Tokens: ");
    for (int i = 0; i < out.tokenLen; i++) printf("%d ", out.tokens[i]);
    printf("\n");

    int decodedTokens[256];
    fse_decode(&out.table, out.compressed, out.initState, decodedTokens, out.tokenLen);

    int tokMatch = 1;
    for (int i = 0; i < out.tokenLen; i++)
        if (decodedTokens[i] != out.tokens[i]) tokMatch = 0;
    printf("Token-level round trip: %s\n", tokMatch ? "PASS" : "FAIL");

    uint8_t reconstructed[64];
    int reLen = lz_reconstruct_ref(decodedTokens, out.tokenLen, dict, 0, reconstructed);

    uint8_t expectedQuantized[16];
    quantize_int8(raw, n, scale, zero, expectedQuantized);

    int byteMatch = (reLen == n);
    for (int i = 0; byteMatch && i < n; i++)
        if (reconstructed[i] != expectedQuantized[i]) byteMatch = 0;

    printf("Byte-level round trip (%d bytes): %s\n", reLen, byteMatch ? "PASS" : "FAIL");
    if (!byteMatch) {
        printf("  expected: "); for (int i=0;i<n;i++) printf("%02x ", expectedQuantized[i]); printf("\n");
        printf("  got:      "); for (int i=0;i<reLen;i++) printf("%02x ", reconstructed[i]); printf("\n");
    }

    return (tokMatch && byteMatch) ? 0 : 1;
}
#endif

#ifdef KV_GEN_VECTORS
/* Emit golden vectors in a machine-parseable form for gen_kv_stimulus.py.
 * Same tile as the self-test, so the two stay in step. */
int main(void) {
    float raw[16] = {
        1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f,
        1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f,
        7.0f, 8.0f, 9.0f, 10.0f
    };
    int n = 16;
    float scale = 1.0f; int8_t zero = 0;
    uint8_t dict[8] = {0,0,0,0,0,0,0,0};

    uint8_t quantized[MAX_TILE_BYTES];
    quantize_int8(raw, n, scale, zero, quantized);

    KvCompressedTile out;
    kv_compress_tile(raw, n, scale, zero, dict, 0, &out);

    for (int i = 0; i < n; i++) printf("raw[%d] = %d\n", i, (int)raw[i]);
    for (int i = 0; i < n; i++) printf("quant[%d] = 0x%02x\n", i, quantized[i]);
    for (int i = 0; i < out.tokenLen; i++) printf("token[%d] = %d\n", i, out.tokens[i]);
    for (int i = 0; i < out.compressedBytes; i++)
        printf("comp[%d] = 0x%02x\n", i, out.compressed[i]);

    printf("num_raw = %d\n", n);
    printf("num_tokens = %d\n", out.tokenLen);
    printf("num_comp_bytes = %d\n", out.compressedBytes);
    printf("init_state = %d\n", out.initState);
    printf("quant_scale_q88 = %d\n", (int)(scale * 256.0f));
    printf("quant_zero = %d\n", (int)zero);
    return 0;
}
#endif
