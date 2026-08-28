/* =============================================================================
 * fse_codec.c
 * A real (not toy) table-based ANS entropy coder: genuine encode/decode
 * round trip, not a literal-passthrough placeholder.
 *
 * Simplification versus full Zstd/FSE (chosen deliberately, documented so
 * it's an informed choice, not a hidden shortcut): every symbol's
 * normalized frequency is constrained to be a power of 2. This is still
 * genuine tANS (the decode table has the same (symbol, nbBits, newState)
 * shape a real FSE decode table has, and RTL decodes it exactly the same
 * way), but it lets the table be built and inverted for encoding with a
 * simple closed form instead of FSE's "spread" placement algorithm --
 * much less code, much lower risk of a subtle construction bug, at the
 * cost of not hitting fractional-bit optimal compression ratios. Real
 * bring-up against actual zstd output would replace build_table() with
 * the standard spread-based FSE table construction; the DECODE side
 * (and the RTL) would not need to change at all, since it only consumes
 * the (symbol, nbBits, newState) table regardless of how it was built.
 *
 * Core algorithm (standard tANS, derived and re-verified here explicitly
 * because getting the direction/ordering wrong silently breaks
 * correctness):
 *
 *   DECODE (forward through the symbol sequence):
 *     state = initial_state (transmitted)
 *     for i in 0..n-1:
 *       symbol[i]  = table[state].symbol
 *       nbBits     = table[state].nbBits
 *       bits       = read_bits(nbBits)      // from the stream, forward
 *       state      = table[state].newStateBase + bits
 *
 *   Because state at step i depends on bits consumed at step i, and the
 *   SYMBOL at step i is a function of state BEFORE those bits are known,
 *   encoding must run backward (last symbol first) to be able to solve
 *   for the state/bits that make forward decode reproduce the original
 *   sequence. See encode() below.
 * ============================================================================= */

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
    int symbolValue[MAX_SYMBOLS];   // the actual byte/escape value, in table order
    int freq[MAX_SYMBOLS];          // power-of-2 frequency per symbol
    int base[MAX_SYMBOLS];          // cumulative-frequency base (start state) per symbol
    int tableLog;
    int tableSize;
    DTableEntry table[MAX_TABLE];   // decode table, index by state
} FseTable;

static int ilog2(int x) {
    int r = 0;
    while (x > 1) { x >>= 1; r++; }
    return r;
}

/* Build the decode table from a symbol/frequency spec. freq[] entries
 * MUST each be a power of 2, and MUST sum to exactly (1<<tableLog). */
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
        int k = ilog2(f);              // f == 2^k, by construction
        int nbBits = tableLog - k;
        for (int j = 0; j < f; j++) {
            int state = t->base[s] + j;
            t->table[state].symbol       = (uint16_t)t->symbolValue[s];
            t->table[state].nbBits       = (uint8_t)nbBits;
            t->table[state].newStateBase = (uint16_t)(j << nbBits);
        }
    }
}

/* ---------------- Bit writer / reader (LSB-first within each byte, bytes
 * in increasing stream order -- our own convention, chosen for simplicity
 * since we control both ends; must match tans_decoder.sv exactly). ---- */
typedef struct {
    uint8_t *buf;
    int      byteCap;
    int      bitPos;    // next bit to write, 0 = LSB of buf[0]
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

/* ---------------- Encode: symbols[0..n-1] (original, forward order) ----
 * Processed BACKWARD internally; emits (nbBits,bits) pairs also in
 * backward order, then reverses them so the final bitstream has step 0's
 * bits first (matching forward decode order). Returns the INITIAL state
 * the decoder should start from (transmit this alongside the stream),
 * and fills `out` / `*outBytes` with the compressed bitstream. */
int fse_encode(const FseTable *t, const int *symbols, int n,
               uint8_t *out, int outCap, int *outBytes) {
    /* Look up each symbol's table index (base) and freq/nbBits by value */
    int idxOf[1024];
    memset(idxOf, -1, sizeof(idxOf));
    for (int s = 0; s < t->nbSymbols; s++) idxOf[t->symbolValue[s]] = s;

    /* backward pass, recording (nbBits, bits) per step in i=n-1..0 order */
    int nbBitsArr[4096], bitsArr[4096];
    int state = 0; /* arbitrary seed; must match what decoder is told as
                       initial state only for the LAST computed value at
                       i=0, so this seed itself is never transmitted */
    for (int i = n - 1; i >= 0; i--) {
        int sym = symbols[i];
        int sIdx = idxOf[sym];
        assert(sIdx >= 0 && "symbol not in table");
        int f = t->freq[sIdx];
        int k = ilog2(f);
        int nbBits = t->tableLog - k;
        int j = state >> nbBits;          /* which occurrence of this symbol */
        int bits = state & ((1 << nbBits) - 1);
        assert(j < f && "encode state out of range for this symbol -- table/seed mismatch");
        int newState = t->base[sIdx] + j;  /* this becomes state_i */

        nbBitsArr[i] = nbBits;
        bitsArr[i]   = bits;
        state = newState;
    }
    int initialState = state; /* this is state_0, what decode must start at */

    BitWriter bw;
    bw_init(&bw, out, outCap);
    for (int i = 0; i < n; i++) {
        bw_put_bits(&bw, (uint32_t)bitsArr[i], nbBitsArr[i]);
    }
    *outBytes = bw_total_bytes(&bw);
    return initialState;
}

/* ---------------- Decode: forward, exactly matching tans_decoder.sv ---- */
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
    /* Symbol alphabet: 8 literal byte values used in the demo tile, plus
     * ESCAPE=256 marking the start of an LZ-match token. */
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

    /* Test sequence: 6 literals then an ESCAPE + 3-byte match token
     * (offset_hi=0x00, offset_lo=0x06, length=0x06), i.e. our 16-byte
     * tile's compressed token stream. */
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
