
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define MAX_SYMBOLS 512
#define MAX_TABLE   4096

typedef struct {
    uint16_t symbol;
    uint8_t  nbBits;
    uint16_t newStateBase;
} DTableEntry;

typedef struct {
    int nbSymbols;
    int symbolValue[MAX_SYMBOLS];
    int freq[MAX_SYMBOLS];
    int base[MAX_SYMBOLS];
    int tableLog;
    int tableSize;
    DTableEntry table[MAX_TABLE];
} FseTable;

static int ilog2(int x) {
    int r = 0;
    while (x > 1) { x >>= 1; r++; }
    return r;
}

void fse_build_table(FseTable *t, const int *symbolValue, const int *freq,
                      int nbSymbols, int tableLog) {
    t->nbSymbols = nbSymbols;
    t->tableLog  = tableLog;
    t->tableSize = 1 << tableLog;

    int sum = 0;
    int base = 0;
    for (int s = 0; s < nbSymbols; s++) {
        t->symbolValue[s] = symbolValue[s];
        t->freq[s] = freq[s];
        t->base[s] = base;
        base += freq[s];
        sum += freq[s];
    }
    assert(sum == t->tableSize && "frequencies must sum exactly to tableSize");

    for (int s = 0; s < nbSymbols; s++) {
        int f = t->freq[s];
        int k = ilog2(f);
        int nbBits = tableLog - k;
        for (int j = 0; j < f; j++) {
            int state = t->base[s] + j;
            t->table[state].symbol       = (uint16_t)t->symbolValue[s];
            t->table[state].nbBits       = (uint8_t)nbBits;
            t->table[state].newStateBase = (uint16_t)(j << nbBits);
        }
    }
}

typedef struct {
    uint8_t *buf;
    int      byteCap;
    int      bitPos;
} BitWriter;

static void bw_init(BitWriter *bw, uint8_t *buf, int byteCap) {
    bw->buf = buf; bw->byteCap = byteCap; bw->bitPos = 0;
    memset(buf, 0, byteCap);
}
static void bw_put_bits(BitWriter *bw, uint32_t value, int nbBits) {
    for (int i = 0; i < nbBits; i++) {
        int bit = (value >> i) & 1;
        int byteIdx = bw->bitPos >> 3;
        int bitIdx  = bw->bitPos & 7;
        assert(byteIdx < bw->byteCap);
        bw->buf[byteIdx] |= (bit << bitIdx);
        bw->bitPos++;
    }
}
static int bw_total_bytes(BitWriter *bw) {
    return (bw->bitPos + 7) / 8;
}

typedef struct {
    const uint8_t *buf;
    int bitPos;
} BitReader;

static void br_init(BitReader *br, const uint8_t *buf) {
    br->buf = buf; br->bitPos = 0;
}
static uint32_t br_get_bits(BitReader *br, int nbBits) {
    uint32_t v = 0;
    for (int i = 0; i < nbBits; i++) {
        int byteIdx = br->bitPos >> 3;
        int bitIdx  = br->bitPos & 7;
        int bit = (br->buf[byteIdx] >> bitIdx) & 1;
        v |= (bit << i);
        br->bitPos++;
    }
    return v;
}

int fse_encode(const FseTable *t, const int *symbols, int n,
               uint8_t *out, int outCap, int *outBytes) {

    int idxOf[1024];
    memset(idxOf, -1, sizeof(idxOf));
    for (int s = 0; s < t->nbSymbols; s++) idxOf[t->symbolValue[s]] = s;

    int nbBitsArr[4096], bitsArr[4096];
    int state = 0;
    for (int i = n - 1; i >= 0; i--) {
        int sym = symbols[i];
        int sIdx = idxOf[sym];
        assert(sIdx >= 0 && "symbol not in table");
        int f = t->freq[sIdx];
        int k = ilog2(f);
        int nbBits = t->tableLog - k;
        int j = state >> nbBits;
        int bits = state & ((1 << nbBits) - 1);
        assert(j < f && "encode state out of range for this symbol -- table/seed mismatch");
        int newState = t->base[sIdx] + j;

        nbBitsArr[i] = nbBits;
        bitsArr[i]   = bits;
        state = newState;
    }
    int initialState = state;

    BitWriter bw;
    bw_init(&bw, out, outCap);
    for (int i = 0; i < n; i++) {
        bw_put_bits(&bw, (uint32_t)bitsArr[i], nbBitsArr[i]);
    }
    *outBytes = bw_total_bytes(&bw);
    return initialState;
}

void fse_decode(const FseTable *t, const uint8_t *in, int initialState,
                 int *symbolsOut, int n) {
    BitReader br;
    br_init(&br, in);
    int state = initialState;
    for (int i = 0; i < n; i++) {
        int sym    = t->table[state].symbol;
        int nbBits = t->table[state].nbBits;
        uint32_t bits = br_get_bits(&br, nbBits);
        symbolsOut[i] = sym;
        state = t->table[state].newStateBase + bits;
    }
}

#ifdef FSE_CODEC_SELFTEST
int main(void) {

    int symbolValue[] = {0x00, 0x05, 0x06, 0x0A, 0x11, 0x22, 0xAA, 0xBB, 256};
    int freq[]         = {   1,    1,    1,    1,    1,    1,    1,    1,   8};
    int nbSymbols = 9, tableLog = 4;

    FseTable t;
    fse_build_table(&t, symbolValue, freq, nbSymbols, tableLog);

    printf("Decode table (state: symbol nbBits newStateBase):\n");
    for (int s = 0; s < t.tableSize; s++) {
        printf("  %2d: sym=0x%03x nbBits=%d newStateBase=%d\n",
               s, t.table[s].symbol, t.table[s].nbBits, t.table[s].newStateBase);
    }

    int symbols[] = {0x05, 0xAA, 0xBB, 0x0A, 0x11, 0x22, 256, 0x00, 0x06, 0x06};
    int n = sizeof(symbols)/sizeof(symbols[0]);

    uint8_t compressed[64];
    int outBytes;
    int initState = fse_encode(&t, symbols, n, compressed, sizeof(compressed), &outBytes);

    printf("\nEncoded %d symbols into %d bytes, initial_state=%d\n", n, outBytes, initState);
    printf("Compressed bytes: ");
    for (int i = 0; i < outBytes; i++) printf("%02x ", compressed[i]);
    printf("\n");

    int decoded[64];
    fse_decode(&t, compressed, initState, decoded, n);

    int ok = 1;
    printf("\nRound-trip check:\n");
    for (int i = 0; i < n; i++) {
        int match = (decoded[i] == symbols[i]);
        if (!match) ok = 0;
        printf("  [%d] expected=0x%03x decoded=0x%03x %s\n",
               i, symbols[i], decoded[i], match ? "OK" : "MISMATCH");
    }
    printf("\n%s\n", ok ? "ROUND TRIP PASS" : "ROUND TRIP FAIL");
    return ok ? 0 : 1;
}
#endif
