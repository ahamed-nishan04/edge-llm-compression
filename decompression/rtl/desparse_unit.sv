
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

    localparam int TID_W = $clog2(NUM_TILES);
    localparam int OFF_W = $clog2(TILE_SIZE_BYTES);

    localparam logic [1:0] S_GET_IDX = 2'd0;
    localparam logic [1:0] S_GET_V0  = 2'd1;
    localparam logic [1:0] S_GET_V1  = 2'd2;
    localparam logic [1:0] S_EMIT    = 2'd3;

    localparam logic [OFF_W-1:0] OFF_ONE  = {{(OFF_W-1){1'b0}}, 1'b1};
    localparam logic [OFF_W-1:0] OFF_ZERO = {OFF_W{1'b0}};
    localparam logic [TID_W-1:0] TID_ZERO = {TID_W{1'b0}};

    logic [1:0]       st;
    logic [1:0]       st_n;

    logic [3:0]       idx_q;
    logic [7:0]       v0_q;
    logic [7:0]       v1_q;
    logic [1:0]       emit_pos;
    logic [TID_W-1:0] tile_id_q;
    logic [OFF_W-1:0] out_off_q;
    logic             group_last_q;

    logic eff_bypass;
    assign eff_bypass = bypass || (ENABLE == 1'b0);

    logic [3:0] in_nib;
    assign in_nib = in_data[3:0];

    logic idx0, idx1, idx2, idx3;
    assign idx0 = idx_q[0];
    assign idx1 = idx_q[1];
    assign idx2 = idx_q[2];
    assign idx3 = idx_q[3];

    logic pos0, pos1, pos2, pos3;
    assign pos0 = (emit_pos == 2'd0);
    assign pos1 = (emit_pos == 2'd1);
    assign pos2 = (emit_pos == 2'd2);
    assign pos3 = (emit_pos == 2'd3);

    logic last_pos;
    assign last_pos = pos3;

    logic       bit_set;
    logic       use_v1;
    logic [7:0] emit_data;

    assign bit_set = (pos0 & idx0) | (pos1 & idx1) |
                     (pos2 & idx2) | (pos3 & idx3);

    assign use_v1  = (pos1 & idx0) |
                     (pos2 & (idx0 | idx1)) |
                     (pos3 & (idx0 | idx1 | idx2));

    assign emit_data = bit_set ? (use_v1 ? v1_q : v0_q) : 8'h00;

    logic in_fire;
    logic emit_fire;

    assign in_ready  = eff_bypass ? out_ready : (st != S_EMIT);
    assign in_fire   = in_valid && in_ready && !eff_bypass;
    assign emit_fire = (!eff_bypass) && (st == S_EMIT) && out_ready;

    assign out_data        = eff_bypass ? in_data        : emit_data;
    assign out_valid       = eff_bypass ? in_valid       : (st == S_EMIT);
    assign out_tile_id     = eff_bypass ? in_tile_id     : tile_id_q;
    assign out_tile_offset = eff_bypass ? in_tile_offset : out_off_q;
    assign out_tile_last   = eff_bypass ? in_tile_last
                                        : (group_last_q && last_pos);

    logic        end_of_tile;
    logic [1:0]  emit_pos_nxt;
    logic [OFF_W-1:0] out_off_inc;
    logic [OFF_W-1:0] out_off_nxt;
    logic [3:0]  group_last_or;

    assign end_of_tile  = group_last_q & last_pos;
    assign emit_pos_nxt = emit_pos + 2'd1;
    assign out_off_inc  = out_off_q + OFF_ONE;
    assign out_off_nxt  = end_of_tile ? OFF_ZERO : out_off_inc;
    assign group_last_or = 4'd0;

    logic group_last_upd;
    assign group_last_upd = group_last_q | in_tile_last;

    logic group_last_emit;
    assign group_last_emit = end_of_tile ? 1'b0 : group_last_q;

    always_comb begin
        st_n = S_GET_IDX;
        if (eff_bypass) begin
            st_n = S_GET_IDX;
        end else begin
            case (st)
                S_GET_IDX: st_n = in_fire ? S_GET_V0 : S_GET_IDX;
                S_GET_V0 : st_n = in_fire ? S_GET_V1 : S_GET_V0;
                S_GET_V1 : st_n = in_fire ? S_EMIT   : S_GET_V1;
                S_EMIT   : st_n = (emit_fire && last_pos) ? S_GET_IDX : S_EMIT;
                default  : st_n = S_GET_IDX;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) st <= S_GET_IDX;
        else        st <= st_n;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_q        <= 4'd0;
            v0_q         <= 8'd0;
            v1_q         <= 8'd0;
            emit_pos     <= 2'd0;
            tile_id_q    <= TID_ZERO;
            out_off_q    <= OFF_ZERO;
            group_last_q <= 1'b0;
        end else if (eff_bypass) begin

            idx_q        <= 4'd0;
            v0_q         <= 8'd0;
            v1_q         <= 8'd0;
            emit_pos     <= 2'd0;
            group_last_q <= 1'b0;
            out_off_q    <= OFF_ZERO;
            tile_id_q    <= in_tile_id;
        end else begin
            case (st)
                S_GET_IDX: begin
                    if (in_fire) begin
                        idx_q        <= in_nib;
                        tile_id_q    <= in_tile_id;
                        group_last_q <= in_tile_last;
                        emit_pos     <= 2'd0;
                    end
                end
                S_GET_V0: begin
                    if (in_fire) begin
                        v0_q         <= in_data;
                        group_last_q <= group_last_upd;
                    end
                end
                S_GET_V1: begin
                    if (in_fire) begin
                        v1_q         <= in_data;
                        group_last_q <= group_last_upd;
                    end
                end
                S_EMIT: begin
                    if (emit_fire) begin
                        emit_pos     <= emit_pos_nxt;
                        out_off_q    <= out_off_nxt;
                        group_last_q <= group_last_emit;
                    end
                end
                default: begin

                end
            endcase
        end
    end

endmodule
