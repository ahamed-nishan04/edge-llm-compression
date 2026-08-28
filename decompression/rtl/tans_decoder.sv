// =============================================================================
// tans_decoder.sv
// A real (not literal-passthrough) table-based ANS entropy decoder.
//
// Matches the construction in model/fse_codec.c exactly:
//   symbol  = table[state].symbol
//   nbBits  = table[state].nbBits
//   bits    = read nbBits bits, LSB-first within each byte, bytes in
//             increasing stream order
//   state   = table[state].newStateBase + bits
//
// Tile completion is tracked by a SYMBOL COUNT (num_symbols_this_tile),
// not by the compressed byte stream's own boundary -- with real variable
// bit-length entropy coding, the number of compressed BYTES consumed
// doesn't correspond 1:1 with the number of SYMBOLS decoded, so the old
// byte-stream-tile_last approach (fine for the literal-passthrough
// skeleton this replaces) is no longer valid. num_symbols_this_tile and
// init_state are per-tile metadata your encoder must transmit alongside
// the compressed bytes (e.g. in a small per-tile header the DMA/scheduler
// peels off before handing bytes here -- not modeled as a separate stage
// yet; this module takes them as direct inputs).
//
// Only literal/escape CLASSIFICATION lives outside this module now:
// tans_decoder emits raw decoded symbol values (0..maxSymbol, e.g. 0-255
// for literal bytes plus 256 for an LZ-match escape code in this design)
// and lz_reconstruct.sv is responsible for interpreting the sequence
// (detecting the escape code, gathering the following symbols as a match
// token). This mirrors how real compressors separate the entropy layer
// (generic symbol decode) from the LZ layer (sequence interpretation).
//
// Bit-reader notes (this is where bit-exactness against fse_codec.c
// actually lives):
//   * shreg holds the next un-consumed bits of the stream, LSB = the next
//     bit to be read.  A freshly arrived byte is OR-ed in at bit position
//     `bits_avail`, i.e. above whatever is already buffered, so the LSB of
//     each byte is consumed before its MSB and byte N is consumed before
//     byte N+1 -- exactly bw_put_bits()/br_get_bits() ordering.
//   * A byte is only accepted when there is guaranteed room for a whole
//     8 bits (bits_avail <= SHREG_W-8).  The old `bits_avail + 8 <=
//     SHREG_W` form overflowed the (narrow) bits_avail counter and let the
//     shift register silently wrap/corrupt itself once full.
//   * Bytes are only pulled while symbols still remain to be decoded, so
//     we never over-read into the following tile's compressed bytes.
// =============================================================================

module tans_decoder #(
    parameter int NUM_TILES     = 64,
    parameter int STATE_BITS    = 12,          // table has 2^STATE_BITS entries
    parameter int MAX_SYM_BITS  = 9,            // symbol alphabet up to 512 entries
    parameter int MAX_NB_BITS   = 16,
    parameter int MAX_SYMBOLS_PER_TILE = 4096
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,

    // Per-tile metadata (see header note above): loaded once before/at the
    // start of each tile's decode, held for the duration of that tile.
    input  logic                          tile_start,   // pulse: latch init_state/num_symbols, begin this tile
    input  logic [STATE_BITS-1:0]         init_state,
    input  logic [$clog2(MAX_SYMBOLS_PER_TILE+1)-1:0] num_symbols_this_tile,

    output logic [MAX_SYM_BITS-1:0] out_symbol,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_tile_last,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,

    // ---------------- Decode table load (host/software populated per tile
    // or per tile-class) ------------------------------------------------
    input  logic                         table_wr_en,
    input  logic [STATE_BITS-1:0]        table_wr_addr,
    input  logic [MAX_SYM_BITS-1:0]      table_wr_symbol,
    input  logic [$clog2(MAX_NB_BITS+1)-1:0] table_wr_nbbits,
    input  logic [STATE_BITS-1:0]        table_wr_newstate_base
);

    localparam int NB_BITS_W  = $clog2(MAX_NB_BITS+1);
    localparam int SYMCNT_W   = $clog2(MAX_SYMBOLS_PER_TILE+1);
    localparam int TILEID_W   = $clog2(NUM_TILES);

    // ---------------- Decode table (BRAM-inferred) ----------------
    typedef struct packed {
        logic [MAX_SYM_BITS-1:0]   symbol;
        logic [NB_BITS_W-1:0]      nb_bits;
        logic [STATE_BITS-1:0]     newstate_base;
    } tans_entry_t;

    tans_entry_t table_mem [0:(1<<STATE_BITS)-1];

    tans_entry_t table_wr_entry;
    always_comb begin
        table_wr_entry.symbol        = table_wr_symbol;
        table_wr_entry.nb_bits       = table_wr_nbbits;
        table_wr_entry.newstate_base = table_wr_newstate_base;
    end

    always_ff @(posedge clk) begin
        if (table_wr_en) begin
            table_mem[table_wr_addr] <= table_wr_entry;
        end
    end

    // ---------------- Bit reader ----------------
    localparam int SHREG_W   = 8 + MAX_NB_BITS;
    localparam int AVAIL_W   = $clog2(SHREG_W+1);
    localparam int AVAIL_MAX_ACCEPT = SHREG_W - 8;   // may accept a byte iff bits_avail <= this

    logic [SHREG_W-1:0]  shreg;
    logic [AVAIL_W-1:0]  bits_avail;

    logic [STATE_BITS-1:0] state_reg;

    tans_entry_t cur_entry;
    assign cur_entry = table_mem[state_reg];

    logic [NB_BITS_W-1:0] cur_nb_bits;
    assign cur_nb_bits = cur_entry.nb_bits;

    // Mask selecting exactly the low nb_bits of shreg (the bits this
    // symbol actually consumes) -- built via a variable-width shift/AND
    // rather than a variable part-select, which is not synthesizable.
    logic [MAX_NB_BITS-1:0] consumed_bits_mask;
    always_comb begin
        if (cur_nb_bits == '0)
            consumed_bits_mask = '0;
        else
            consumed_bits_mask =
                ({{(MAX_NB_BITS-1){1'b0}}, 1'b1} << cur_nb_bits) - {{(MAX_NB_BITS-1){1'b0}}, 1'b1};
    end

    logic [MAX_NB_BITS-1:0] consumed_value;
    assign consumed_value = shreg[MAX_NB_BITS-1:0] & consumed_bits_mask;

    // ---------------- FSM ----------------
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_LOOKUP = 3'd1,
        S_EMIT   = 3'd2
    } state_e;
    state_e st, st_n;

    logic [SYMCNT_W-1:0] sym_ctr;
    logic [SYMCNT_W-1:0] num_symbols_q;
    logic [TILEID_W-1:0] tile_id_q;

    logic bits_ready;        // enough buffered bits to resolve this symbol
    assign bits_ready = (bits_avail >= {{(AVAIL_W-NB_BITS_W){1'b0}}, cur_nb_bits});

    logic emit_fire;         // output handshake completes this cycle
    assign emit_fire = (st == S_EMIT) && out_valid && out_ready;

    logic lookup_fire;       // capture symbol / arm output this cycle
    assign lookup_fire = (st == S_LOOKUP) && bits_ready;

    logic last_symbol;
    assign last_symbol = ((sym_ctr + {{(SYMCNT_W-1){1'b0}}, 1'b1}) == num_symbols_q);

    // Pull a new compressed byte in whenever we have room for a whole byte
    // and there might still be more symbols to decode this tile (avoids
    // over-reading past the tile's actual compressed length into the next
    // tile's bytes).
    logic byte_fire;
    always_comb begin
        in_ready = (st != S_IDLE) &&
                   (sym_ctr < num_symbols_q) &&
                   (bits_avail <= AVAIL_MAX_ACCEPT[AVAIL_W-1:0]);
    end
    assign byte_fire = in_valid && in_ready;

    logic [SHREG_W-1:0] byte_ext;
    assign byte_ext = {{(SHREG_W-8){1'b0}}, in_byte};

    logic [AVAIL_W-1:0] nb_bits_ext;
    assign nb_bits_ext = {{(AVAIL_W-NB_BITS_W){1'b0}}, cur_nb_bits};

    // ---------------- Shift register / bit accounting ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shreg      <= '0;
            bits_avail <= '0;
        end else if ((st == S_IDLE) && tile_start) begin
            // Discard any leftover padding bits from the previous tile's
            // final (possibly not-byte-aligned) compressed byte -- each
            // tile's compressed stream starts at a fresh byte boundary,
            // so those leftover bits are not part of the new tile's data
            // and must not leak into its first symbol's lookup.
            shreg      <= '0;
            bits_avail <= '0;
        end else if (byte_fire && emit_fire) begin
            // simultaneous byte-in and bits-consumed this cycle
            shreg      <= (shreg >> nb_bits_ext) |
                          (byte_ext << (bits_avail - nb_bits_ext));
            bits_avail <= (bits_avail - nb_bits_ext) + AVAIL_W'(8);
        end else if (byte_fire) begin
            shreg      <= shreg | (byte_ext << bits_avail);
            bits_avail <= bits_avail + AVAIL_W'(8);
        end else if (emit_fire) begin
            shreg      <= shreg >> nb_bits_ext;
            bits_avail <= bits_avail - nb_bits_ext;
        end
    end

    // ---------------- FSM sequencing ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        case (st)
            S_IDLE  : begin
                if (tile_start && (num_symbols_this_tile != '0)) st_n = S_LOOKUP;
                else                                             st_n = S_IDLE;
            end
            S_LOOKUP: begin
                if (bits_ready) st_n = S_EMIT;
                else            st_n = S_LOOKUP;
            end
            S_EMIT  : begin
                if (out_valid && out_ready) begin
                    if (last_symbol) st_n = S_IDLE;
                    else             st_n = S_LOOKUP;
                end else begin
                    st_n = S_EMIT;
                end
            end
            default : st_n = S_IDLE;
        endcase
    end

    // ---------------- Datapath / outputs ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_reg     <= '0;
            sym_ctr       <= '0;
            num_symbols_q <= '0;
            tile_id_q     <= '0;
            out_symbol    <= '0;
            out_tile_id   <= '0;
            out_valid     <= 1'b0;
            out_tile_last <= 1'b0;
        end else begin
            // ---- per-tile metadata latch ----
            if ((st == S_IDLE) && tile_start) begin
                state_reg     <= init_state;
                sym_ctr       <= '0;
                num_symbols_q <= num_symbols_this_tile;
                tile_id_q     <= in_tile_id;
            end

            // ---- output register ----
            if (lookup_fire) begin
                out_symbol    <= cur_entry.symbol;
                out_tile_id   <= tile_id_q;
                out_tile_last <= last_symbol;
                out_valid     <= 1'b1;
            end else if (out_valid && out_ready) begin
                out_valid     <= 1'b0;
                out_tile_last <= 1'b0;
            end

            // ---- state advance: state = newStateBase + bits ----
            if (emit_fire) begin
                state_reg <= cur_entry.newstate_base +
                             consumed_value[STATE_BITS-1:0];
                sym_ctr   <= sym_ctr + {{(SYMCNT_W-1){1'b0}}, 1'b1};
            end
        end
    end

endmodule