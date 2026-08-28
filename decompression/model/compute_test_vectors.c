#include "fse_codec.c"

int main(void) {
    int symbolValue[] = {0x00, 0x05, 0x06, 0x0A, 0x11, 0x22, 0xAA, 0xBB, 256};
    int freq[]         = {   1,    1,    1,    1,    1,    1,    1,    1,   8};
    int nbSymbols = 9, tableLog = 4;

    FseTable t;
    fse_build_table(&t, symbolValue, freq, nbSymbols, tableLog);

    int symbols[] = {0x05, 0xAA, 0xBB, 0x0A, 0x11, 0x22, 256, 0x00, 0x06, 0x06};
    int n = sizeof(symbols)/sizeof(symbols[0]);

    uint8_t compressed[64];
    int outBytes;
    int initState = fse_encode(&t, symbols, n, compressed, sizeof(compressed), &outBytes);

    printf("// ==== Verilog table_wr_* preload sequence ====\n");
    for (int s = 0; s < t.tableSize; s++) {
        printf("table_wr_addr=%2d table_wr_symbol=%3d table_wr_nbbits=%d table_wr_newstate_base=%2d\n",
            s, t.table[s].symbol, t.table[s].nbBits, t.table[s].newStateBase);
    }
    printf("\n// ==== compressed bytes (load into AXI memory model) ====\n");
    for (int i = 0; i < outBytes; i++) printf("byte[%d] = 0x%02x\n", i, compressed[i]);
    printf("\ninit_state = %d\n", initState);
    printf("num_symbols = %d\n", n);
    printf("total compressed bytes = %d\n", outBytes);

    int decoded[64];
    fse_decode(&t, compressed, initState, decoded, n);

    printf("\n// ==== decoded symbols ====\n");
    for (int i = 0; i < n; i++) printf("sym[%d] = 0x%03x\n", i, decoded[i]);

    uint8_t lz_out[64];
    int lz_len = 0;
    for (int i = 0; i < n; ) {
        if (decoded[i] == 256) {
            int off = (decoded[i+1] << 8) | decoded[i+2];
            int len = decoded[i+3];
            for (int k = 0; k < len; k++) {
                lz_out[lz_len] = lz_out[lz_len - off];
                lz_len++;
            }
            i += 4;
        } else {
            lz_out[lz_len++] = (uint8_t)decoded[i];
            i++;
        }
    }
    printf("\n// ==== LZ-reconstructed bytes (%d) ====\n", lz_len);
    for (int i = 0; i < lz_len; i++) printf("lz_out[%d] = 0x%02x\n", i, lz_out[i]);

    uint8_t ds_out[64];
    int ds_len = 0;
    for (int g = 0; g < lz_len; g += 3) {
        uint8_t idx = lz_out[g] & 0xF;
        uint8_t v0 = lz_out[g+1], v1 = lz_out[g+2];
        int seen = 0;
        for (int pos = 0; pos < 4; pos++) {
            if (idx & (1 << pos)) {
                ds_out[ds_len++] = (seen == 0) ? v0 : v1;
                seen++;
            } else {
                ds_out[ds_len++] = 0x00;
            }
        }
    }
    printf("\n// ==== Desparsed bytes (%d) ====\n", ds_len);
    for (int i = 0; i < ds_len; i++) printf("ds_out[%d] = 0x%02x\n", i, ds_out[i]);

    printf("\n// ==== Dequantized (INT8, scale=1, zero=0) - expect == ds_out ====\n");
    for (int i = 0; i < ds_len; i++) printf("out[%d] = %d (0x%02x)\n", i, ds_out[i], ds_out[i]);

    return 0;
}
