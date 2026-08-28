
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
    logic tile_last_q;

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

    assign in_ready = (st == S_IDLE) || (st == S_GET_OFF_HI) ||
                       (st == S_GET_OFF_LO) || (st == S_GET_LEN);

    logic use_dict;
    logic [TILE_ADDR_W-1:0] copy_src_addr;

    logic [TILE_ADDR_W-1:0] copy_src_addr_next;
    assign use_dict            = (copy_offset_q >= TILE_SIZE_BYTES);
    assign copy_src_addr_next  = copy_src_addr + 1;
    assign dict_rd_addr = use_dict ? (copy_src_addr - TILE_SIZE_BYTES) : '0;
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
                    if (in_valid && in_symbol != ESCAPE_SYMBOL[8:0]) begin
                        out_data    <= in_symbol[7:0];
                        out_valid   <= 1'b1;
                        tile_id_q   <= in_tile_id;
                        tile_last_q <= in_tile_last;
                    end else if (in_valid) begin

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
                    tile_last_q <= in_tile_last;

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

    assign out_tile_last = (st == S_LITERAL) ? (tile_last_q && (wr_ptr == TILE_SIZE_BYTES-1))
                          : (st == S_COPY)   ? (tile_last_q && (copy_len_q == 8'd1) && (wr_ptr == TILE_SIZE_BYTES-1))
                          : 1'b0;

endmodule
