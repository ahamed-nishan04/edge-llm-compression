// =============================================================================
// lz_reconstruct.sv
// Consumes the RAW decoded symbol stream from tans_decoder (values 0..255
// are literal bytes, ESCAPE_SYMBOL=256 begins a match token) and
// reconstructs the tile byte stream. This module owns the LZ sequence
// interpretation (detecting the escape code, gathering the following
// symbols as a match token's offset/length fields) -- the entropy stage
// is a generic symbol decoder and doesn't know about LZ semantics.
//
// Match token format (3 symbols immediately following ESCAPE_SYMBOL, each
// decoded through the SAME entropy table as literals -- i.e. offset/length
// bytes are entropy-coded too, not raw/unencoded):
//   symbol[i+1] = offset_hi (bits [15:8] of the match offset)
//   symbol[i+2] = offset_lo (bits [7:0] of the match offset)
//   symbol[i+3] = length (number of bytes to copy)
//
// Matches can reference:
//   (a) bytes already emitted earlier in THIS tile (history window), or
//   (b) the preloaded role-specific dictionary (dict_rd_*) for cross-tile
//       redundancy.
// Offset addressing: offset < TILE_SIZE_BYTES -> in-tile history;
//                     offset >= TILE_SIZE_BYTES -> dictionary
//                     (dict_addr = offset - TILE_SIZE_BYTES).
// =============================================================================

module lz_reconstruct #(
    parameter int TILE_SIZE_BYTES  = 4096,
    parameter int NUM_TILES        = 64,
    parameter int DICT_DEPTH_BYTES = 32768,
    parameter int ESCAPE_SYMBOL    = 256
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [8:0]  in_symbol,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_tile_last,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,

    output logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_rd_addr,
    input  logic [7:0]                          dict_rd_data,
    output logic                                dict_rd_en,

    output logic [7:0]  out_data,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_tile_last,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,
    output logic [$clog2(TILE_SIZE_BYTES)-1:0] out_tile_offset
);

    localparam int TILE_ADDR_W = $clog2(TILE_SIZE_BYTES);

    // In-tile history buffer: every byte emitted this tile also gets
    // written here so later matches within the same tile can copy from it.
    logic [7:0] history [0:TILE_SIZE_BYTES-1];
    logic [TILE_ADDR_W-1:0] wr_ptr;

    typedef enum logic [2:0] {
        S_IDLE, S_GET_OFF_HI, S_GET_OFF_LO, S_GET_LEN, S_LITERAL, S_COPY
    } state_e;
    state_e st, st_n;

    logic [15:0] copy_offset_q;
    logic [7:0]  copy_len_q;
    logic [7:0]  off_hi_q;
    logic [$clog2(NUM_TILES)-1:0] tile_id_q;
    logic tile_last_q; // latched at the cycle each symbol is accepted, not
                        // read live off the input -- see note in
                        // out_tile_last assignment below

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_IDLE: if (in_valid) begin
                        if (in_symbol == ESCAPE_SYMBOL[8:0]) st_n = S_GET_OFF_HI;
                        else                                  st_n = S_LITERAL;
                    end
            S_GET_OFF_HI: if (in_valid) st_n = S_GET_OFF_LO;
            S_GET_OFF_LO: if (in_valid) st_n = S_GET_LEN;
            S_GET_LEN:    if (in_valid) st_n = S_COPY;
            S_LITERAL: if (out_valid && out_ready) st_n = S_IDLE;
            S_COPY:    if (out_valid && out_ready && copy_len_q == 8'd1) st_n = S_IDLE;
            default: st_n = S_IDLE;
        endcase
    end

    // Accept a new input symbol in any of the "gathering" states, plus
    // S_IDLE itself.
    assign in_ready = (st == S_IDLE) || (st == S_GET_OFF_HI) ||
                       (st == S_GET_OFF_LO) || (st == S_GET_LEN);

    // Address mux: in-tile history vs dictionary, per the offset convention above
    logic use_dict;
    logic [TILE_ADDR_W-1:0] copy_src_addr;      // explicit read pointer for the
                                                  // copy source, decoupled from
                                                  // wr_ptr so its own advance
                                                  // timing can't create the
                                                  // stale-read bug described
                                                  // below
    logic [TILE_ADDR_W-1:0] copy_src_addr_next;
    assign use_dict            = (copy_offset_q >= TILE_SIZE_BYTES);
    assign copy_src_addr_next  = copy_src_addr + 1;
    assign dict_rd_addr = use_dict ? (copy_src_addr - TILE_SIZE_BYTES) : '0;
    assign dict_rd_en   = (st == S_COPY) && use_dict;
    // KNOWN LATENT ISSUE, not exercised by the current in-tile-only test:
    // dict_mem's real read port is REGISTERED (1-cycle latency), but the
    // S_COPY logic below reads dict_rd_data the SAME cycle it drives
    // dict_rd_addr, i.e. one cycle too early for a real dictionary-
    // crossing match. Needs a pipeline stage (or an explicit wait cycle)
    // before this is correct for offset >= TILE_SIZE_BYTES.

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr        <= '0;
            out_valid     <= 1'b0;
            copy_len_q    <= '0;
            copy_offset_q <= '0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (in_valid && in_symbol != ESCAPE_SYMBOL[8:0]) begin
                        out_data    <= in_symbol[7:0];
                        out_valid   <= 1'b1;
                        tile_id_q   <= in_tile_id;
                        tile_last_q <= in_tile_last;
                    end else if (in_valid) begin
                        // ESCAPE seen -- this symbol's own tile_last (if
                        // it were somehow the tile's last symbol, which
                        // shouldn't happen for a well-formed stream since
                        // a match token always has 3 more symbols after
                        // it) is not meaningful here; the REAL tile_last
                        // for this match arrives with the LENGTH symbol.
                        out_valid <= 1'b0;
                    end
                end

                S_GET_OFF_HI: if (in_valid) begin
                    off_hi_q <= in_symbol[7:0];
                end

                S_GET_OFF_LO: if (in_valid) begin
                    copy_offset_q <= {off_hi_q, in_symbol[7:0]};
                end

                S_GET_LEN: if (in_valid) begin
                    copy_len_q  <= in_symbol[7:0];
                    tile_id_q   <= in_tile_id;
                    tile_last_q <= in_tile_last; // the LENGTH symbol carries
                                                   // the token's true tile_last
                    // Initialize the copy source pointer here, using the
                    // CURRENT wr_ptr (unchanged since we've only been
                    // gathering the token's fields, not writing bytes) and
                    // the offset latched at S_GET_OFF_LO.
                    copy_src_addr <= wr_ptr - copy_offset_q[TILE_ADDR_W-1:0];
                end

                S_LITERAL: begin
                    if (out_valid && out_ready) begin
                        history[wr_ptr] <= out_data;
                        wr_ptr          <= wr_ptr + 1;
                        out_valid       <= 1'b0;
                    end
                end

                S_COPY: begin
                    if (!out_valid || out_ready) begin
                        if (out_valid && out_ready) begin
                            // A byte was just consumed: commit it to history,
                            // advance wr_ptr AND the copy source pointer
                            // together, then fetch the NEXT source byte using
                            // the ALREADY-ADVANCED address -- not wr_ptr's
                            // pre-increment value, which is what caused this
                            // stage to silently re-emit the same byte twice
                            // instead of advancing through the match.
                            history[wr_ptr] <= out_data;
                            wr_ptr           <= wr_ptr + 1;
                            copy_src_addr    <= copy_src_addr_next;
                            copy_len_q       <= copy_len_q - 1;
                            if (copy_len_q == 8'd1) begin
                                out_valid <= 1'b0;
                            end else begin
                                out_data  <= use_dict ? dict_rd_data : history[copy_src_addr_next];
                                out_valid <= 1'b1;
                            end
                        end else begin
                            // First entry into S_COPY (out_valid was 0): fetch
                            // the first source byte, no address advance yet.
                            out_data  <= use_dict ? dict_rd_data : history[copy_src_addr];
                            out_valid <= 1'b1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

    assign out_tile_id     = tile_id_q;
    assign out_tile_offset = wr_ptr;
    // Latched tile_last_q lines up with the cycle this symbol's byte is
    // actually written (wr_ptr advances), not with whenever the input
    // port happened to pulse it -- see write-up in tans_decoder.sv on why
    // a live read of the input would be stale by the time it matters.
    // NOTE: for a match spanning multiple bytes, tile_last_q applies to
    // the WHOLE match; only assert out_tile_last on the FINAL byte of the
    // copy loop (copy_len_q==1 in S_COPY), not every byte of it.
    assign out_tile_last = (st == S_LITERAL) ? (tile_last_q && (wr_ptr == TILE_SIZE_BYTES-1))
                          : (st == S_COPY)   ? (tile_last_q && (copy_len_q == 8'd1) && (wr_ptr == TILE_SIZE_BYTES-1))
                          : 1'b0;

endmodule