// =============================================================================
// tans_encoder.sv
// Batch tANS/FSE encoder. Matches model/kv_encoder.c's algorithm exactly
// (same power-of-2 frequency normalization, same backward encode pass, same
// LSB-first bit-packing convention as fse_codec.c) so RTL and golden model
// agree bit-for-bit -- verify against that C model before trusting this in
// simulation; this file has NOT yet been through iterative RTL simulation
// debugging the way the decompression side's tans_decoder.sv was. Expect to
// find and fix real bugs here the same way (see that file's/this project's
// commit history for the kind of issues that turned up: off-by-ones in
// bit-count bookkeeping, tile-boundary latching, FSM race conditions).
//
// Phases (one FSM, gated by `phase`):
//   COUNT      -- tally symbol frequency as tokens arrive (no extra pass
//                 needed; overlaps with lz_match_finder producing tokens)
//   NORMALIZE  -- reduce raw counts to power-of-2 freq[] summing to
//                 tableSize, via the "double the `remaining` most frequent
//                 symbols" rule derived in kv_encoder.c's header. Iterative
//                 max-extraction (bounded by remaining <= nbSymbols <= 257
//                 iterations, each scanning up to 257 candidates) -- not
//                 fast, but correct and simple; optimize later if this
//                 phase's latency matters more than tile throughput does.
//   BUILD_BASE -- prefix-sum freq[] into base[] over all 257 possible
//                 symbol values (freq=0 entries contribute 0, no symbol
//                 compaction needed -- see header derivation)
//   BACKWARD   -- the actual encode pass, symbols n-1 down to 0
//   SERIALIZE  -- forward pass over the (already correctly forward-ordered
//                 -- see header) per-symbol (nbBits,bits) results, packing
//                 into output bytes LSB-first
// =============================================================================

module tans_encoder #(
    parameter int MAX_TOKENS_PER_TILE = 16384,
    parameter int STATE_BITS          = 12,
    parameter int MAX_SYM_BITS        = 9,
    parameter int MAX_NB_BITS         = 16,
    parameter int NUM_SYMBOL_VALUES   = 257   // 0-255 literal + 256 ESCAPE
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [MAX_SYM_BITS-1:0] in_symbol,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_last,
    input  logic [$clog2(MAX_TOKENS_PER_TILE)-1:0] in_tok_count, // total token count, valid when in_last

    output logic [7:0]  out_byte,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_last,
    output logic [STATE_BITS-1:0] out_init_state,
    output logic [31:0] out_total_bytes
);

    localparam int TOK_ADDR_W = $clog2(MAX_TOKENS_PER_TILE);
    localparam int SYM_ADDR_W = $clog2(NUM_SYMBOL_VALUES);

    // ---------------- Token buffer (filled during COUNT phase) ----------
    logic [MAX_SYM_BITS-1:0] token_buf [0:MAX_TOKENS_PER_TILE-1];
    logic [TOK_ADDR_W-1:0]   fill_ptr;
    logic [TOK_ADDR_W-1:0]   n_tokens_q; // latched total count

    // ---------------- Frequency / base tables (dense, indexed by symbol
    // value 0..256 directly -- see header, no compaction needed) --------
    logic [TOK_ADDR_W-1:0] raw_count [0:NUM_SYMBOL_VALUES-1];
    logic [15:0]           freq      [0:NUM_SYMBOL_VALUES-1]; // power-of-2
    logic [STATE_BITS-1:0] base_tbl  [0:NUM_SYMBOL_VALUES-1];
    logic                  freq_assigned [0:NUM_SYMBOL_VALUES-1]; // used
                                                                     // during
                                                                     // NORMALIZE
                                                                     // to mark
                                                                     // symbols
                                                                     // already
                                                                     // bumped
                                                                     // to
                                                                     // freq=2

    typedef enum logic [3:0] {
        S_IDLE, S_COUNT,
        S_NORM_INIT, S_NORM_FIND_MAX, S_NORM_MARK,
        S_BASE_INIT, S_BASE_SCAN,
        S_BWD_INIT, S_BWD_STEP,
        S_SER_INIT, S_SER_STEP,
        S_DONE
    } state_e;
    state_e st, st_n;

    assign in_ready = (st == S_IDLE) || (st == S_COUNT);

    // ---------------- COUNT phase: buffer tokens + tally raw counts -----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_ptr <= '0;
        end else if (st == S_IDLE || st == S_COUNT) begin
            if (in_valid && in_ready) begin
                token_buf[fill_ptr] <= in_symbol;
                raw_count[in_symbol] <= raw_count[in_symbol] + 1;
                fill_ptr <= fill_ptr + 1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) n_tokens_q <= '0;
        else if (in_valid && in_ready && in_last) n_tokens_q <= fill_ptr + 1;
    end

    // ---------------- NORMALIZE phase state ----------------
    logic [SYM_ADDR_W-1:0] nbSymbols_q;      // count of distinct observed symbols
    logic [SYM_ADDR_W:0]   tableLog_q;
    logic [STATE_BITS:0]   tableSize_q;
    logic [SYM_ADDR_W:0]   remaining_q;
    logic [SYM_ADDR_W:0]   remaining_ctr;    // counts down during S_NORM_FIND_MAX iterations

    logic [SYM_ADDR_W-1:0] scan_sym;         // 0..256 scan cursor within a NORM_FIND_MAX pass
    logic [TOK_ADDR_W-1:0] cur_max_count;
    logic [SYM_ADDR_W-1:0] cur_max_sym;

    // ---------------- BASE phase ----------------
    logic [SYM_ADDR_W-1:0] base_scan;
    logic [STATE_BITS-1:0] running_sum;

    // ---------------- BACKWARD phase ----------------
    logic [TOK_ADDR_W-1:0] bwd_i;            // counts n_tokens_q-1 downto 0
    logic [STATE_BITS-1:0] enc_state;
    logic [$clog2(MAX_NB_BITS+1)-1:0] result_nbbits [0:MAX_TOKENS_PER_TILE-1];
    logic [MAX_NB_BITS-1:0]           result_bits   [0:MAX_TOKENS_PER_TILE-1];

    logic [MAX_SYM_BITS-1:0] bwd_sym;
    logic [15:0] bwd_freq;
    logic [$clog2(MAX_NB_BITS+1)-1:0] bwd_nbbits;
    logic [MAX_NB_BITS-1:0] bwd_mask;
    logic [STATE_BITS-1:0] bwd_j, bwd_bits, bwd_newstate;

    assign bwd_sym    = token_buf[bwd_i];
    assign bwd_freq    = freq[bwd_sym];

    function automatic [3:0] ilog2_16(input [15:0] x);
        integer i;
        reg [3:0] r;
        begin
            r = 0;
            for (i = 15; i >= 1; i = i - 1)
                if (x[i]) r = i[3:0];
            ilog2_16 = r;
        end
    endfunction

    assign bwd_nbbits   = tableLog_q[$clog2(MAX_NB_BITS+1)-1:0] - {1'b0,ilog2_16(bwd_freq)};
    assign bwd_mask     = (bwd_nbbits == 0) ? '0 : (({{(MAX_NB_BITS-1){1'b0}},1'b1} << bwd_nbbits) - 1'b1);
    assign bwd_j        = enc_state >> bwd_nbbits;
    assign bwd_bits      = enc_state & bwd_mask[STATE_BITS-1:0];
    assign bwd_newstate = base_tbl[bwd_sym] + bwd_j;

    // ---------------- SERIALIZE phase ----------------
    logic [TOK_ADDR_W-1:0] ser_i;
    logic [7:0] out_shreg;
    logic [3:0] out_bits_in_shreg;
    logic [31:0] byte_ctr;

    logic [SYM_ADDR_W:0] nb_count;   // scratch for S_IDLE's distinct-symbol count
    logic [SYM_ADDR_W:0] tl_scratch; // scratch for S_NORM_INIT's tableLog search
    logic [15:0] merged;             // scratch for S_SER_STEP's bit-pack merge
    logic [4:0]  merged_cnt;

    // =========================================================================
    // Main FSM
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_IDLE       : if (in_valid) st_n = S_COUNT;
            S_COUNT      : if (in_valid && in_ready && in_last) st_n = S_NORM_INIT;
            S_NORM_INIT  : if (remaining_q == 0) st_n = S_BASE_INIT; else st_n = S_NORM_FIND_MAX;
            S_NORM_FIND_MAX: if (scan_sym == NUM_SYMBOL_VALUES-1) st_n = S_NORM_MARK;
            S_NORM_MARK  : if (remaining_ctr == 1) st_n = S_BASE_INIT; else st_n = S_NORM_FIND_MAX;
            S_BASE_INIT  : st_n = S_BASE_SCAN;
            S_BASE_SCAN  : if (base_scan == NUM_SYMBOL_VALUES-1) st_n = S_BWD_INIT;
            S_BWD_INIT   : st_n = S_BWD_STEP;
            S_BWD_STEP   : if (bwd_i == 0) st_n = S_SER_INIT;
            S_SER_INIT   : st_n = S_SER_STEP;
            S_SER_STEP   : if (out_valid && out_ready && ser_i == n_tokens_q - 1 &&
                                out_bits_in_shreg == 0) st_n = S_DONE;
            S_DONE       : st_n = S_IDLE;
            default      : st_n = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nbSymbols_q   <= '0;
            tableLog_q    <= '0;
            tableSize_q   <= '0;
            remaining_q   <= '0;
            remaining_ctr <= '0;
            scan_sym      <= '0;
            cur_max_count <= '0;
            cur_max_sym   <= '0;
            base_scan     <= '0;
            running_sum   <= '0;
            enc_state     <= '0;
            bwd_i         <= '0;
            ser_i         <= '0;
            out_shreg     <= '0;
            out_bits_in_shreg <= '0;
            byte_ctr      <= '0;
            out_valid     <= 1'b0;
            out_last      <= 1'b0;
            out_init_state <= '0;
            out_total_bytes <= '0;
        end else begin
            unique case (st)
                // ---- transition from COUNT: count distinct symbols,
                // pick tableLog = ceil(log2(nbSymbols)) ----
                S_IDLE: begin
                    for (int s = 0; s < NUM_SYMBOL_VALUES; s++) begin
                        raw_count[s]     <= '0;
                        freq[s]          <= '0;
                        freq_assigned[s] <= 1'b0;
                    end
                end
                S_COUNT: if (in_valid && in_ready && in_last) begin
                    // count distinct symbols and seed freq[s]=1 for each
                    // observed one, in the SAME pass (combinational scan
                    // over all 257 counters -- fine, this runs once, not
                    // per-token)
                    nb_count = 0;
                    for (int s = 0; s < NUM_SYMBOL_VALUES; s++) begin
                        if (raw_count[s] != 0) begin
                            freq[s] <= 16'd1;
                            nb_count = nb_count + 1;
                        end
                    end
                    nbSymbols_q <= nb_count[SYM_ADDR_W-1:0];
                end

                S_NORM_INIT: begin
                    tl_scratch = 0;
                    while ((1 << tl_scratch) < nbSymbols_q) tl_scratch = tl_scratch + 1;
                    if (tl_scratch == 0) tl_scratch = 1;
                    tableLog_q  <= tl_scratch[SYM_ADDR_W:0];
                    tableSize_q <= (STATE_BITS+1)'(1 << tl_scratch);
                    remaining_q <= (SYM_ADDR_W+1)'((1 << tl_scratch) - nbSymbols_q);
                    remaining_ctr <= (SYM_ADDR_W+1)'((1 << tl_scratch) - nbSymbols_q);
                    scan_sym      <= '0;
                    cur_max_count <= '0;
                    cur_max_sym   <= '0;
                end

                S_NORM_FIND_MAX: begin
                    if (!freq_assigned[scan_sym] && freq[scan_sym] != 0 &&
                        raw_count[scan_sym] > cur_max_count) begin
                        cur_max_count <= raw_count[scan_sym];
                        cur_max_sym   <= scan_sym;
                    end
                    scan_sym <= scan_sym + 1;
                end

                S_NORM_MARK: begin
                    freq[cur_max_sym]          <= 16'd2;
                    freq_assigned[cur_max_sym] <= 1'b1;
                    remaining_ctr <= remaining_ctr - 1;
                    scan_sym      <= '0;
                    cur_max_count <= '0;
                    cur_max_sym   <= '0;
                end

                S_BASE_INIT: begin
                    base_scan   <= '0;
                    running_sum <= '0;
                end
                S_BASE_SCAN: begin
                    base_tbl[base_scan] <= running_sum;
                    running_sum <= running_sum + freq[base_scan][STATE_BITS-1:0];
                    base_scan   <= base_scan + 1;
                end

                S_BWD_INIT: begin
                    enc_state <= '0; // arbitrary seed, matches kv_encoder.c
                    bwd_i     <= n_tokens_q - 1;
                end
                S_BWD_STEP: begin
                    result_nbbits[bwd_i] <= bwd_nbbits;
                    result_bits[bwd_i]   <= {{(MAX_NB_BITS-STATE_BITS){1'b0}}, bwd_bits};
                    enc_state <= bwd_newstate;
                    if (bwd_i != 0) bwd_i <= bwd_i - 1;
                end

                S_SER_INIT: begin
                    out_init_state <= enc_state; // final backward-pass state = state_0
                    ser_i          <= '0;
                    out_shreg      <= '0;
                    out_bits_in_shreg <= '0;
                    byte_ctr       <= '0;
                end

                S_SER_STEP: begin
                    // Pack result_bits[ser_i] (result_nbbits[ser_i] wide)
                    // into out_shreg LSB-first; flush a byte whenever 8
                    // bits are ready. Matches fse_codec.c's BitWriter
                    // exactly (LSB-first within byte, bytes in order).
                    if (!out_valid || out_ready) begin
                        merged     = {8'd0, out_shreg} | (result_bits[ser_i] << out_bits_in_shreg);
                        merged_cnt = out_bits_in_shreg + result_nbbits[ser_i];

                        if (merged_cnt >= 8) begin
                            out_byte          <= merged[7:0];
                            out_valid         <= 1'b1;
                            out_shreg         <= merged[15:8];
                            out_bits_in_shreg <= merged_cnt - 8;
                            byte_ctr          <= byte_ctr + 1;
                        end else begin
                            out_shreg         <= merged[7:0];
                            out_bits_in_shreg <= merged_cnt[3:0];
                            out_valid         <= 1'b0;
                        end

                        if (ser_i == n_tokens_q - 1) begin
                            // last token processed -- if leftover bits
                            // remain unflushed, flush a final padded byte
                            if (merged_cnt < 8 && merged_cnt != 0) begin
                                out_byte  <= merged[7:0];
                                out_valid <= 1'b1;
                                out_last  <= 1'b1;
                                byte_ctr  <= byte_ctr + 1;
                            end else begin
                                out_last <= (merged_cnt >= 8);
                            end
                            out_total_bytes <= 32'(byte_ctr) + (merged_cnt >= 8 ? 1 : 0) +
                                                ((merged_cnt < 8 && merged_cnt != 0) ? 1 : 0);
                        end else begin
                            ser_i <= ser_i + 1;
                        end
                    end else if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                    end
                end

                S_DONE: begin
                    out_valid <= 1'b0;
                    out_last  <= 1'b0;
                end

                default: ;
            endcase
        end
    end

endmodule
