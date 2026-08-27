module tans_decoder #(
    parameter int NUM_TILES     = 64,
    parameter int STATE_BITS    = 12,          
    parameter int MAX_SYM_BITS  = 9,            
    parameter int MAX_NB_BITS   = 16
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0]  in_byte,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_tile_last,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,

    output logic [7:0]  out_symbol,
    output logic [15:0] out_lz_offset,
    output logic [7:0]  out_lz_length,
    output logic        out_is_lz_token,
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

    typedef struct packed {
        logic [MAX_SYM_BITS-1:0]              symbol;
        logic [$clog2(MAX_NB_BITS+1)-1:0]      nb_bits;
        logic [STATE_BITS-1:0]                 newstate_base;
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

    logic [7:0]  shreg;
    logic [3:0]  bits_avail;
    logic        need_byte;

    logic [STATE_BITS-1:0] fse_state, fse_state_n;
    tans_entry_t cur_entry;
    assign cur_entry = table_mem[fse_state];

    typedef enum logic [2:0] {
        S_IDLE, S_INIT_STATE, S_LOOKUP, S_READ_BITS, S_EMIT, S_DONE
    } state_e;
    state_e st, st_n;

    logic [$clog2(NUM_TILES)-1:0] tile_id_q;
    logic tile_last_q;
    logic tile_active_q; 

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_IDLE       : if (in_valid) begin
                                if (tile_active_q) st_n = S_LOOKUP;
                                else                st_n = S_INIT_STATE;
                            end
            S_INIT_STATE : st_n = S_LOOKUP;
            S_LOOKUP     : st_n = S_READ_BITS;
            S_READ_BITS  : if (bits_avail >= cur_entry.nb_bits) st_n = S_EMIT;
            S_EMIT       : if (out_valid && out_ready) begin
                                if (tile_last_q) st_n = S_DONE;
                                else              st_n = S_IDLE;
                            end
            S_DONE       : st_n = S_IDLE;
            default      : st_n = S_IDLE;
        endcase
    end

    assign in_ready = (st == S_IDLE) || (st == S_READ_BITS && bits_avail < cur_entry.nb_bits);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shreg      <= '0;
            bits_avail <= '0;
        end else if (in_valid && in_ready) begin
            shreg      <= {shreg[6:0], in_byte[7]}; 
            bits_avail <= bits_avail + 1;
            tile_id_q  <= in_tile_id;
            tile_last_q<= in_tile_last;
        end else if (st == S_EMIT && out_valid && out_ready) begin
            bits_avail <= bits_avail - cur_entry.nb_bits;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end else if (st == S_LOOKUP) begin
            out_valid <= 1'b0;
        end else if (st == S_READ_BITS && bits_avail >= cur_entry.nb_bits) begin
            out_symbol      <= cur_entry.symbol;
            out_is_lz_token <= 1'b0;              
            out_lz_offset   <= '0;
            out_lz_length   <= '0;
            out_tile_id     <= tile_id_q;
            out_tile_last   <= tile_last_q;
            out_valid       <= 1'b1;
        end else if (out_ready) begin
            out_valid <= 1'b0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fse_state <= '0;
        else if (st == S_INIT_STATE) fse_state <= '0; 
        else if (st == S_EMIT && out_valid && out_ready)
            fse_state <= cur_entry.newstate_base; 
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) tile_active_q <= 1'b0;
        else if (st == S_INIT_STATE) tile_active_q <= 1'b1;
        else if (st == S_DONE)       tile_active_q <= 1'b0;
    end

endmodule
