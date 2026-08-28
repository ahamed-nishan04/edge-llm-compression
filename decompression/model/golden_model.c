/* =============================================================================
 * golden_model.c
 * Bit-exact-ish C reference for the decompression pipeline stages, used to:
 *   1. Generate known-good (compressed_in, decompressed_out) test vectors
 *      for the RTL testbench.
 *   2. Sanity check each stage's algorithm independent of RTL timing.
 *
 * This is a FUNCTIONAL model (simplified LZ77 + a toy range/table entropy
 * stage), NOT a bit-exact Zstd/tANS implementation -- for real bring-up you
 * should instead point the testbench at actual `zstd --ultra -22` output
 * decoded with a reference tANS decoder (e.g. adapt FiniteStateEntropy from
 * the Zstd repo) so RTL is verified against the real format, not a stand-in.
 * This file exists to unblock RTL structural testing before that's wired up.
 *
 * Stages modeled, matching the RTL pipeline order:
 *   entropy_decode_toy() -> lz_reconstruct() -> desparse_2_4() -> dequant()
 * ============================================================================= */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define TILE_SIZE_BYTES   4096
#define DICT_DEPTH_BYTES  32768
#define GROUP_SIZE        128

typedef enum { QUANT_INT8 = 0, QUANT_NF4 = 1, QUANT_AWQ_INT4 = 2 } quant_mode_t;

/* ---- Toy entropy stage: literal-only passthrough (placeholder for tANS) ---- */
static void entropy_decode_toy(const uint8_t *comp, int comp_len,
                                uint8_t *literals, int *lit_len) {
    memcpy(literals, comp, comp_len);
    *lit_len = comp_len;
}

/* ---- LZ77 reconstruction: token stream (0x00 len offset_hi offset_lo = match,
 *      else literal byte) against dictionary + in-tile history ---- */
static int lz_reconstruct(const uint8_t *tokens, int tok_len,
                           const uint8_t *dict, int dict_len,
                           uint8_t *out) {
    int op = 0;
    for (int i = 0; i < tok_len; ) {
        if (tokens[i] == 0x00 && i + 3 < tok_len) {
            uint8_t len = tokens[i+1];
            uint16_t offset = (tokens[i+2] << 8) | tokens[i+3];
            for (int k = 0; k < len; k++) {
                uint8_t b;
                if (offset >= TILE_SIZE_BYTES) {
                    int daddr = offset - TILE_SIZE_BYTES;
                    b = (daddr < dict_len) ? dict[daddr] : 0;
                } else {
                    int haddr = op - offset;
                    b = (haddr >= 0) ? out[haddr] : 0;
                }
                out[op++] = b;
            }
            i += 4;
        } else {
            out[op++] = tokens[i++];
        }
    }
    return op;
}

/* ---- 2:4 structured sparsity expansion: 4-bit idx + 2 nonzero bytes per group ---- */
static int desparse_2_4(const uint8_t *in, int in_len, uint8_t *out) {
    int op = 0, ip = 0;
    while (ip + 2 < in_len) {
        uint8_t idx = in[ip] & 0x0F;
        uint8_t v0 = in[ip+1], v1 = in[ip+2];
        ip += 3;
        int seen = 0;
        for (int pos = 0; pos < 4; pos++) {
            if (idx & (1 << pos)) {
                out[op++] = (seen == 0) ? v0 : v1;
                seen++;
            } else {
                out[op++] = 0x00;
            }
        }
    }
    return op;
}

/* ---- Dequantize: INT8 affine / NF4 LUT / AWQ-INT4 affine ---- */
static const float nf4_lut[16] = {
    -1.0f, -0.6962f, -0.5251f, -0.3949f, -0.2844f, -0.1848f, -0.0911f, -0.0f,
     0.0f,  0.0796f,  0.1610f,  0.2461f,  0.3379f,  0.4407f,  0.5626f,  0.7230f
};

static int dequant(const uint8_t *in, int in_len, quant_mode_t mode,
                    const float *scale, const int8_t *zero, float *out) {
    int op = 0;
    for (int i = 0; i < in_len; i++) {
        int group = i / GROUP_SIZE;
        float s = scale[group];
        int8_t z = zero[group];
        if (mode == QUANT_INT8) {
            out[op++] = ((int)in[i] - z) * s;
        } else if (mode == QUANT_NF4) {
            out[op++] = nf4_lut[(in[i] >> 4) & 0xF] * s;
            out[op++] = nf4_lut[in[i] & 0xF] * s;
        } else { /* AWQ_INT4 */
            out[op++] = (((in[i] >> 4) & 0xF) - z) * s;
            out[op++] = ((in[i] & 0xF) - z) * s;
        }
    }
    return op;
}

/* ---- End-to-end pipeline, mirrors RTL stage order ---- */
int decompress_tile(const uint8_t *comp, int comp_len,
                     const uint8_t *dict, int dict_len,
                     int desparse_en, quant_mode_t mode,
                     const float *scale, const int8_t *zero,
                     float *out) {
    static uint8_t lit_buf[TILE_SIZE_BYTES * 4];
    static uint8_t lz_buf[TILE_SIZE_BYTES];
    static uint8_t ds_buf[TILE_SIZE_BYTES];
    int lit_len;

    entropy_decode_toy(comp, comp_len, lit_buf, &lit_len);
    int lz_len = lz_reconstruct(lit_buf, lit_len, dict, dict_len, lz_buf);

    int ds_len;
    if (desparse_en) {
        ds_len = desparse_2_4(lz_buf, lz_len, ds_buf);
    } else {
        memcpy(ds_buf, lz_buf, lz_len);
        ds_len = lz_len;
    }

    return dequant(ds_buf, ds_len, mode, scale, zero, out);
}

#ifdef GOLDEN_MODEL_MAIN
int main(void) {
    /* Minimal smoke test: literal-only tile, no LZ matches, INT8 dequant */
    uint8_t comp[16];
    for (int i = 0; i < 16; i++) comp[i] = i * 4;
    float scale[TILE_SIZE_BYTES / GROUP_SIZE];
    int8_t zero[TILE_SIZE_BYTES / GROUP_SIZE];
    for (int g = 0; g < TILE_SIZE_BYTES / GROUP_SIZE; g++) { scale[g] = 0.5f; zero[g] = 0; }

    float out[64];
    int n = decompress_tile(comp, 16, NULL, 0, 0, QUANT_INT8, scale, zero, out);
    printf("decoded %d elements:\n", n);
    for (int i = 0; i < n; i++) printf("%.2f ", out[i]);
    printf("\n");
    return 0;
}
#endif
