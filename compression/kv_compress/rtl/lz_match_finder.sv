// =============================================================================
// lz_match_finder.sv
// Single-pass, hash-table-based greedy LZ77 match finder. Buffers the
// incoming (already-quantized) tile bytes as they arrive, then -- once the
// whole tile is resident -- scans it once, emitting literal symbols
// (0-255) or 4-symbol match tokens (ESCAPE, offset_hi, offset_lo, length)
// in exactly the format lz_reconstruct.sv (decompression side) expects.
//
// Buffering the tile before scanning (rather than matching byte-by-byte
// as data streams in) is a deliberate simplification: it avoids having to
// handle "match extends past what's arrived so far" edge cases, and the
// scan itself is fast (bounded by TILE_SIZE_BYTES cycles) relative to the
// token-arrival rate, so it doesn't add meaningful latency beyond what
// quant_pack's own buffering already requires.
//
// SIMPLIFICATIONS (documented, not hidden -- see model/kv_encoder.c for
// the exhaustive-search golden reference this trades accuracy for):
// - In-tile history hash table: direct-mapped (one candidate position per
//   hash bucket), so hash collisions can cause a real match to be missed.
//   A real implementation would use a multi-way (e.g. 4-way) table or
//   chain multiple candidates.
// - Dictionary hash table: NOT built by this module. It must be
//   pre-populated by the host whenever D_KV's contents change (via
//   dict_hash_wr_*, mirroring table_wr_* elsewhere in this codebase) --
//   there's no automatic re-indexing here yet. Until that's wired up,
//   dict_hash_valid stays low and only in-tile matches are found.
// =============================================================================

module lz_match_finder #(
    parameter int TILE_SIZE_BYTES      = 4096,
    parameter int DICT_DEPTH_BYTES     = 32768,
    parameter int MIN_MATCH_LEN        = 4,
    parameter int MAX_MATCH_LEN        = 255,
    parameter int HASH_BITS            = 10,
    parameter int MAX_TOKENS_PER_TILE  = TILE_SIZE_BYTES * 4,
    parameter int TILE_ADDR_WIDTH      = $clog2(TILE_SIZE_BYTES)
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_last,
    input  logic [TILE_ADDR_WIDTH-1:0] in_offset,

    output logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_rd_addr,
    input  logic [7:0]                          dict_rd_data,
    output logic                                dict_rd_en,

    // ---------------- Dictionary hash-table preload (host-populated,
    // see header note -- optional; leave unwritten to disable dict
    // matching entirely) --------------------------------------------------
    input  logic                          dict_hash_wr_en,
    input  logic [HASH_BITS-1:0]          dict_hash_wr_addr,
    input  logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_hash_wr_pos,
    input  logic                          dict_hash_wr_valid,

    output logic [8:0]  out_symbol,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_last,
    output logic [$clog2(MAX_TOKENS_PER_TILE)-1:0] out_tok_count
);

    // ---------------- Tile history buffer (filled as bytes arrive) -------
    logic [7:0] history [0:TILE_SIZE_BYTES-1];
    logic [TILE_ADDR_WIDTH-1:0] fill_count;

    assign in_ready = 1'b1; // always accept -- buffering is the only job here
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_count <= '0;
        end else if (in_valid) begin
            history[in_offset] <= in_byte;
            fill_count         <= in_last ? '0 : fill_count + 1;
        end
    end
    typedef enum logic [2:0] {
        S_WAIT_TILE, S_LOOKUP, S_EXTEND_HIST, S_EXTEND_DICT, S_DECIDE, S_EMIT, S_DONE
    } state_e;
    state_e st, st_n;
    // WIDTH FIX: a full tile length is TILE_SIZE_BYTES, which needs
    // TILE_ADDR_WIDTH+1 bits, not TILE_ADDR_WIDTH. At 16 bytes,
    // in_offset+1 = 16 wrapped to 0 in a 4-bit register, making
    // (scan_ptr + 1 >= tile_len_q) trivially true so the FSM jumped to
    // S_DONE after emitting exactly one token.
    logic [TILE_ADDR_WIDTH:0] tile_len_q; // latched total length once in_last seen
    logic tile_ready_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_ready_q <= 1'b0;
            tile_len_q   <= '0;
        end else if (in_valid && in_last) begin
            tile_ready_q <= 1'b1;
            tile_len_q   <= in_offset + 1;
        end else if (st == S_DONE) begin
            tile_ready_q <= 1'b0; // consumed; ready for next tile's fill
        end
    end

    // ---------------- In-tile hash table (direct-mapped, 1 candidate/entry) --
    logic [TILE_ADDR_WIDTH-1:0] hash_pos   [0:(1<<HASH_BITS)-1];
    logic                       hash_valid [0:(1<<HASH_BITS)-1];

    // ---------------- Dictionary hash table (host-populated) -------------
    logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_hash_pos   [0:(1<<HASH_BITS)-1];
    logic                                dict_hash_valid_mem [0:(1<<HASH_BITS)-1];

    always_ff @(posedge clk) begin
        if (dict_hash_wr_en) begin
            dict_hash_pos[dict_hash_wr_addr]       <= dict_hash_wr_pos;
            dict_hash_valid_mem[dict_hash_wr_addr] <= dict_hash_wr_valid;
        end
    end

    function automatic [HASH_BITS-1:0] hash4(input [7:0] b0, b1, b2, b3);
        // simple multiplicative hash over 4 bytes -- adequate for a
        // direct-mapped table at this scale; swap for something with
        // better avalanche behavior if collision rate matters in practice
        hash4 = (({b0,b1,b2,b3} * 32'h9E3779B1) >> (32 - HASH_BITS));
    endfunction

    // ---------------- Match-finding FSM ----------------


    logic [TILE_ADDR_WIDTH-1:0] scan_ptr;
    logic [HASH_BITS-1:0] cur_hash;
    logic [TILE_ADDR_WIDTH-1:0] hist_cand_pos;
    logic hist_cand_ok;
    logic [$clog2(DICT_DEPTH_BYTES)-1:0] dict_cand_pos;
    logic dict_cand_ok;

    logic [8:0] hist_match_len, dict_match_len; // 9 bits: up to 255 + headroom
    logic [TILE_ADDR_WIDTH-1:0] extend_i;

    logic [8:0]  best_len;
    logic [15:0] best_off; // matches lz_reconstruct's offset convention:
                            // < TILE_SIZE_BYTES = in-tile, >= = dictionary

    logic [3:0] emit_phase; // 0=escape/literal, 1=off_hi, 2=off_lo, 3=len
    logic [$clog2(MAX_TOKENS_PER_TILE)-1:0] tok_ctr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_WAIT_TILE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_WAIT_TILE : if (tile_ready_q) st_n = S_LOOKUP;
            S_LOOKUP    : st_n = S_EXTEND_HIST;
            S_EXTEND_HIST: if (extend_i == TILE_ADDR_WIDTH'(MAX_MATCH_LEN) ||
                                (scan_ptr + extend_i >= tile_len_q))
                                st_n = S_EXTEND_DICT;
            S_EXTEND_DICT: if (extend_i == TILE_ADDR_WIDTH'(MAX_MATCH_LEN) ||
                                (scan_ptr + extend_i >= tile_len_q))
                                st_n = S_DECIDE;
            S_DECIDE    : st_n = S_EMIT;
            S_EMIT      : if (out_valid && out_ready) begin
                              if (emit_phase == 4'd0 && best_len < MIN_MATCH_LEN) begin
                                  // literal just emitted
                                  if (scan_ptr + 1 >= tile_len_q) st_n = S_DONE;
                                  else                             st_n = S_LOOKUP;
                              end else if (emit_phase == 4'd3) begin
                                  // last symbol of a match token just emitted
                                  if (scan_ptr + best_len >= tile_len_q) st_n = S_DONE;
                                  else                                    st_n = S_LOOKUP;
                              end
                          end
            S_DONE      : st_n = S_WAIT_TILE;
            default     : st_n = S_WAIT_TILE;
        endcase
    end

    // ---------------- hash lookup + candidate compare ----------------
    logic [7:0] b0,b1,b2,b3;
    assign b0 = history[scan_ptr];
    assign b1 = (scan_ptr+1 < tile_len_q) ? history[scan_ptr+1] : 8'h0;
    assign b2 = (scan_ptr+2 < tile_len_q) ? history[scan_ptr+2] : 8'h0;
    assign b3 = (scan_ptr+3 < tile_len_q) ? history[scan_ptr+3] : 8'h0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_ptr <= '0;
        end else begin
            case (st)
                S_WAIT_TILE: if (tile_ready_q) scan_ptr <= '0;
                S_LOOKUP: begin
                    cur_hash      <= hash4(b0,b1,b2,b3);
                    hist_cand_pos <= hash_pos[hash4(b0,b1,b2,b3)];
                    hist_cand_ok  <= hash_valid[hash4(b0,b1,b2,b3)];
                    dict_cand_pos <= dict_hash_pos[hash4(b0,b1,b2,b3)];
                    dict_cand_ok  <= dict_hash_valid_mem[hash4(b0,b1,b2,b3)];
                    // record this position for FUTURE lookups (classic
                    // greedy-parse insert-as-you-go)
                    hash_pos[hash4(b0,b1,b2,b3)]   <= scan_ptr;
                    hash_valid[hash4(b0,b1,b2,b3)] <= 1'b1;
                    extend_i <= '0;
                    hist_match_len <= '0;
                    dict_match_len <= '0;
                end
                S_EXTEND_HIST: begin
                    if (hist_cand_ok &&
                        (scan_ptr + extend_i < tile_len_q) &&
                        (hist_cand_pos + extend_i < scan_ptr) &&
                        history[hist_cand_pos + extend_i] == history[scan_ptr + extend_i]) begin
                        hist_match_len <= hist_match_len + 1;
                        extend_i       <= extend_i + 1;
                    end else begin
                        extend_i <= TILE_ADDR_WIDTH'(MAX_MATCH_LEN); // force exit
                    end
                end
                S_EXTEND_DICT: begin
                    if (extend_i == 0) extend_i <= '0; // reset entry handled by transition below
                    if (dict_cand_ok &&
                        (scan_ptr + extend_i < tile_len_q) &&
                        dict_rd_data == history[scan_ptr + extend_i]) begin
                        dict_match_len <= dict_match_len + 1;
                        extend_i       <= extend_i + 1;
                    end else begin
                        extend_i <= TILE_ADDR_WIDTH'(MAX_MATCH_LEN);
                    end
                end
                S_DECIDE: begin
                    if (hist_match_len >= MIN_MATCH_LEN[8:0] &&
                        hist_match_len >= dict_match_len) begin
                        best_len <= hist_match_len;
                        best_off <= {6'd0, scan_ptr} - {6'd0, hist_cand_pos};
                    end else if (dict_match_len >= MIN_MATCH_LEN[8:0]) begin
                        best_len <= dict_match_len;
                        best_off <= TILE_SIZE_BYTES[15:0]
                                    + (DICT_DEPTH_BYTES[15:0] - dict_cand_pos[15:0]);
                    end else begin
                        best_len <= 9'd0;
                        best_off <= '0;
                    end
                    emit_phase <= '0;
                end
                S_EMIT: if (out_valid && out_ready) begin
                    emit_phase <= emit_phase + 1;
                    if (emit_phase == 4'd0 && best_len < MIN_MATCH_LEN) begin
                        scan_ptr <= scan_ptr + 1; // literal: advance by 1
                    end else if (emit_phase == 4'd3) begin
                        scan_ptr <= scan_ptr + best_len[TILE_ADDR_WIDTH-1:0];
                    end
                end
                default: ;
            endcase
        end
    end

    // second-pass restart of extend_i for the dict-extend state (needs to
    // start from 0 again, independent of the hist-extend loop above)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
        end else if (st == S_EXTEND_HIST && st_n == S_EXTEND_DICT) begin
            extend_i <= '0;
        end
    end

    assign dict_rd_addr = dict_cand_pos + extend_i; // widths differ; addition
                                                      // zero-extends the
                                                      // narrower operand,
                                                      // avoiding a
                                                      // negative-width
                                                      // concatenation when
                                                      // TILE_ADDR_WIDTH is
                                                      // smaller than needed
                                                      // for a padding literal
    assign dict_rd_en   = (st == S_EXTEND_DICT);

    // ---------------- output symbol emission ----------------
    always_comb begin
        out_valid = (st == S_EMIT);
        if (best_len < MIN_MATCH_LEN) begin
            out_symbol = {1'b0, history[scan_ptr]};
        end else begin
            unique case (emit_phase)
                4'd0: out_symbol = 9'd256;                 // ESCAPE
                4'd1: out_symbol = {1'b0, best_off[15:8]};  // offset_hi
                4'd2: out_symbol = {1'b0, best_off[7:0]};   // offset_lo
                4'd3: out_symbol = {1'b0, best_len[7:0]};   // length
                default: out_symbol = 9'd0;
            endcase
        end
        out_last = (st == S_EMIT) &&
                   ((best_len < MIN_MATCH_LEN && emit_phase == 4'd0 && (scan_ptr + 1 >= tile_len_q)) ||
                    (best_len >= MIN_MATCH_LEN && emit_phase == 4'd3 && (scan_ptr + best_len >= tile_len_q)));
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tok_ctr <= '0;
        else if (st == S_WAIT_TILE && tile_ready_q) tok_ctr <= '0;
        else if (out_valid && out_ready) tok_ctr <= tok_ctr + 1;
    end
    assign out_tok_count = tok_ctr;

endmodule
