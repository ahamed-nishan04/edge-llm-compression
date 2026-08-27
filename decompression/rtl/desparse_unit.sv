module desparse_unit #(
    parameter int TILE_SIZE_BYTES = 4096,
    parameter int NUM_TILES       = 64,
    parameter bit ENABLE          = 1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic bypass,

    input  logic [7:0]  in_data,
    input  logic        in_valid,
    output logic        in_ready,
    input  logic        in_tile_last,
    input  logic [$clog2(NUM_TILES)-1:0] in_tile_id,
    input  logic [$clog2(TILE_SIZE_BYTES)-1:0] in_tile_offset,

    output logic [7:0]  out_data,
    output logic        out_valid,
    input  logic        out_ready,
    output logic        out_tile_last,
    output logic [$clog2(NUM_TILES)-1:0] out_tile_id,
    output logic [$clog2(TILE_SIZE_BYTES)-1:0] out_tile_offset
);

    localparam bit EFFECTIVE_ENABLE = ENABLE; 

    typedef enum logic [2:0] {
        S_GET_IDX, S_GET_V0, S_GET_V1, S_EMIT
    } state_e;
    state_e st, st_n;

    logic [3:0] idx_q;
    logic [7:0] v0_q, v1_q;
    logic [1:0] emit_pos;
    logic [$clog2(NUM_TILES)-1:0] tile_id_q;
    logic [$clog2(TILE_SIZE_BYTES)-1:0] tile_off_q;
    logic group_last_q;

    wire eff_bypass = bypass || !EFFECTIVE_ENABLE;

    always_comb begin
        st_n = st;
        if (!eff_bypass) begin
            unique case (st)
                S_GET_IDX: if (in_valid) st_n = S_GET_V0;
                S_GET_V0 : if (in_valid) st_n = S_GET_V1;
                S_GET_V1 : if (in_valid) st_n = S_EMIT;
                S_EMIT   : if (emit_pos == 2'd3 && out_valid && out_ready) st_n = S_GET_IDX;
                default  : st_n = S_GET_IDX;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_GET_IDX;
        else        st <= st_n;
    end

    assign in_ready = eff_bypass ? out_ready :
                       ((st == S_GET_IDX || st == S_GET_V0 || st == S_GET_V1) && in_valid);

    logic sel_v1;
    assign sel_v1 = (idx_q[3:0] & (4'(1 << emit_pos) - 4'd1)) != 4'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_q <= '0; v0_q <= '0; v1_q <= '0; emit_pos <= '0;
            out_valid <= 1'b0;
        end else if (eff_bypass) begin
            out_data        <= in_data;
            out_valid       <= in_valid;
            out_tile_id     <= in_tile_id;
            out_tile_last   <= in_tile_last;
            out_tile_offset <= in_tile_offset;
        end else begin
            unique case (st)
                S_GET_IDX: if (in_valid) begin
                    idx_q        <= in_data[3:0];
                    tile_id_q    <= in_tile_id;
                    group_last_q <= in_tile_last;
                    tile_off_q   <= in_tile_offset;
                    emit_pos     <= 2'd0;
                    out_valid    <= 1'b0;
                end
                S_GET_V0: if (in_valid) v0_q <= in_data;
                S_GET_V1: if (in_valid) begin
                    v1_q      <= in_data;
                    out_valid <= 1'b1; 
                end
                S_EMIT: begin
                    if (!idx_q[emit_pos])
                        out_data <= 8'h00;
                    else if (!sel_v1)
                        out_data <= v0_q;
                    else
                        out_data <= v1_q;

                    out_tile_id     <= tile_id_q;
                    out_tile_offset <= tile_off_q;
                    out_tile_last   <= group_last_q && (emit_pos == 2'd3);
                    out_valid       <= 1'b1;
                    if (out_ready) begin
                        emit_pos   <= emit_pos + 2'd1;
                        tile_off_q <= tile_off_q + 1;
                    end
                end
                default: ;
            endcase
        end
    end

endmodule
