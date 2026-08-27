module lz_reconstruct #(
    parameter int TILE_SIZE_BYTES  = 4096,
    parameter int NUM_TILES        = 64,
    parameter int DICT_DEPTH_BYTES = 32768
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0]  in_symbol,
    input  logic [15:0] in_lz_offset,
    input  logic [7:0]  in_lz_length,
    input  logic        in_is_lz_token,
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

    logic [7:0] history [0:TILE_SIZE_BYTES-1];
    logic [TILE_ADDR_W-1:0] wr_ptr;

    typedef enum logic [1:0] {S_IDLE, S_LITERAL, S_COPY, S_DRAIN} state_e;
    state_e st, st_n;

    logic [15:0] copy_offset_q;
    logic [7:0]  copy_len_q;
    logic [$clog2(NUM_TILES)-1:0] tile_id_q;
    logic tile_last_q; 

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_IDLE;
        else        st <= st_n;
    end

    always_comb begin
        st_n = st;
        unique case (st)
            S_IDLE: if (in_valid) begin
                        if (in_is_lz_token) st_n = S_COPY;
                        else                 st_n = S_LITERAL;
                    end
            S_LITERAL: if (out_valid && out_ready) st_n = S_IDLE;
            S_COPY: if (out_valid && out_ready && copy_len_q == 8'd1) st_n = S_IDLE;
            default: st_n = S_IDLE;
        endcase
    end

    assign in_ready = (st == S_IDLE);

    logic use_dict;
    logic [TILE_ADDR_W-1:0] hist_rd_addr;
    assign use_dict     = (copy_offset_q >= TILE_SIZE_BYTES);
    assign hist_rd_addr = wr_ptr - copy_offset_q[TILE_ADDR_W-1:0];
    assign dict_rd_addr = copy_offset_q - TILE_SIZE_BYTES;
    assign dict_rd_en   = (st == S_COPY) && use_dict;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr        <= '0;
            out_valid     <= 1'b0;
            copy_len_q    <= '0;
            copy_offset_q <= '0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (in_valid && !in_is_lz_token) begin
                        out_data   <= in_symbol;
                        out_valid  <= 1'b1;
                        tile_id_q  <= in_tile_id;
                        tile_last_q<= in_tile_last;
                    end else if (in_valid && in_is_lz_token) begin
                        copy_offset_q <= in_lz_offset;
                        copy_len_q    <= in_lz_length;
                        tile_id_q     <= in_tile_id;
                        tile_last_q   <= in_tile_last;
                        out_valid     <= 1'b0; 
                    end
                end

                S_LITERAL: begin
                    if (out_valid && out_ready) begin
                        history[wr_ptr] <= out_data;
                        wr_ptr          <= wr_ptr + 1;
                        out_valid       <= 1'b0;
                    end
                end

                S_COPY: begin
                    out_data  <= use_dict ? dict_rd_data : history[hist_rd_addr];
                    out_valid <= 1'b1;
                    if (out_valid && out_ready) begin
                        history[wr_ptr] <= out_data;
                        wr_ptr          <= wr_ptr + 1;
                        copy_offset_q   <= copy_offset_q; 
                        copy_len_q      <= copy_len_q - 1;
                        if (copy_len_q == 8'd1) out_valid <= 1'b0;
                    end
                end

                default: ;
            endcase
        end
    end

    assign out_tile_id     = tile_id_q;
    assign out_tile_offset = wr_ptr;
    assign out_tile_last   = tile_last_q && (wr_ptr == TILE_SIZE_BYTES-1);

endmodule
