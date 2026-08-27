`default_nettype none
`timescale 1ns/1ps

module dp_engine #(
    parameter DP_STATES = 262144,
    parameter DP_LOG    = 18,
    parameter K         = 64,
    parameter PRICE_W   = 16,
    parameter OFFSET_W  = 23,
    parameter ML_W      = 8,
    parameter POS_W     = 18,
    parameter INF_COST  = 16'hFFFF
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              block_start,
    input  wire [POS_W-1:0]  block_len,
    input  wire [PRICE_W-1:0]  price_in [0:K],
    input  wire [OFFSET_W-1:0] off_in   [0:K-1],
    input  wire [ML_W-1:0]     len_in   [0:K-1],
    input  wire [K:0]          valid_in,
    input  wire [POS_W-1:0]    pos_in,
    input  wire                price_pulse,
    output reg                 bt_start,
    output reg  [POS_W-1:0]    bt_len,
    input  wire [POS_W-1:0]    bt_rd_addr,
    output reg  [OFFSET_W-1:0] bt_offset,
    output reg  [ML_W-1:0]     bt_length,
    output reg                 bt_is_match
);
    reg [PRICE_W-1:0]  dp_cost    [0:DP_STATES-1];
    reg                dp_is_match[0:DP_STATES-1];
    reg [OFFSET_W-1:0] dp_offset  [0:DP_STATES-1];
    reg [ML_W-1:0]     dp_ml      [0:DP_STATES-1];
    reg [PRICE_W-1:0] prune_thresh;

    localparam [PRICE_W-1:0] PRUNE_MARGIN = 16'h7FFF;

    integer i;

    wire [PRICE_W-1:0] lit_cost;
    wire [POS_W-1:0]   lit_dst;
    wire               lit_valid_upd;
    wire [16:0]        lit_limit;
    assign lit_dst       = pos_in + {{(POS_W-1){1'b0}}, 1'b1};
    assign lit_cost      = dp_cost[pos_in[DP_LOG-1:0]] + price_in[0];
    assign lit_limit     = {1'b0, prune_thresh} + {1'b0, PRUNE_MARGIN};
    assign lit_valid_upd = valid_in[0] & price_pulse
                         & (lit_cost < dp_cost[lit_dst[DP_LOG-1:0]])
                         & ({1'b0, lit_cost} <= lit_limit);
    wire [PRICE_W-1:0] match_cost      [0:K-1];
    wire [POS_W-1:0]   match_dst       [0:K-1];
    wire               match_valid_upd [0:K-1];
    wire [16:0]        match_limit     [0:K-1];

    genvar gv;
    generate
        for (gv = 0; gv < K; gv = gv+1) begin : GEN_MATCH
            assign match_dst      [gv] = pos_in + {{(POS_W-ML_W){1'b0}}, len_in[gv]};
            assign match_cost     [gv] = dp_cost[pos_in[DP_LOG-1:0]] + price_in[gv+1];
            assign match_limit    [gv] = {1'b0, prune_thresh} + {1'b0, PRUNE_MARGIN};
            assign match_valid_upd[gv] = valid_in[gv+1] & price_pulse
                                       & (match_cost[gv] < dp_cost[match_dst[gv][DP_LOG-1:0]])
                                       & ({1'b0, match_cost[gv]} <= match_limit[gv]);
        end
    endgenerate

    reg [PRICE_W-1:0] cand_min;
    always @(*) begin
        cand_min = prune_thresh;
        if (lit_valid_upd && lit_cost < cand_min)
            cand_min = lit_cost;
        for (i = 0; i < K; i = i+1)
            if (match_valid_upd[i] && match_cost[i] < cand_min)
                cand_min = match_cost[i];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bt_start     <= 1'b0;
            bt_len       <= '0;
            prune_thresh <= INF_COST;
            for (i = 0; i < DP_STATES; i = i+1) begin
                dp_cost[i]     <= INF_COST;
                dp_is_match[i] <= 1'b0;
                dp_offset[i]   <= '0;
                dp_ml[i]       <= '0;
            end
        end else begin
            bt_start <= 1'b0;
            if (block_start) begin
                for (i = 0; i < DP_STATES; i = i+1) begin
                    dp_cost[i]     <= INF_COST;
                    dp_is_match[i] <= 1'b0;
                    dp_offset[i]   <= '0;
                    dp_ml[i]       <= '0;
                end
                dp_cost[0]   <= 16'd0;
                prune_thresh <= INF_COST;
            end

            if (price_pulse) begin
                if (lit_valid_upd) begin
                    dp_cost    [lit_dst[DP_LOG-1:0]] <= lit_cost;
                    dp_is_match[lit_dst[DP_LOG-1:0]] <= 1'b0;
                    dp_offset  [lit_dst[DP_LOG-1:0]] <= '0;
                    dp_ml      [lit_dst[DP_LOG-1:0]] <= 8'd1;
                end

                for (i = 0; i < K; i = i+1) begin
                    if (match_valid_upd[i]) begin
                        dp_cost    [match_dst[i][DP_LOG-1:0]] <= match_cost[i];
                        dp_is_match[match_dst[i][DP_LOG-1:0]] <= 1'b1;
                        dp_offset  [match_dst[i][DP_LOG-1:0]] <= off_in[i];
                        dp_ml      [match_dst[i][DP_LOG-1:0]] <= len_in[i];
                    end
                end

                if (cand_min < prune_thresh)
                    prune_thresh <= cand_min;
                if (pos_in == block_len - 1) begin
                    bt_start <= 1'b1;
                    bt_len   <= block_len;
                end
            end
        end
    end

    always @(posedge clk) begin
        bt_offset   <= dp_offset  [bt_rd_addr[DP_LOG-1:0]];
        bt_length   <= dp_ml      [bt_rd_addr[DP_LOG-1:0]];
        bt_is_match <= dp_is_match[bt_rd_addr[DP_LOG-1:0]];
    end

endmodule
`default_nettype wire
