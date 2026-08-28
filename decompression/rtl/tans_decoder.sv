
module tans_decoder #(
    parameter int NUM_TILES     = 64,
    parameter int STATE_BITS    = 12,
    parameter int MAX_SYM_BITS  = 9,
    parameter int MAX_NB_BITS   = 16,
    parameter int MAX_SYMBOLS_PER_TILE = 4096
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,

    input  logic                          tile_start,
    input  logic [STATE_BITS-1:0]         init_state,
    input  logic [$clog2(MAX_SYMBOLS_PER_TILE+1)-1:0] num_symbols_this_tile,

    output logic [MAX_SYM_BITS-1:0] out_symbol,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_tile_last,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,

    input  logic                         table_wr_en,
    input  logic [STATE_BITS-1:0]        table_wr_addr,
    input  logic [MAX_SYM_BITS-1:0]      table_wr_symbol,
    input  logic [$clog2(MAX_NB_BITS+1)-1:0] table_wr_nbbits,
    input  logic [STATE_BITS-1:0]        table_wr_newstate_base
);

    localparam int NB_BITS_W  = $clog2(MAX_NB_BITS+1);
    localparam int SYMCNT_W   = $clog2(MAX_SYMBOLS_PER_TILE+1);
    localparam int TILEID_W   = $clog2(NUM_TILES);

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

    localparam int SHREG_W   = 8 + MAX_NB_BITS;
    localparam int AVAIL_W   = $clog2(SHREG_W+1);
    localparam int AVAIL_MAX_ACCEPT = SHREG_W - 8;

    logic [SHREG_W-1:0]  shreg;
    logic [AVAIL_W-1:0]  bits_avail;

    logic [STATE_BITS-1:0] state_reg;

    tans_entry_t cur_entry;
    assign cur_entry = table_mem[state_reg];

    logic [NB_BITS_W-1:0] cur_nb_bits;
    assign cur_nb_bits = cur_entry.nb_bits;

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

    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_LOOKUP = 3'd1,
        S_EMIT   = 3'd2
    } state_e;
    state_e st, st_n;

    logic [SYMCNT_W-1:0] sym_ctr;
    logic [SYMCNT_W-1:0] num_symbols_q;
    logic [TILEID_W-1:0] tile_id_q;

    logic bits_ready;
    assign bits_ready = (bits_avail >= {{(AVAIL_W-NB_BITS_W){1'b0}}, cur_nb_bits});

    logic emit_fire;
    assign emit_fire = (st == S_EMIT) && out_valid && out_ready;

    logic lookup_fire;
    assign lookup_fire = (st == S_LOOKUP) && bits_ready;

    logic last_symbol;
    assign last_symbol = ((sym_ctr + {{(SYMCNT_W-1){1'b0}}, 1'b1}) == num_symbols_q);

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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shreg      <= '0;
            bits_avail <= '0;
        end else if ((st == S_IDLE) && tile_start) begin

            shreg      <= '0;
            bits_avail <= '0;
        end else if (byte_fire && emit_fire) begin

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

            if ((st == S_IDLE) && tile_start) begin
                state_reg     <= init_state;
                sym_ctr       <= '0;
                num_symbols_q <= num_symbols_this_tile;
                tile_id_q     <= in_tile_id;
            end

            if (lookup_fire) begin
                out_symbol    <= cur_entry.symbol;
                out_tile_id   <= tile_id_q;
                out_tile_last <= last_symbol;
                out_valid     <= 1'b1;
            end else if (out_valid && out_ready) begin
                out_valid     <= 1'b0;
                out_tile_last <= 1'b0;
            end

            if (emit_fire) begin
                state_reg <= cur_entry.newstate_base +
                             consumed_value[STATE_BITS-1:0];
                sym_ctr   <= sym_ctr + {{(SYMCNT_W-1){1'b0}}, 1'b1};
            end
        end
    end

endmodule
